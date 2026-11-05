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
    @Environment(\.motionEnabled) private var motion

    private var identity: BotIdentity { avatars.identity(profile: chat.bot.name, title: chat.bot.title) }

    var body: some View {
        VStack(spacing: 0) {
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
            chat.addAttachments(files)
            return true
        } isTargeted: { dropTargeted = $0 && chat.isReady }
        .task { chat.open() }
        .navigationTitle(chat.bot.title)
        .navigationSubtitle("@\(chat.bot.name)" + (chat.bot.model.map { " · \($0)" } ?? ""))
        .toolbar {
            ToolbarItem(placement: .navigation) { AvatarView(identity: identity, size: DS.Size.avatarHero) }
            ToolbarItem(placement: .primaryAction) {  // A15, RoutinesView.swift
                RoutinesToolbarButton(bot: chat.bot) { chat.showRoutines() }
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
        // Presented from the pane (in the window's view hierarchy), not from the toolbar item that opens it.
        .motionSheet(isPresented: $chat.routinesShown, motion: motion) {
            RoutinesSheet(bot: chat.bot, context: .current(), onClose: { chat.routinesShown = false })
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Older rows lazy, the ones seen on open laid out eagerly (EagerTail).
                let items = TranscriptItem.build(chat.lines)
                let tail = EagerTail.start(of: items) { $0.approximateLines }
                let gaps = TranscriptItem.gaps(items)
                let full = ChatCopy.fullResponses(chat.lines)
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items[..<tail]) { item in transcriptRow(item, full: full).padding(.top, gaps[item.id] ?? 0) }
                    }
                    ForEach(items[tail...]) { item in transcriptRow(item, full: full).padding(.top, gaps[item.id] ?? 0) }
                    ServerRequestCards(chat: chat, identity: identity)
                        .padding(.top, chat.requests.isEmpty ? 0 : DS.Space.timeline)
                }
                .padding(.horizontal, DS.Space.s5).padding(.top, DS.Space.s4).padding(.bottom, DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion ? DS.Motion.spring : nil, value: chat.lines.map(\.id))
                .animation(motion ? DS.Motion.spring : nil, value: chat.requests.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .environmentObject(disclosure)
            .opacity(transcriptSettled ? 1 : 0)
            .onAppear { settle(proxy) }
            .onChange(of: chat.lines.last?.text) { _, _ in
                if let id = TranscriptItem.build(chat.lines).last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: chat.requests.last?.id) { _, id in
                if let id { proxy.scrollTo("request-\(id)", anchor: .bottom) }
            }
        }
    }

    /// Reopening a long Bot Chat first drew it some rows above the end, then jumped down once the eagerly laid
    /// out tail had its real heights (the bottom anchor works from estimates on the first pass). The transcript
    /// is scrolled to its last row, again on the next runloop turn after that layout, and only then shown.
    private func settle(_ proxy: ScrollViewProxy) {
        let last = TranscriptItem.build(chat.lines).last?.id
        if let last { proxy.scrollTo(last, anchor: .bottom) }
        DispatchQueue.main.async {
            if let last { proxy.scrollTo(last, anchor: .bottom) }
            transcriptSettled = true
        }
    }

    private func transcriptRow(_ item: TranscriptItem, full: [UUID: String]) -> some View {
        let fromUser: Bool
        if case .line(let l, _) = item { fromUser = l.role == .user } else { fromUser = false }
        return copyable(row(item), item, full: full).id(item.id)
            .transition(motion ? .arrive(from: fromUser ? .bottomTrailing : .bottomLeading) : .identity)
    }

    /// B2: Copy message (and Copy full response for a reply in several parts) on hover and in the context menu.
    @ViewBuilder private func copyable<V: View>(_ view: V, _ item: TranscriptItem, full: [UUID: String]) -> some View {
        if case .line(let line, _) = item, ChatCopy.copyable(line) {
            let bot = chat.bot
            view.messageCopyActions(line, fullResponse: full[line.id], onCreateTask: {
                AppModel.shared.composeTask(from: .botChat(text: line.text, fromUser: line.role == .user, bot: bot.name, botTitle: bot.title))
            })
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
        default: StreamingText(text: line.text, streaming: line.streaming, caret: identity.color)
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
            if let notice = SystemNotice.parse(line.text) { SystemNoticeRow(notice: notice, id: line.id) } else { UserBubble(text: line.text, time: 0) }
        case .bot, .thought, .tool:
            botContent(line)
        case .error:
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.iconSmall)
                Text(line.text).textSelection(.enabled)
            }
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .padding(.leading, DS.Size.contentInset)
        case .system:
            SystemNoteRow(text: line.text)
        }
    }
}

/// Streamed reply: grows with an opacity content transition and a blinking caret in the bot colour while
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
                    .contentTransition(.opacity)
                    .animation(motion ? DS.Motion.stream : nil, value: text)
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
