import AppKit
import HermesGatewayKit
import SwiftUI

/// Bot Chat composer: the queue panel, pending attachment chips, paperclip (NSOpenPanel, several files), the
/// text field with the slash menu above it, Send (and Stop while a reply runs), and the status row with the
/// model, reasoning effort and context controls.
/// While a reply runs, Return steers it (`session.redirect`) and ⌘Return queues the message (B8); the
/// primary button follows `ChatModel.composerAction` (Send / Steer / Queue / Save).
/// Files can also be pasted (⌘V with files or an image on the pasteboard) or dropped on the chat
/// (`BotChatView`); chips stay local until Send. The send gate stays in `ChatModel.submit`: the draft is
/// cleared only when accepted.
/// `@` lists the other bots (B1, Tab or click inserts); ↑/↓ at the start/end of the text walk the earlier
/// messages (B12, ChatModel+Composer.swift).
struct ChatComposer: View {
    @ObservedObject var chat: ChatModel
    let identity: BotIdentity
    @FocusState private var focused: Bool
    @State private var menu = SlashMenuState()
    @State private var paste = AttachmentPasteMonitor()
    /// B17: the mic button's dictation (Voice/Dictation.swift).
    @StateObject private var dictation = DictationController()
    @Environment(\.motionEnabled) private var motion

    private var menuItems: [SlashCommand] {
        menu.isOpen(chat.draft, catalog: chat.catalog) ? SlashMenuState.items(chat.draft, catalog: chat.catalog) : []
    }

