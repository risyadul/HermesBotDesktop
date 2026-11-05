import AppKit
import HermesGatewayKit
import SwiftUI

/// A file picked, dropped or pasted into the composer. Chips are LOCAL until Send: only the client-side
/// checks run at pick time (`ChatAttachments.check`); the attach RPCs run inside the send
/// (`BotChatSession.submit(_:files:)`), so nothing is queued on the shared Bot Chat before then.
struct PendingAttachment: Identifiable, Equatable {
    enum State: Equatable {
        /// Checked; goes out with the next send.
        case ready
        /// Being staged by a send in flight.
        case sending
        /// Refused (check or send); the chip stays with the error until removed.
        case failed(String)
    }

    let id = UUID()
    let url: URL
    /// Resolved path (duplicate check).
    let key: String
    /// The client-side check result; nil when the check failed (and for a context ref).
    let checked: ChatAttachments.Checked?
    var state: State
    /// B11: a web page or folder sent as an `@url:` / `@folder:` line in the prompt (nothing is uploaded).
    var contextRef: ContextRef?

    init(url: URL, key: String? = nil, check: (URL) throws -> ChatAttachments.Checked) {
        self.url = url
        self.key = key ?? url.standardizedFileURL.resolvingSymlinksInPath().path
        do {
            checked = try check(url)
            state = .ready
        } catch {
            checked = nil
            state = .failed(Redaction.describe(error))
        }
    }

    /// B11: a context ref chip (`@url:` / `@folder:`): always ready, never staged on the session.
    init(ref: ContextRef) {
        contextRef = ref
        url = ref.kind == .folder ? URL(fileURLWithPath: ref.value, isDirectory: true) : (URL(string: ref.value) ?? URL(fileURLWithPath: "/"))
        key = ref.refText
        checked = nil
        state = .ready
    }

    var name: String {
        if let ref = contextRef {
            return VisibleText.reveal(ref.kind == .url ? (url.host ?? ref.value) : url.lastPathComponent)
        }
        // B11: a long paste saved as a text file reads as "Pasted content", as in Desktop.
        if LargePaste.isPastedContent(url.lastPathComponent) {
            return "Pasted content" + (checked.map { " (\(LargePaste.byteLabel($0.bytes)))" } ?? "")
        }
        return VisibleText.reveal(checked?.name ?? url.lastPathComponent)
    }
    var kind: ChatAttachments.Kind { checked?.kind ?? ChatAttachments.kind(of: url) }
    var isReady: Bool { state == .ready }
    var isSending: Bool { state == .sending }
    var isFailed: Bool { if case .failed = state { return true }; return false }
    var error: String? { if case .failed(let e) = state { return e }; return nil }
    /// A pasted image the app wrote itself (deleted once sent, removed or at quit).
    var isTemporary: Bool { PasteboardAttachments.isPasted(url) }

    var symbol: String {
        switch contextRef?.kind {
        case .url?: return "link"
        case .folder?: return "folder"
        case nil: break
        }
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        }
    }

    var detail: String {
        switch state {
        case .sending: return "Sending…"
        case .failed(let e): return e
        case .ready:
            if let ref = contextRef { return ref.kind == .url ? "Web page" : "Folder" }
            if let pages = checked?.pages { return pages == 1 ? "1 page" : "\(pages) pages" }
            return kind == .image ? "Image" : (kind == .pdf ? "PDF" : "File")
        }
    }

    var accessibilityLabel: String {
        let what = contextRef.map { $0.kind == .url ? "Web page" : "Folder" } ?? (kind == .image ? "Image" : "File")
        switch state {
        case .sending: return "\(what) \(name), sending"
        case .failed(let e): return "\(what) \(name) could not be attached: \(e)"
        case .ready: return "\(what) \(name), ready to send"
        }
    }
}

