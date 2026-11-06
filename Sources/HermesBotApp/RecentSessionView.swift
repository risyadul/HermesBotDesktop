import HermesGatewayKit
import SwiftUI

/// "Open Recent Session" (A17): the bot's newest conversation other than its Bot Chat (a routine run, a
/// side thread started in Hermes Desktop or the CLI), shown read-only in a sheet. The transcript comes from
/// the read-only REST route (`SessionTranscriptREST`): no session is resumed, nothing is sent or written.
@MainActor
final class RecentSessionModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case loading
        case loaded([ChatLine])
        case failed(String)
    }

    typealias Reader = @Sendable (_ sessionId: String, _ profile: String) async throws -> [ChatHistoryMessage]

    let bot: Bot
    let session: BotSessionSummary
    @Published private(set) var phase: Phase = .loading
    nonisolated var id: String { session.id }
    private let reader: Reader

    init(bot: Bot, session: BotSessionSummary, reader: @escaping Reader) {
        self.bot = bot; self.session = session; self.reader = reader
    }

    func load() async {
        phase = .loading
        do {
            phase = .loaded(Self.lines(try await reader(session.id, bot.name)))
        } catch {
            phase = .failed((error as? SessionTranscriptREST.Failure)?.description ?? Redaction.describe(error))
        }
    }

    /// History rows as transcript lines (the Bot Chat's own seeding: bubbles, Thoughts, settled tool rows).
    nonisolated static func lines(_ history: [ChatHistoryMessage]) -> [ChatLine] {
        var t = ChatTranscript()
        t.seed(history: history)
        return t.lines
    }

    /// The sheet's title: the session's own title, else a neutral name.
    nonisolated static func title(_ session: BotSessionSummary) -> String {
        let t = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled session" : t
    }

    /// The live reader for a backend's REST access.
    static func reader(_ access: SessionRESTAccess?) -> Reader {
        { id, profile in try await SessionTranscriptREST.messages(access, sessionId: id, profile: profile) }
    }
}

struct RecentSessionView: View {
    @ObservedObject var model: RecentSessionModel
    let onClose: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @StateObject private var disclosure = DisclosureStore()

    private var identity: BotIdentity { avatars.identity(profile: model.bot.name, title: model.bot.title) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            HStack {
                Text("Read-only. Continue this conversation in Hermes Desktop or the CLI.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .lineLimit(2)
                Spacer(minLength: DS.Space.s2)
                Button("Close", action: onClose)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.s5).padding(.vertical, DS.Space.s3)
        }
        .frame(width: DS.Size.recentSessionSheet.width, height: DS.Size.recentSessionSheet.height)
        .background(DS.Palette.window)
        .environmentObject(disclosure)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.gutter) {
            AvatarView(identity: identity, size: DS.Size.avatarHero)
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                Text(RecentSessionModel.title(model.session))
                    .font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text(subtitle).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s5).padding(.vertical, DS.Space.s3)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let age = RoomDigest.age(of: model.session.lastActive, now: Date())
        return "\(model.bot.title) · read-only" + (age.isEmpty ? "" : " · \(age == "now" ? "just now" : age + " ago")")
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "Loading the session", message: "Reading it from Hermes.") {
                ProgressView().controlSize(.small).accessibilityLabel("Loading")
            }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't show this session", message: message) {
                Button("Try Again") { Task { await model.load() } }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        case .loaded(let lines) where lines.isEmpty:
            EmptyStateView(symbol: "text.bubble", title: "No messages", message: "This session has nothing to show yet.") { EmptyView() }
        case .loaded(let lines):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                    ForEach(TranscriptItem.build(lines)) { item in row(item) }
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
                if let notice = SystemNotice.parse(line.text) { SystemNoticeRow(notice: notice, id: line.id) } else { UserBubble(text: line.text, time: 0) }
            case .system:
                SystemNoteRow(text: line.text)
            case .error:
                Text(line.text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                    .padding(.leading, DS.Size.contentInset)
            case .bot, .thought, .tool:
                botSide(header: header) { botContent(line) }
            }
        case .tools(let lines, let header):
            botSide(header: header) { ToolGroupView(lines: lines).padding(.leading, -DS.Space.s2) }
        }
    }

    @ViewBuilder private func botSide<Content: View>(header: Bool, @ViewBuilder content: () -> Content) -> some View {
        if header {
            MemberMessage(identity: identity, author: model.bot.title, time: 0, combinesAccessibility: false) { content() }
        } else {
            content().frame(maxWidth: DS.Size.memberWidth, alignment: .leading).padding(.leading, DS.Size.contentInset)
        }
    }

    @ViewBuilder private func botContent(_ line: ChatLine) -> some View {
        switch line.role {
        case .thought: ThoughtRow(line: line).padding(.leading, -DS.Space.s2)
        case .tool: ToolActivityRow(line: line).padding(.leading, -DS.Space.s2)
        default: MessageBody(text: line.text).equatable()
        }
    }
}
