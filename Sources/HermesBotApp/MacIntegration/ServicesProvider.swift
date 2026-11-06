import AppKit
import HermesGatewayKit
import SwiftUI

// D6: macOS Services → "Send to Herald" for selected text and Finder files. The service (declared as
// NSServices in Info.plist by scripts/package-app.sh, served by `NSApp.servicesProvider`) never sends: it
// opens a small chooser, prefilled, where the user picks a bot or a group chat and then either sends the text
// or puts text and files into that chat's composer.

/// What a Services request carried: text and/or file URLs. Pure (ServicesInputTests).
struct ServiceInput: Equatable {
    var text: String
    var files: [URL]

    /// Characters of text taken from a selection.
    static let textLimit = 20_000
    /// Files taken (a room message carries at most this many).
    static let fileLimit = RoomAttachments.maxFiles

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }

    /// `fileURLs`: `public.file-url` items; `filenames`: the legacy NSFilenamesPboardType list. Only regular
    /// files that exist are kept (no folders), without duplicates, at most `fileLimit`.
    static func make(text: String?, fileURLs: [URL], filenames: [String],
                     isRegularFile: (URL) -> Bool = ServiceInput.isRegularFile) -> ServiceInput {
        var seen: Set<String> = []
        var files: [URL] = []
        for url in fileURLs + filenames.map({ URL(fileURLWithPath: $0) }) where url.isFileURL {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), isRegularFile(url) else { continue }
            seen.insert(key)
            files.append(url.standardizedFileURL)
        }
        var body = text ?? ""
        // A file selection usually also offers its paths as text: drop text that only repeats them.
        let paths = Set(files.map(\.path))
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if !files.isEmpty, !lines.isEmpty, lines.allSatisfy({ paths.contains($0) || paths.contains(URL(string: $0)?.path ?? "") }) {
            body = ""
        }
        if body.count > textLimit { body = String(body.prefix(textLimit)) }
        return ServiceInput(text: body, files: Array(files.prefix(fileLimit)))
    }

    static func read(_ pboard: NSPasteboard) -> ServiceInput {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let legacy = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        return make(text: pboard.string(forType: .string), fileURLs: urls, filenames: legacy)
    }

    nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

/// The object `NSApp.servicesProvider` points at. The selector matches NSMessage "sendToHermesBot". AppKit
/// calls it on the main thread.
@MainActor
final class HermesServicesProvider: NSObject {
    let present: @MainActor (ServiceInput) -> Void

    init(present: @escaping @MainActor (ServiceInput) -> Void) {
        self.present = present
    }

    @objc(sendToHermesBot:userData:error:)
    func sendToHermesBot(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let input = ServiceInput.read(pboard)
        guard !input.isEmpty else {
            error.pointee = "Nothing to send: select some text or files first." as NSString
            return
        }
        present(input)
    }
}

/// Installs the provider. Production: `NSApp.servicesProvider` + `NSUpdateDynamicServices`; tests inject a
/// recorder, so no service is ever registered with the system from a test.
@MainActor
protocol ServicesRegistering {
    func install(_ provider: NSObject)
}

@MainActor
struct AppServicesRegistrar: ServicesRegistering {
    func install(_ provider: NSObject) {
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }
}

// MARK: - chooser

/// The Services chooser's state, headless (ServicesInputTests).
@MainActor
final class SendChooserModel: ObservableObject {
    @Published var target: QuickSendTarget?
    @Published var text: String
    @Published private(set) var files: [URL]
    @Published private(set) var working = false
    @Published private(set) var error: String?
    /// Set once the chooser did its job (the panel closes).
    @Published private(set) var finished = false

    let sender: () -> QuickSender
    let roomModel: (String) -> RoomModel?
    let open: (SidebarItem) -> Void

    init(input: ServiceInput, sender: @escaping () -> QuickSender, roomModel: @escaping (String) -> RoomModel?,
         open: @escaping (SidebarItem) -> Void) {
        text = input.text
        files = input.files
        self.sender = sender
        self.roomModel = roomModel
        self.open = open
    }

