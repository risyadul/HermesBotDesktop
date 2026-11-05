import AppKit
import HermesGatewayKit
import SwiftUI

// D4: the Quick Ask panel. A floating, non-activating panel (typing works without bringing the app's
// windows forward): pick a bot, type, Return sends it to the bot's Bot Chat and the reply streams in
// below, read from the same ChatModel the Bot Chat pane shows. Esc (or the shortcut again) hides it.

/// The panel's state, headless (QuickAskModelTests).
@MainActor
final class QuickAskModel: ObservableObject {
    @Published var bot: String?
    @Published var text = ""
    @Published private(set) var turn: QuickTurn?
    @Published private(set) var error: String?
    @Published private(set) var sending = false
    /// Bumped each time the panel is shown: the field takes focus again.
    @Published private(set) var shown = 0

    let sender: () -> QuickSender

    init(sender: @escaping () -> QuickSender) {
        self.sender = sender
    }

    var bots: [Bot] { sender().bots() }

    /// Keeps the picked bot when it still exists, else the first one.
    func pickDefaultBot() {
        let names = bots.map(\.name)
        if let bot, names.contains(bot) { return }
        bot = names.first
    }

    var canSend: Bool {
        bot != nil && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return / Send. The text clears once the message went out; it stays on a refusal.
    func send() async {
        guard canSend, let bot else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            turn = try await sender().send(text, toBot: bot)
            text = ""
        } catch {
            self.error = (error as? QuickSendError)?.description ?? Redaction.describe(error)
        }
    }

    /// The panel came on screen.
    func didShow() {
        pickDefaultBot()
        shown += 1
    }

    /// Picking another bot clears the previous reply.
    func botChanged() {
        turn = nil
        error = nil
    }
}

/// A quick turn's reply, live from its ChatModel (shared by Quick Ask and Summarize Since I Left).
struct QuickReplyView: View {
    @ObservedObject var chat: ChatModel
    let userLine: UUID
    var maxHeight: CGFloat = 260

    var body: some View {
        let state = QuickReply.state(lines: chat.lines, after: userLine, busy: chat.busy)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                switch state {
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text("\(chat.bot.title) is thinking…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                case .streaming:
                    StatusDot(color: DS.Palette.primary, live: true)
                    Text("\(chat.bot.title) is replying").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                case .done:
                    Text(chat.bot.title).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                case .failed:
                    Label("Failed", systemImage: "exclamationmark.triangle").font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                }
                Spacer(minLength: 0)
            }
            if !state.text.isEmpty {
                ScrollView {
                    Text(verbatim: state.text)
                        .font(DS.Typeface.body)
                        .foregroundStyle(state.failed ? DS.Palette.danger : DS.Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuickAskView: View {
    @ObservedObject var model: QuickAskModel
    /// Re-renders when the roster loads or changes (the bot menu).
    @ObservedObject private var app = AppModel.shared
    let onOpen: (String) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                Picker("Bot", selection: $model.bot) {
                    ForEach(model.bots) { bot in Text(bot.title).tag(Optional(bot.name)) }
                }
                .labelsHidden()
                .accessibilityLabel("Bot")
                .fixedSize()
                .onChange(of: model.bot) { _, _ in model.botChanged() }
                TextField("Ask a bot…", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typeface.titlePane)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { Task { await model.send() } }
                if model.sending { ProgressView().controlSize(.small) }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let turn = model.turn {
                Hairline()
                QuickReplyView(chat: turn.chat, userLine: turn.userLine)
                HStack {
                    Spacer()
                    Button("Open in Bot Chat") { onOpen(turn.chat.bot.name) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            if model.bots.isEmpty {
                Text("Hermes Bot is not connected. Open the app to connect.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: QuickAskPanel.width)
        .background(DS.Palette.window)
        .tint(DS.Palette.primary)
        .onExitCommand(perform: onClose)
        .onAppear {
            model.pickDefaultBot()
            focused = true
        }
        .onChange(of: model.shown) { _, _ in focused = true }
        .onChange(of: app.bots.map(\.name)) { _, _ in model.pickDefaultBot() }
    }
}

/// Floating, non-activating, borderless-looking panel that can still take the keyboard.
final class QuickAskPanel: NSPanel {
    static let width: CGFloat = 560
    var onCancel: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentViewController = content
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the one Quick Ask panel: the shortcut toggles it.
@MainActor
final class QuickAskPanelController {
    static let shared = QuickAskPanelController()
    private var panel: QuickAskPanel?
    private lazy var model = QuickAskModel(sender: { AppModel.shared.quickSender })

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.didShow()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> QuickAskPanel {
        let view = QuickAskView(model: model,
                                onOpen: { [weak self] name in
                                    self?.hide()
                                    AppModel.shared.openFromIntegration(.bot(name))
                                },
                                onClose: { [weak self] in self?.hide() })
        // A hosting controller (not a bare hosting view) resizes the panel as the reply grows.
        let host = NSHostingController(rootView: view.modifier(MotionGate()))
        host.sizingOptions = [.preferredContentSize]
        let panel = QuickAskPanel(content: host)
        panel.onCancel = { [weak self] in self?.hide() }
        return panel
    }
}
