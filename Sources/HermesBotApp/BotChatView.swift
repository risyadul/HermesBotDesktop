import AppKit
import HermesGatewayKit
import SwiftUI

struct BotChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject private var avatars = AvatarStore.shared
    /// Persisted inspector visibility. The inspector binds to the @State copy below: an @AppStorage write
    /// reaches the view outside the toggle's transaction, so the no-animation path still slid the panel.
    @AppStorage("hba.botInspector") private var storedInspector = true
    @State private var showInspector = UserDefaults.standard.object(forKey: "hba.botInspector") as? Bool ?? true
    @State private var dropTargeted = false
    /// Open/closed Thought and tool rows, kept across row re-creation (DisclosureStore).
    @StateObject private var disclosure = DisclosureStore()
    /// The transcript stays invisible until it has been scrolled to its last row (`settle`).
    @State private var transcriptSettled = false
    /// B13: the find bar's state; nil while it is closed.
    @State private var find: ChatFind?
    @State private var findFocus = 0
    /// B6: follow new output unless the user scrolled up (geometry in `scroll`, only changes published);
    /// messages that arrived below meanwhile.
    @State private var scroll = TranscriptScrollTracker()
    @State private var following = true
    @State private var unread = UnreadCounter()
    @Environment(\.motionEnabled) private var motion

    private var identity: BotIdentity { avatars.identity(profile: chat.bot.name, title: chat.bot.title) }

    var body: some View {
        VStack(spacing: 0) {
            if find != nil {
                ChatFindBar(find: Binding(get: { find ?? ChatFind() }, set: { find = $0 }), lines: chat.lines,
                            focusRequest: findFocus, onClose: { find = nil })
                    .transition(motion ? .move(edge: .top).combined(with: .opacity) : .identity)
            }
            switch chat.phase {
            case .idle, .loading: loadingChat
            case .failed(let message): failedChat(message)
            case .ready:
                if chat.lines.isEmpty && chat.requests.isEmpty { emptyChat } else { transcript }
            }
            ChatComposer(chat: chat, identity: identity)
        }
        // The chat column takes the width the sidebar and inspector leave. Any intrinsic minimum here is
        // inflated by the inspector split (on top of the sidebar inset) and widens it past the window,
        // clipping the inspector at the 820 pt minimum (InspectorLayoutTests).
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(DS.Palette.window)
        .overlay { if dropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard chat.isReady, !files.isEmpty else { return false }
            chat.addDropped(files)  // B11: folders attach as @folder: context
            return true
        } isTargeted: { dropTargeted = $0 && chat.isReady }
        .task { chat.open() }
        .onAppear { seedUnreadHistoryIfReady() }
        .onChange(of: chat.phase) { _, phase in
            if phase == .ready { seedUnreadHistoryIfReady() }
        }
        .navigationTitle(chat.bot.title)
        .navigationSubtitle("@\(chat.bot.name)" + (chat.bot.model.map { " · \($0)" } ?? ""))
        .toolbar {
            ToolbarItem(placement: .navigation) { AvatarView(identity: identity, size: DS.Size.avatarHero) }
            ToolbarItem(placement: .primaryAction) {  // A15, RoutinesView.swift
                RoutinesToolbarButton(bot: chat.bot) { chat.showRoutines() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { toggleFind() } label: { Label("Find in Chat", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find in this chat (⌘F)")
                    .disabled(!chat.isReady)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { ChatExport.save(chat) } label: { Label("Export Conversation", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .help("Export this chat as Markdown (⇧⌘E)")
                    .disabled(!chat.isReady || chat.lines.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                // The bot row's actions (Edit, Duplicate, Delete, Open in New Window, Mute) in the pane too.
                Menu { BotManageMenu(bot: chat.bot, model: AppModel.shared) } label: { Label("Bot", systemImage: "ellipsis.circle") }
                    .help("Bot actions")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // System inspector animation with motion on; a no-animation transaction with it off.
                    if motion { showInspector.toggle() } else { withDSAnimation(false) { showInspector.toggle() } }
                } label: { Label("Bot Details", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show or hide bot details (⌥⌘I)")
            }
        }
        .inspector(isPresented: $showInspector) {
            BotInspector(bot: chat.bot, identity: identity)
                .inspectorColumnWidth(min: DS.Size.inspectorMin, ideal: DS.Size.inspectorWidth, max: DS.Size.inspectorMax)
        }
        .onChange(of: showInspector) { _, shown in storedInspector = shown }
        // B3 confirm + edit, B11 URL dialog + image zoom.
        .chatSheets(chat, motion: motion)
        // B4: a branch opens beside the chat, read-write.
        .motionSheet(isPresented: Binding(get: { chat.branch != nil }, set: { if !$0 { chat.closeBranch() } }), motion: motion) {
            if let branch = chat.branch { BranchChatSheet(chat: branch, onClose: { chat.closeBranch() }) }
        }
        // Presented from the pane (in the window's view hierarchy), not from the toolbar item that opens it.
        .motionSheet(isPresented: $chat.routinesShown, motion: motion) {
            RoutinesSheet(bot: chat.bot, context: .current(), onClose: { chat.routinesShown = false })
        }
        .animation(motion ? DS.Motion.ease : nil, value: find != nil)
    }

    /// ⌘F opens the find bar, or puts the caret back in its field when it is already open.
    private func toggleFind() {
        if find == nil { find = ChatFind() } else { findFocus += 1 }
    }

    private func seedUnreadHistoryIfReady() {
        guard chat.isReady, unread.seedHistoryIfNeeded(chat.lines) else { return }
        scroll.follow.resume()
        following = true
    }

    private var transcript: some View {
        let presentation = chat.presentation
        let rows = BotTimelineRows(messages: presentation.items, requests: chat.requests)
        return TranscriptTable(items: rows, revision: UUID(),
                               structureRevision: rows.structure(history: presentation.history),
                               tracker: scroll, onFollowChange: { value in
            if following != value {
                following = value
                unread.update(chat.lines, following: value)
            }
        }, sameContent: ==) { row in
            tableRow(row, presentation: presentation)
                .environmentObject(disclosure)
                .environment(\.findQuery, find?.query ?? "")
                .environment(\.motionEnabled, motion)
        }
        .opacity(transcriptSettled ? 1 : 0)
        .onAppear { settle() }
        .messageJumpTarget(.bot(chat.bot.name), beforeJump: {
            scroll.follow.pause()
            following = false
        }) { anchor in
            if case .chatLine(let id) = anchor { scroll.scrollToID?(AnyHashable(id), .center) }
        }
        .onChange(of: chat.lines.last?.text) { _, _ in
            if following || chat.lines.last?.role == .user { scrollToEnd() }
            if find != nil { find?.refresh(chat.lines) }
        }
        .onChange(of: chat.lines.last?.id) { _, _ in unread.update(chat.lines, following: following) }
        .onChange(of: chat.lines.count) { _, _ in unread.update(chat.lines, following: following) }
        .onChange(of: chat.requests.last?.id) { _, id in
            if id != nil, following { scrollToEnd() }
        }
        .onChange(of: find?.currentMatch) { _, match in
            guard let match else { return }
            scroll.follow.pause()
            following = false
            scroll.scrollToID?(AnyHashable(match.lineId), .center)
        }
        .overlay(alignment: .bottom) {
            if !following {
                ScrollToBottomButton(unread: unread.count) { scrollToEnd(animated: true) }
                    .padding(.bottom, DS.Space.s3)
            }
        }
    }

    @ViewBuilder private func tableRow(_ row: BotTimelineRow, presentation: BotTranscriptPresentation) -> some View {
        Group {
            switch row {
            case .message(let item):
                transcriptRow(item, full: presentation.fullResponses, changed: presentation.changedFiles)
                    .padding(.top, presentation.gaps[item.id] ?? 0)
            case .request(let request):
                ServerRequestRow(chat: chat, identity: identity, request: request).padding(.top, DS.Space.timeline)
            }
        }
        .padding(.horizontal, DS.Space.s5)
        .padding(.top, row.id == presentation.items.first.map({ AnyHashable($0.id) }) ? DS.Space.s4 : 0)
        .padding(.bottom, row.id == (chat.requests.last.map { AnyHashable("request-\($0.id)") }
                                     ?? presentation.lastID.map(AnyHashable.init)) ? DS.Space.s3 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last row (or the last open request card) at the bottom of the view; follows again.
    private func scrollToEnd(animated: Bool = false) {
        scroll.follow.resume()
        if !following { following = true }
        if unread.count > 0 { unread.update(chat.lines, following: true) }
        withDSAnimation(motion && animated, DS.Motion.ease) {
            scroll.scrollToLatest?()
        }
    }

    /// Give the native viewport its initial layout before revealing the last message. Later height
    /// corrections and resize pinning belong to the same native coordinator.
    private func settle() {
        guard !transcriptSettled else { return }
        seedUnreadHistoryIfReady()
        scroll.scrollToLatest?()
        DispatchQueue.main.async {
            scroll.follow.resume()
            scroll.scrollToLatest?()
            following = true
            unread.update(chat.lines, following: true)
            transcriptSettled = true
        }
    }

    private func transcriptRow(_ item: TranscriptItem, full: TranscriptLookup<String>, changed: TranscriptLookup<[ChangedFile]>) -> some View {
        let fromUser: Bool
        let lastId: UUID
        switch item {
        case .line(let l, _): fromUser = l.role == .user; lastId = l.id
        case .tools(let ls, _): fromUser = false; lastId = ls[ls.count - 1].id
        }
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            copyable(row(item), item, full: full)
            // B16: the files a finished turn edited, under its last line.
            if let files = changed[lastId] {
                ChangedFilesCard(files: files).padding(.leading, DS.Size.contentInset)
            }
        }
            .overlay { if find?.currentMatch?.lineId == item.id { FindCurrentRing() } }
            .id(item.id)
            .transition(motion ? .arrive(from: fromUser ? .bottomTrailing : .bottomLeading) : .identity)
    }

    /// B2: Copy message (and Copy full response for a reply in several parts) on hover and in the context menu.
    @ViewBuilder private func copyable<V: View>(_ view: V, _ item: TranscriptItem, full: TranscriptLookup<String>) -> some View {
        if case .line(let line, _) = item, ChatCopy.copyable(line) {
            let bot = chat.bot
            // B3/B4: Edit / Restore / Branch on sent messages, Regenerate / Branch on replies.
            let actions = line.role == .user ? BotChatActions.user(line, chat: chat) : BotChatActions.reply(line, chat: chat)
            view.messageCopyActions(line, fullResponse: full[line.id], onCreateTask: {
                AppModel.shared.composeTask(from: .botChat(text: line.text, fromUser: line.role == .user, bot: bot.name, botTitle: bot.title))
            }, readAloud: ReadAloudItem.reply(line, lines: { [chat] in chat.lines }), actions: actions)  // B17, B3/B4
        } else {
            view
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .line(let line, let header):
            if TranscriptItem.isBotSide(line.role) {
                botSide(header: header, note: line.role == .bot ? (line.interim ? "interim" : (line.streaming ? "streaming" : nil)) : nil,
                        combines: line.role == .bot) {
                    botContent(line)
                }
            } else {
                bubble(line)
            }
        case .tools(let lines, let header):
            botSide(header: header, note: nil, combines: false) { ToolGroupView(lines: lines).padding(.leading, -DS.Space.s2) }
        }
    }

    /// The first bot-side item of a turn carries the avatar and name; the rest line up under its text.
    @ViewBuilder private func botSide<Content: View>(header: Bool, note: String?, combines: Bool = true,
                                                     @ViewBuilder content: () -> Content) -> some View {
        if header {
            // Thought and tool rows hold their own buttons: kept as separate accessibility elements.
            MemberMessage(identity: identity, author: chat.bot.title, time: 0, trailingNote: note,
                          combinesAccessibility: combines) { content() }
        } else {
            content()
                .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
                .padding(.leading, DS.Size.contentInset)
        }
    }

    /// Thought and tool rows have their own hover inset: pulled left so their labels line up with the text.
    @ViewBuilder private func botContent(_ line: ChatLine) -> some View {
        switch line.role {
        case .thought: ThoughtRow(line: line).padding(.leading, -DS.Space.s2)
        case .tool: ToolActivityRow(line: line).padding(.leading, -DS.Space.s2)
        default:
            if let seconds = line.turnDuration, !line.streaming {
                // B5: how long the turn took, under its finished reply.
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    StreamingText(text: line.text, streaming: false, caret: identity.color)
                    TurnDurationLabel(seconds: seconds)
                }
            } else {
                StreamingText(text: line.text, streaming: line.streaming, caret: identity.color)
            }
        }
    }

    /// `empty-state` (new Bot Chat variant, A16): centred in the pane, the bot's own face large (96 pt, as in
    /// Hermes Desktop's `chat-empty.tsx`) over its name and a short hint, so an empty conversation still says
    /// whose it is. No `.fixedSize(vertical:)` on these texts (unlike text inside a ScrollView): the split view
    /// measures the pane at a near-zero width, where a fixed-height text wraps one glyph per line and becomes
    /// the whole window's minimum height, pushing the sidebar, the inspector and the composer off screen
    /// (BotChatLayoutTests).
    private var emptyChat: some View {
        VStack(spacing: DS.Space.s3) {
            AvatarView(identity: identity, size: DS.Size.avatarChatEmpty)
                .padding(.bottom, DS.Space.s1)
                .accessibilityHidden(true)
            Text(chat.bot.title).font(DS.Typeface.titleState).foregroundStyle(DS.Palette.ink)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Text(Self.emptyHint).font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center)
            Text(Self.sharedChatNote)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Size.proseNarrow)
        }
        .padding(DS.Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The empty Bot Chat's hint (Desktop `chatEmpty`).
    nonisolated static let emptyHint = "Say something to get started."

    /// The Bot Chat is the bot's one continuous chat, kept by Hermes (never deleted on quit).
    nonisolated static let sharedChatNote = "This is the bot's one ongoing chat, shared with Hermes Desktop and kept when the app quits. Group chats are separate."

    private var loadingChat: some View {
        EmptyStateView(symbol: "bubble.left.and.text.bubble.right", title: "Opening \(chat.bot.title)'s Bot Chat",
                       message: "Loading the conversation from Hermes.") {
            ProgressView().controlSize(.small).accessibilityLabel("Loading")
        }
    }

    private func failedChat(_ message: String) -> some View {
        EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't open the Bot Chat", message: message) {
            Button("Retry") { chat.open() }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .accessibilityLabel("Retry opening the Bot Chat")
        }
    }

    @ViewBuilder private func bubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .user:
            if let notice = SystemNotice.parse(line.text) {
                SystemNoticeRow(notice: notice, id: line.id)
            } else {
                UserBubble(text: line.text, time: 0, mentionHandles: chat.mentionHandles)  // B1: tagged bots highlighted
            }
        case .bot, .thought, .tool:
            botContent(line)
        case .error:
            BotChatActions.errorCard(line, chat: chat)  // B10
        case .system:
            SystemNoteRow(text: line.text)
        }
    }
}

/// Streamed reply: grows without animating the entire text on every token, with a blinking caret while
/// `streaming`; settles to `MessageBody` (markdown + code) when the turn completes.
struct StreamingText: View {
    let text: String
    let streaming: Bool
    let caret: Color
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        if streaming {
            HStack(alignment: .lastTextBaseline, spacing: DS.Space.s0 / 2) {
                Text(text.isEmpty ? " " : text)
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.proseLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Caret(color: caret)
            }
        } else {
            MessageBody(text: text).equatable()
        }
    }
}

struct Caret: View {
    let color: Color
    @Environment(\.motionEnabled) private var motion
    var body: some View {
        Group {
            if motion {
                PhaseAnimator([true, false]) { on in
                    RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(color).opacity(on ? 1 : 0)
                } animation: { _ in .linear(duration: DS.Motion.caretBlink) }
            } else {
                RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(color)
            }
        }
        .frame(width: DS.Size.caret.width, height: DS.Size.caret.height)
        .accessibilityHidden(true)
    }
}