    /// B1: roster bots for the `@word` the draft ends with (none while the slash menu shows).
    private var mentionMatches: [Bot] {
        guard menuItems.isEmpty, chat.draft.contains("@") else { return [] }
        return BotMentionCompletion.matches(chat.draft, candidates: chat.mentionCandidates)
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
            let mentions = mentionMatches
            if !mentions.isEmpty {
                BotMentionSuggestions(matches: mentions, candidates: chat.mentionCandidates) { pickMention($0) }
                    .transition(motion ? .scale(scale: DS.Motion.pressedScale, anchor: .bottomLeading).combined(with: .opacity) : .identity)
            }
            if !chat.queue.isEmpty {
                ChatQueuePanel(chat: chat)
                    .transition(motion ? .opacity.combined(with: .move(edge: .bottom)) : .identity)
            }
            field
            statusRow
        }
        .animation(motion ? DS.Motion.pop : nil, value: menuItems.map(\.id))
        .animation(motion ? DS.Motion.pop : nil, value: mentionMatches.map(\.id))
        .animation(motion ? DS.Motion.ease : nil, value: chat.queue.map(\.id))
        .alert(chat.modelConfirm.map { "Switch to \($0.model)?" } ?? "", isPresented: Binding(
            get: { chat.modelConfirm != nil }, set: { if !$0 { chat.cancelModelSwitch() } }
        ), presenting: chat.modelConfirm) { _ in
            Button("Switch") { chat.confirmModelSwitch() }
            Button("Cancel", role: .cancel) { chat.cancelModelSwitch() }
        } message: { c in
            Text(c.message)
        }
        .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
        .onChange(of: chat.draft) { _, d in
            menu.draftChanged(d)
            if d == "/" && chat.catalog == nil { chat.loadCatalog() }
        }
        .onChange(of: focused) { _, f in paste.focused = f }
        .onAppear {
            let chat = chat
            // A branch sheet over this chat has its own composer: pastes go there, not here.
            paste.install(canAttach: { chat.isReady && chat.branch == nil }, attach: { chat.addDropped($0) },
                          pasteText: { chat.branch == nil && chat.attachLongPaste($0) })  // B11: a long paste becomes a text attachment
        }
        .onDisappear { paste.remove() }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            DictationErrorBanner(dictation: dictation)  // B17
            if !chat.pending.isEmpty {
                AttachmentChips(items: chat.pending) { chat.removeAttachment($0) }
            }
            HStack(alignment: .bottom, spacing: DS.Space.s2) {
                attachMenu
                TextField(placeholder, text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typeface.body)
                    .lineLimit(DS.Size.composerLines)
                    .padding(.vertical, DS.Size.fieldInset)
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { moveMenu(-1) == .handled ? .handled : recall(up: true) }
                    .onKeyPress(.downArrow) { moveMenu(1) == .handled ? .handled : recall(up: false) }
                    .onKeyPress(.tab) { acceptMenu() || acceptMention() ? .handled : .ignored }
                    .onKeyPress(.escape) {
                        if !menuItems.isEmpty { menu.dismiss(chat.draft); return .handled }
                        guard chat.editingQueueId != nil else { return .ignored }
                        chat.cancelQueueEdit()
                        return .handled
                    }
                    .accessibilityLabel("Message \(chat.bot.title)")
                DictationButton(dictation: dictation, text: $chat.draft)  // B17
                    .disabled(!chat.isReady)
                if chat.busy {
                    IconButton(symbol: "stop.circle", label: "Stop the reply") { chat.stop() }
                }
                Button(Self.primaryLabel(chat.composerAction), action: send)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(!canSend)
                    .keyboardShortcut(chat.busy ? nil : KeyboardShortcut(.return, modifiers: .command))
                    .help(Self.primaryHelp(chat.composerAction))
                if chat.busy {
                    // ⌘Return while a reply runs: queue the draft (an invisible button keeps the shortcut
                    // working wherever focus is, like Send's).
                    Button("Queue message") { chat.queueOrSend() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.leading, DS.Space.s2).padding(.trailing, DS.Space.s2).padding(.vertical, DS.Space.s2)
        .composerSurface(focused: focused)
    }

    /// Controls, key hints and the chat's status. Narrower rows drop the hints first, then the effort
    /// label; the model name and the status text truncate last.
    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            statusLine(compact: false, hints: true)
            statusLine(compact: false, hints: false)
            statusLine(compact: true, hints: false)
        }
        .animation(motion ? DS.Motion.ease : nil, value: chat.busy)
        .animation(motion ? DS.Motion.ease : nil, value: chat.activity)
        .animation(motion ? DS.Motion.ease : nil, value: chat.compacting)
    }

    private func statusLine(compact: Bool, hints showHints: Bool) -> some View {
        HStack(spacing: DS.Space.s3) {
            ComposerControls(chat: chat, compact: compact)
            if showHints { hints }
            Spacer(minLength: 0)
            status
        }
    }

    @ViewBuilder private var status: some View {
        if let activity = chat.activity {
            statusText(activity, spinner: true)
        } else if chat.reconnecting {
            statusText("Reopening the Bot Chat…", spinner: true)
        } else if chat.compacting {
            statusText("Compacting the conversation…", spinner: true)
        } else if chat.busy {
            HStack(spacing: DS.Space.s2) {
                WorkingDots(color: identity.nameColor)
                Text(Self.busyText(bot: chat.bot.title, drafting: chat.transcript.draftingTool))
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private func statusText(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: DS.Space.s2) {
            if spinner { ProgressView().controlSize(.mini) }
            Text(text).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    /// What Return does now, then the second key where there is one.
    @ViewBuilder private var hints: some View {
        HStack(spacing: DS.Space.s3) {
            ForEach(Self.hints(chat.composerAction), id: \.keys) { h in KeyHint(keys: h.keys, label: h.label) }
        }
        .fixedSize()
    }

    nonisolated static func hints(_ action: ComposerAction) -> [(keys: String, label: String)] {
        switch action {
        case .send: return [("Return", "send"), ("/", "commands"), ("@", "mention")]
        case .steer: return [("Return", "steer"), ("⌘Return", "queue")]
        case .queue: return [("Return", "queue")]
        case .saveEdit: return [("Return", "save"), ("Esc", "cancel")]
        }
    }

    nonisolated static func primaryLabel(_ action: ComposerAction) -> String {
        switch action {
        case .send: return "Send"
        case .steer: return "Steer"
        case .queue: return "Queue"
        case .saveEdit: return "Save"
        }
    }

    nonisolated static func primaryHelp(_ action: ComposerAction) -> String {
        switch action {
        case .send: return "Send (Return)"
        case .steer: return "Redirect the running reply to this message (Return). ⌘Return queues it instead."
        case .queue: return "Send this after the running reply finishes (Return)"
        case .saveEdit: return "Save the queued message (Return). Esc cancels."
        }
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

    /// The model's gate for what the button does now (`ChatModel.canPrimary`), so the button never lies.
    private var canSend: Bool { chat.canPrimary }

    // MARK: actions

    /// Return / Send. With the slash menu open, Return accepts the highlight first.
    private func send() {
        if menu.returnAccepts(chat.draft, catalog: chat.catalog) { _ = acceptMenu(); return }
        dictation.stop()  // B17: sending ends dictation and stops a reply being read aloud
        ReadAloudController.shared.stop()
        chat.primaryAction()
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

    /// B1: Tab takes the first @ suggestion.
    private func acceptMention() -> Bool {
        guard let first = mentionMatches.first else { return false }
        pickMention(first)
        return true
    }

    private func pickMention(_ bot: Bot) {
        BotMentionCompletion.insert(bot, candidates: chat.mentionCandidates, into: &chat.draft)
        focused = true
    }

    /// B12: ↑ / ↓ recall sent messages when the caret is at the start / end of the text (like a shell);
    /// otherwise the key moves the caret as usual. Read from the field editor, the text view that has the
    /// caret while the composer is focused.
    private func recall(up: Bool) -> KeyPress.Result {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           !PromptHistory.caretAllows(up: up, caret: editor.selectedRange(), length: (editor.string as NSString).length) {
            return .ignored
        }
        return (up ? chat.recallOlder() : chat.recallNewer()) ? .handled : .ignored
    }

    /// B11: the paperclip offers files, a folder (`@folder:`) and a web page (`@url:`).
    private var attachMenu: some View {
        Menu {
            Button("Attach Files…", action: pickFiles)
            Button("Attach Folder…", action: pickFolder)
            Button("Attach URL…") { chat.urlDialogShown = true }
        } label: {
            Image(systemName: "paperclip").font(DS.Typeface.icon)
                .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(IconButtonStyle())
        .fixedSize()
        .accessibilityLabel("Attach files")
        .help("Attach files, a folder or a web page")
        .disabled(!chat.isReady)
    }

    private func pickFolder() {
        let chat = chat
        pickFolders(message: "Attach folders as context for \(chat.bot.title)") { chat.addFolders($0) }
    }

    private func pickFiles() {
        let chat = chat
        pickAttachments(message: "Attach files to your message to \(chat.bot.title)") { chat.addAttachments($0) }
    }
}
