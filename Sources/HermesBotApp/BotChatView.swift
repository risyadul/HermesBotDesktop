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
        .overlay { if dropTargeted { dropHighlight } }
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
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Older bubbles lazy, the ones seen on open laid out eagerly (EagerTail).
                let lines = chat.lines
                let tail = EagerTail.start(of: lines) { EagerTail.lines($0.text) }
                VStack(alignment: .leading, spacing: DS.Space.timeline) {
                    LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                        ForEach(lines[..<tail]) { line in transcriptRow(line) }
                    }
                    ForEach(lines[tail...]) { line in transcriptRow(line) }
                    ServerRequestCards(chat: chat, identity: identity)
                }
                .padding(.horizontal, DS.Space.s5).padding(.top, DS.Space.s4).padding(.bottom, DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion ? DS.Motion.spring : nil, value: chat.lines.map(\.id))
                .animation(motion ? DS.Motion.spring : nil, value: chat.requests.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.lines.last?.text) { _, _ in
                if let id = chat.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: chat.requests.last?.id) { _, id in
                if let id { proxy.scrollTo("request-\(id)", anchor: .bottom) }
            }
        }
    }

    private func transcriptRow(_ line: ChatLine) -> some View {
        bubble(line).id(line.id)
            .transition(motion ? .arrive(from: line.role == .user ? .bottomTrailing : .bottomLeading) : .identity)
    }

    /// `empty-state` (new Bot Chat variant): centred in the pane, the bot's own avatar instead of a symbol.
    /// No `.fixedSize(vertical:)` on these texts (unlike text inside a ScrollView): the split view measures
    /// the pane at a near-zero width, where a fixed-height text wraps one glyph per line and becomes the
    /// whole window's minimum height, pushing the sidebar, the inspector and the composer off screen
    /// (BotChatLayoutTests).
    private var emptyChat: some View {
        VStack(spacing: DS.Space.s3) {
            AvatarView(identity: identity, size: DS.Size.avatarEmpty)
                .padding(.bottom, DS.Space.s1)
            Text("Chat with \(chat.bot.title)").font(DS.Typeface.titleState).foregroundStyle(DS.Palette.ink)
            if let d = chat.bot.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                Text(d).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DS.Size.proseNarrow)
            }
            Text(Self.sharedChatNote)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Size.proseNarrow)
        }
        .padding(DS.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    private var dropHighlight: some View {
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

    @ViewBuilder private func bubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .user:
            UserBubble(text: line.text, time: 0)
        case .bot:
            MemberMessage(identity: identity, author: chat.bot.title, time: 0,
                          trailingNote: line.interim ? "interim" : (line.streaming ? "streaming" : nil)) {
                StreamingText(text: line.text, streaming: line.streaming, caret: identity.color)
            }
        case .error:
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.iconSmall)
                Text(line.text).textSelection(.enabled)
            }
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .padding(.leading, DS.Size.contentInset)
        case .tool:
            ToolActivityRow(line: line)
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