/// Files and images on the pasteboard (paste into the composer). File URLs win; raw image data (a
/// screenshot copied to the clipboard, no text) is written to a PNG in the app's own paste folder
/// (0700, under the per-user temporary directory). Those files are deleted once their turn has settled,
/// when their chip is removed, and at quit (`purge`). Text is left to the field.
enum PasteboardAttachments {
    static let folderName = "HermesBot Pasted Images"
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true) }

    static func urls(from pb: NSPasteboard, folder: URL = PasteboardAttachments.folder) -> [URL] {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files }
        // Rich text copies can carry an image rendition too: with text on the pasteboard, paste the text.
        guard pb.availableType(from: [.string]) == nil, pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              let url = write(png, in: folder) else { return [] }
        return [url]
    }

    /// Writes `png` to a fresh file in `folder` (created or re-tightened to 0700).
    static func write(_ png: Data, in folder: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let url = folder.appendingPathComponent("Pasted image \(UUID().uuidString.prefix(8)).png")
            try png.write(to: url, options: .withoutOverwriting)
            return url
        } catch { return nil }
    }

    static func isPasted(_ url: URL, folder: URL = PasteboardAttachments.folder) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// Deletes pasted images (only files inside the paste folder).
    static func delete(_ urls: [URL], folder: URL = PasteboardAttachments.folder) {
        for u in urls where isPasted(u, folder: folder) { try? FileManager.default.removeItem(at: u) }
    }

    /// Quit: the whole paste folder goes.
    static func purge(folder: URL = PasteboardAttachments.folder) {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Pending attachment chips above the composer field: kind symbol, name, state (spinner, detail or the
/// error in the danger role) and a remove button.
struct AttachmentChips: View {
    let items: [PendingAttachment]
    let onRemove: (UUID) -> Void
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s2) {
                ForEach(items) { item in
                    AttachmentChip(item: item) { onRemove(item.id) }
                        .transition(motion ? .scale(scale: DS.Motion.arriveScale).combined(with: .opacity) : .identity)
                }
            }
            .padding(.vertical, DS.Space.s0)
        }
        .animation(motion ? DS.Motion.pop : nil, value: items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }
}

struct AttachmentChip: View {
    let item: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Group {
                if item.isSending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: item.isFailed ? "exclamationmark.triangle.fill" : item.symbol)
                        .font(DS.Typeface.icon)
                        .foregroundStyle(item.isFailed ? DS.Palette.danger : DS.Palette.muted)
                }
            }
            .frame(width: DS.Space.s4)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(DS.Typeface.caption)
                    .foregroundStyle(item.isFailed ? DS.Palette.danger : DS.Palette.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: DS.Size.mediaChipMax / 1.5, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(DS.Typeface.iconSmall)
                    .frame(width: DS.Space.s4 + DS.Space.s1, height: DS.Space.s4 + DS.Space.s1)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(item.isSending)
            .accessibilityLabel("Remove \(item.name)")
            .help("Remove \(item.name)")
        }
        .padding(.leading, DS.Space.s2).padding(.trailing, DS.Space.s1).padding(.vertical, DS.Space.s1)
        .background(item.isFailed ? DS.Palette.dangerSoft : DS.Palette.window,
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(item.isFailed ? DS.Palette.dangerRing : DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel)
    }
}

// MARK: - shared composer plumbing (Bot Chat and Group Chat)

/// ⌘V while a composer field is focused and the pasteboard holds files or an image: attach them instead of
/// pasting their names. Anything else (text) pastes normally. One per composer; `install` is idempotent.
@MainActor final class AttachmentPasteMonitor {
    private var monitor: Any?
    /// The composer's focus, readable from the AppKit monitor (which outlives one view value).
    var focused = false

    /// `pasteText` (Bot Chat, B11) sees a text-only paste first and returns true when it took it (a long
    /// paste becomes an attachment); the field gets the paste otherwise.
    func install(canAttach: @escaping @MainActor () -> Bool, attach: @escaping @MainActor ([URL]) -> Void,
                 pasteText: (@MainActor (String) -> Bool)? = nil) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers == "v"
            guard isPaste else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard self?.focused == true, canAttach() else { return false }
                let urls = PasteboardAttachments.urls(from: .general)
                if urls.isEmpty, let pasteText, let text = NSPasteboard.general.string(forType: .string) {
                    return pasteText(text)
                }
                guard !urls.isEmpty else { return false }
                attach(urls)
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// The multi-file picker behind a composer's paperclip.
@MainActor func pickAttachments(message: String, attach: @escaping @MainActor ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.prompt = "Attach"
    panel.message = message
    panel.begin { response in
        guard response == .OK else { return }
        let urls = panel.urls
        MainActor.assumeIsolated { attach(urls) }
    }
}

/// B11: the folder picker behind "Attach Folder…" (folders go as `@folder:` context, nothing is uploaded).
@MainActor func pickFolders(message: String, attach: @escaping @MainActor ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Attach"
    panel.message = message
    panel.begin { response in
        guard response == .OK else { return }
        let urls = panel.urls
        MainActor.assumeIsolated { attach(urls) }
    }
}

/// Dashed ring over a pane while files are dragged over it.
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.ring, style: StrokeStyle(lineWidth: DS.Stroke.keyboardFocus, dash: [DS.Space.s2, DS.Space.s1]))
            .background(DS.Palette.hover, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
            }
            .padding(DS.Space.s2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
