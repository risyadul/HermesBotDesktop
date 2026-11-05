import AppKit
import HermesGatewayKit
import SwiftUI

/// Bot Chat composer: pending attachment chips, paperclip (NSOpenPanel, several files), the text field
/// with the slash menu above it, Send (and Stop while a reply runs), and the status row.
/// Files can also be pasted (⌘V with files or an image on the pasteboard) or dropped on the chat
/// (`BotChatView`); chips stay local until Send. The send gate stays in `ChatModel.submit`: the draft is
/// cleared only when accepted.
struct ChatComposer: View {
    @ObservedObject var chat: ChatModel
    let identity: BotIdentity
    @FocusState private var focused: Bool
    @State private var menu = SlashMenuState()
    @State private var paste = AttachmentPasteMonitor()
    @Environment(\.motionEnabled) private var motion

    private var menuItems: [SlashCommand] {
        menu.isOpen(chat.draft, catalog: chat.catalog) ? SlashMenuState.items(chat.draft, catalog: chat.catalog) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            let items = menuItems
            if !items.isEmpty {
                SlashCommandMenu(items: items, selected: menu.highlighted(chat.draft, catalog: chat.catalog)?.name) { c in
                    chat.draft = "\(c.name) "
                    focused = true
                }
                .transition(motion ? .scale(scale: DS.Motion.pressedScale, anchor: .bottomLeading).combined(with: .opacity) : .identity)
            }
            field
            statusRow
        }
        .animation(motion ? DS.Motion.pop : nil, value: menuItems.map(\.id))
        .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
        .onChange(of: chat.draft) { _, d in
            menu.draftChanged(d)
            if d == "/" && chat.catalog == nil { chat.loadCatalog() }
        }
        .onChange(of: focused) { _, f in paste.focused = f }
        .onAppear { let chat = chat; paste.install(canAttach: { chat.isReady }, attach: { chat.addAttachments($0) }) }
        .onDisappear { paste.remove() }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if !chat.pending.isEmpty {
                AttachmentChips(items: chat.pending) { chat.removeAttachment($0) }
            }
            HStack(alignment: .bottom, spacing: DS.Space.s2) {
                IconButton(symbol: "paperclip", label: "Attach files", action: pickFiles)
                    .disabled(!chat.isReady)
                TextField(placeholder, text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typeface.body)
                    .lineLimit(DS.Size.composerLines)
                    .padding(.vertical, DS.Size.fieldInset)
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { moveMenu(-1) }
                    .onKeyPress(.downArrow) { moveMenu(1) }
                    .onKeyPress(.tab) { acceptMenu() ? .handled : .ignored }
                    .onKeyPress(.escape) {
                        guard !menuItems.isEmpty else { return .ignored }
                        menu.dismiss(chat.draft)
                        return .handled
                    }
                    .accessibilityLabel("Message \(chat.bot.title)")
                if chat.busy {
                    IconButton(symbol: "stop.circle", label: "Stop the reply") { chat.stop() }
                }
                Button("Send", action: send)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, DS.Space.s2).padding(.trailing, DS.Space.s2).padding(.vertical, DS.Space.s2)
        .composerSurface(focused: focused)
    }

    private var statusRow: some View {
        HStack(spacing: DS.Space.s3) {
            KeyHint(keys: "Return", label: "send")
            KeyHint(keys: "/", label: "commands")
            Spacer()
            if let activity = chat.activity {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text(activity).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
                .transition(.opacity)
            } else if chat.reconnecting {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Reopening the Bot Chat…").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
                .transition(.opacity)
            } else if chat.busy {
                HStack(spacing: DS.Space.s2) {
                    WorkingDots(color: identity.nameColor)
                    Text(Self.busyText(bot: chat.bot.title, drafting: chat.transcript.draftingTool))
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(motion ? DS.Motion.ease : nil, value: chat.busy)
        .animation(motion ? DS.Motion.ease : nil, value: chat.activity)
    }

    /// Status while a reply runs; `tool.generating` shows which tool call the model is drafting.
    nonisolated static func busyText(bot: String, drafting: String?) -> String {
        guard let tool = drafting, !tool.isEmpty else { return "\(bot) is replying" }
        return "\(bot) is drafting \(tool)"
    }

    private var placeholder: String {
        switch chat.phase {
        case .ready: return "Message \(chat.bot.title)"
        case .loading, .idle: return "Opening the Bot Chat…"
        case .failed: return "The Bot Chat is not open"
        }
    }

    /// The model's gate (`ChatModel.canSend`): the same rules as `submit`, so the button never lies.
    private var canSend: Bool { chat.canSend }

    // MARK: actions

    /// Return / Send. With the slash menu open, Return accepts the highlight first.
    private func send() {
        if menu.returnAccepts(chat.draft, catalog: chat.catalog) { _ = acceptMenu(); return }
        chat.submit()
    }

    private func moveMenu(_ delta: Int) -> KeyPress.Result {
        let items = menuItems
        guard !items.isEmpty else { return .ignored }
        menu.move(delta, count: items.count)
        return .handled
    }

    private func acceptMenu() -> Bool {
        guard !menuItems.isEmpty, let next = menu.accept(chat.draft, catalog: chat.catalog) else { return false }
        chat.draft = next
        return true
    }

    private func pickFiles() {
        let chat = chat
        pickAttachments(message: "Attach files to your message to \(chat.bot.title)") { chat.addAttachments($0) }
    }
}