    var bots: [Bot] { sender().bots() }
    var rooms: [RoomSummary] { sender().rooms() }

    func pickDefault() {
        if target == nil { target = bots.first.map { .bot($0.name) } }
    }

    func removeFile(_ url: URL) { files.removeAll { $0 == url } }

    /// Sending is text-only; files go through the composer (Open in Composer).
    var canSend: Bool {
        target != nil && files.isEmpty && !working && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPrefill: Bool {
        target != nil && !working && (!files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The user's Send: posts the text to the room or sends it to the bot's Bot Chat, then shows that chat.
    func send() async {
        guard canSend, let target else { return }
        await run {
            switch target {
            case .bot(let name): _ = try await self.sender().send(self.text, toBot: name)
            case .room(let id): try await self.sender().send(self.text, toRoom: id)
            }
            self.open(target.item)
        }
    }

    /// Puts the text and files into the chosen chat's composer and shows it; nothing is sent.
    func prefill() async {
        guard canPrefill, let target else { return }
        await run {
            try await self.sender().prefill(target, text: self.text, files: self.files, roomModel: self.roomModel)
            self.open(target.item)
        }
    }

    private func run(_ body: () async throws -> Void) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await body()
            finished = true
        } catch {
            self.error = (error as? QuickSendError)?.description ?? Redaction.describe(error)
        }
    }
}

struct SendChooserView: View {
    @ObservedObject var model: SendChooserModel
    /// Re-renders when the roster and rooms load (the app may have just been launched by the service).
    @ObservedObject private var app = AppModel.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text("Send to Herald").font(DS.Typeface.titlePane)
            Picker("To", selection: $model.target) {
                Section("Bots") {
                    ForEach(model.bots) { bot in Text(bot.title).tag(Optional(QuickSendTarget.bot(bot.name))) }
                }
                if !model.rooms.isEmpty {
                    Section("Group Chats") {
                        ForEach(model.rooms) { room in Text(room.name).tag(Optional(QuickSendTarget.room(room.roomId))) }
                    }
                }
            }
            .accessibilityLabel("To")
            TextEditor(text: $model.text)
                .font(DS.Typeface.body)
                .frame(minHeight: 90, maxHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.hairline))
            if !model.files.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(model.files, id: \.self) { url in
                        HStack(spacing: DS.Space.s2) {
                            Image(systemName: "doc").foregroundStyle(DS.Palette.muted)
                            Text(url.lastPathComponent).font(DS.Typeface.meta).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeFile(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(DS.Palette.muted)
                                .accessibilityLabel("Remove \(url.lastPathComponent)")
                        }
                    }
                    Text("Files go into the chat's composer; send them from there.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.bots.isEmpty {
                Text("Herald is not connected yet.").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            HStack {
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Open in Composer") { Task { await model.prefill() } }
                    .disabled(!model.canPrefill)
                    .help("Put the text and files into the chat's composer without sending")
                Button("Send") { Task { await model.send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: DS.Size.sheetWidth)
        .onAppear { model.pickDefault() }
        .onChange(of: app.bots.map(\.name)) { _, _ in model.pickDefault() }
        .onChange(of: model.finished) { _, done in if done { onClose() } }
    }
}

/// Presents the chooser in its own small window (the app comes forward: the user asked for it via Services).
@MainActor
final class SendChooserPresenter {
    static let shared = SendChooserPresenter()
    private var window: NSPanel?

    func present(_ input: ServiceInput) {
        window?.close()
        let model = SendChooserModel(input: input, sender: { AppModel.shared.quickSender },
                                     roomModel: { AppModel.shared.roomModel($0) },
                                     open: { AppModel.shared.openFromIntegration($0) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: DS.Size.sheetWidth, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let host = NSHostingController(rootView: SendChooserView(model: model, onClose: { [weak panel] in panel?.close() })
            .tint(DS.Palette.primary))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
