import HermesGatewayKit
import SwiftUI

/// B4: a branch opened beside the Bot Chat, read-write. It is its own stored session of the bot (made by
/// `session.branch` from a message), NOT the canonical Bot Chat: the sidebar keeps one chat per bot, and the
/// branch is listed under the bot's recent sessions (Open Recent Session) once it has been created. Closing
/// the sheet only detaches; the conversation stays in Hermes.
struct BranchChatSheet: View {
    @ObservedObject var chat: ChatModel
    let onClose: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @StateObject private var disclosure = DisclosureStore()
    @Environment(\.motionEnabled) private var motion

    static let size = CGSize(width: 680, height: 600)

    private var identity: BotIdentity { avatars.identity(profile: chat.bot.name, title: chat.bot.title) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            ChatComposer(chat: chat, identity: identity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DS.Palette.window)
        .environmentObject(disclosure)
        .chatSheets(chat, motion: motion)
    }

    private var header: some View {
        HStack(spacing: DS.Space.gutter) {
            AvatarView(identity: identity, size: DS.Size.avatarHero)
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                Text(chat.branchTitle ?? "Branch").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text(Self.subtitle(bot: chat.bot.title)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Close", action: onClose)
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.Space.s5).padding(.vertical, DS.Space.s3)
    }

    nonisolated static func subtitle(bot: String) -> String {
        "Branch of \(bot)'s Bot Chat · kept in Hermes under Open Recent Session"
    }

    @ViewBuilder private var content: some View {
        switch chat.phase {
        case .idle, .loading:
            EmptyStateView(symbol: "arrow.triangle.branch", title: "Opening the branch", message: "Loading it from Hermes.") {
                ProgressView().controlSize(.small).accessibilityLabel("Loading")
            }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't open the branch", message: message) { EmptyView() }
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                    ForEach(TranscriptItem.build(chat.lines)) { item in row(item).id(item.id) }
                    ServerRequestCards(chat: chat, identity: identity)
                }
                .padding(.horizontal, DS.Space.s5).padding(.vertical, DS.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .line(let line, let header):
            switch line.role {
            case .user:
                if let notice = SystemNotice.parse(line.text) { SystemNoticeRow(notice: notice, id: line.id) } else {
                    UserBubble(text: line.text, time: 0)
                        .messageCopyActions(line, fullResponse: nil, actions: BotChatActions.user(line, chat: chat))
                }
            case .system:
                SystemNoteRow(text: line.text)
            case .error:
                BotChatActions.errorCard(line, chat: chat)
            case .bot, .thought, .tool:
                botSide(header: header) {
                    switch line.role {
                    case .thought: ThoughtRow(line: line).padding(.leading, -DS.Space.s2)
                    case .tool: ToolActivityRow(line: line).padding(.leading, -DS.Space.s2)
                    default:
                        StreamingText(text: line.text, streaming: line.streaming, caret: identity.color)
                            .messageCopyActions(line, fullResponse: nil, actions: BotChatActions.reply(line, chat: chat))
                    }
                }
            }
        case .tools(let lines, let header):
            botSide(header: header) { ToolGroupView(lines: lines).padding(.leading, -DS.Space.s2) }
        }
    }

    @ViewBuilder private func botSide<Content: View>(header: Bool, @ViewBuilder content: () -> Content) -> some View {
        if header {
            MemberMessage(identity: identity, author: chat.bot.title, time: 0, combinesAccessibility: false) { content() }
        } else {
            content().frame(maxWidth: DS.Size.memberWidth, alignment: .leading).padding(.leading, DS.Size.contentInset)
        }
    }
}

/// The per-message actions and the error card both chat surfaces share (Bot Chat and a branch sheet).
@MainActor enum BotChatActions {
    /// A sent message: Edit, Restore from Here and (in the Bot Chat) Branch into New Chat.
    static func user(_ line: ChatLine, chat: ChatModel) -> [MessageAction] {
        guard ChatModel.isPrompt(line) else { return [] }
        let ok = chat.canRewind
        var out = [
            MessageAction(title: "Edit Message…", symbol: "pencil", hover: true, enabled: ok) { chat.beginEdit(line.id) },
            MessageAction(title: "Restore from Here…", symbol: "clock.arrow.circlepath", enabled: ok) { chat.restore(from: line.id) },
        ]
        if !chat.isBranch {
            out.append(MessageAction(title: "Branch into New Chat", symbol: "arrow.triangle.branch", enabled: ok) { chat.branchFrom(line.id) })
        }
        return out
    }

    /// A settled reply: Regenerate and (in the Bot Chat) Branch into New Chat.
    static func reply(_ line: ChatLine, chat: ChatModel) -> [MessageAction] {
        guard line.role == .bot, !line.streaming else { return [] }
        let ok = chat.canRewind
        var out = [MessageAction(title: "Regenerate", symbol: "arrow.clockwise", hover: true, enabled: ok) { chat.regenerate(from: line.id) }]
        if !chat.isBranch {
            out.append(MessageAction(title: "Branch into New Chat", symbol: "arrow.triangle.branch", enabled: ok) { chat.branchFrom(line.id) })
        }
        return out
    }

    /// An error line as its card (B10); a line without failure details stays a plain error line.
    @ViewBuilder static func errorCard(_ line: ChatLine, chat: ChatModel) -> some View {
        if let plan = chat.recovery(for: line) {
            ErrorCardRow(line: line, plan: plan, canAct: chat.canRewind,
                         onRetry: { chat.retry(errorLine: line.id) },
                         onSwitchProvider: { chat.switchProvider() },
                         onCopyDiagnostics: { chat.copyDiagnostics(line.id) },
                         onDismiss: { chat.dismissError(line.id) })
        } else {
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.iconSmall)
                Text(line.text).textSelection(.enabled)
            }
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .padding(.leading, DS.Size.contentInset)
        }
    }
}
