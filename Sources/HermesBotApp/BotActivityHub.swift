import Foundation
import HermesGatewayKit

/// Bot rows' live state (A4, A6, A17): last activity, preview and age from one `profiles.list
/// {include_sessions: true}` per pass (never by opening a chat), the unread dot, and the "needs attention"
/// badge.
///
/// Unread follows Desktop's watermark (`roster-actions.ts` `trackInboundActivity`): a bot is unread when its
/// last activity moved past what the user has seen. The seen mark is per bot, persisted locally, seeded the
/// first time a bot is seen (old history never starts unread), and moved to the bot's latest activity when
/// its Bot Chat is opened and on every pass while it stays on screen.
@MainActor
final class BotActivityHub: ObservableObject {
    @Published private(set) var activity: [String: BotRosterActivity] = [:]
    /// Per bot: the activity stamp (epoch seconds) the user has seen.
    @Published private(set) var readThrough: [String: Double]
    /// Per bot: the latest classified failure, until its next good turn. Never persisted.
    @Published private(set) var attention: [String: BotAttention] = [:]

    typealias Fetch = @Sendable () async throws -> [String: BotRosterActivity]
    /// The bot whose Bot Chat is on screen (its activity is seen as it happens).
    var onScreen: () -> String? = { nil }
    var log: (String) -> Void = { AppModel.shared.log($0) }

    static let readKey = "hba.botReadThrough"
    static let interval: TimeInterval = 10

    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        readThrough = (defaults.dictionary(forKey: Self.readKey) as? [String: Double]) ?? [:]
    }

    // MARK: reading

    func lastActive(_ bot: String) -> Double { activity[bot]?.lastActive ?? 0 }

    /// The unread dot. Never on the bot on screen.
    func isUnread(_ bot: String, onScreen: Bool) -> Bool {
        guard !onScreen, let stamp = activity[bot]?.lastActive, stamp > 0 else { return false }
        return stamp > (readThrough[bot] ?? stamp)
    }

    // MARK: feeding

    /// One pass's answer (the whole roster): replaces every bot's activity, seeds the seen mark of bots seen
    /// for the first time, drops the marks and badges of bots no longer listed (deleted), and marks the
    /// on-screen bot read.
    func apply(_ listed: [String: BotRosterActivity]) {
        if activity != listed { activity = listed }
        for bot in attention.keys where listed[bot] == nil { attention[bot] = nil }
        var marks = listed.isEmpty ? readThrough : readThrough.filter { listed[$0.key] != nil }
        for (bot, a) in listed where marks[bot] == nil && a.lastActive > 0 { marks[bot] = a.lastActive }
        if let shown = onScreen(), let stamp = listed[shown]?.lastActive, stamp > (marks[shown] ?? 0) { marks[shown] = stamp }
        saveMarks(marks)
    }

    /// The bot's Bot Chat was opened: everything up to its latest activity is seen. Monotonic.
    func markRead(_ bot: String) {
        guard let stamp = activity[bot]?.lastActive, stamp > (readThrough[bot] ?? 0) else { return }
        var marks = readThrough
        marks[bot] = stamp
        saveMarks(marks)
    }

    private func saveMarks(_ marks: [String: Double]) {
        guard marks != readThrough else { return }
        readThrough = marks
        defaults.set(marks, forKey: Self.readKey)
    }

    // MARK: needs attention

    /// A failed turn of `bot` (Bot Chat, a Group Chat member turn): badges it when the failure classifies,
    /// latest failure wins; a transient one leaves the badge as it was.
    func noteFailure(_ bot: String, message: String?, reasonCode: String? = nil) {
        guard let a = BotAttention(failure: message, reasonCode: reasonCode) else { return }
        attention[bot] = a
        log("bot \(bot) needs attention: \(a.reason.rawValue)")
    }

    /// A good turn clears the badge.
    func clearAttention(_ bot: String) {
        if attention[bot] != nil { attention[bot] = nil }
    }

    /// A Bot Chat turn event (`ChatModel.onTurnEvent`): a failed turn or one that completed with an error
    /// line notes it, a clean completion clears it.
    func turnEvent(_ type: String, bot: String, lines: [ChatLine]) {
        switch Self.attentionUpdate(type, lines: lines) {
        case .note(let text): noteFailure(bot, message: text)
        case .clear: clearAttention(bot)
        case .none: break
        }
    }

    enum AttentionUpdate: Equatable { case note(String), clear, none }

    nonisolated static func attentionUpdate(_ type: String, lines: [ChatLine]) -> AttentionUpdate {
        switch type {
        case "turn.failed":
            return lines.last(where: { $0.role == .error }).map { .note($0.text) } ?? .none
        case "message.complete":
            if let last = lines.last, last.role == .error { return .note(last.text) }
            return .clear
        default:
            return .none
        }
    }

    /// New Group Chat log events: a member's `turn.failed` notes its bot (typed `reason_code` first), a
    /// settled turn clears it.
    func ingest(room: RoomSummary, events: [RoomEvent]) {
        for e in events {
            guard let profile = room.member(e.memberId)?.profile else { continue }
            switch e.kind {
            case "turn.failed": noteFailure(profile, message: e.payload["error"]?.string, reasonCode: e.payload["reason_code"]?.string)
            case "turn.settled": clearAttention(profile)
            default: break
            }
        }
    }

    // MARK: polling

    func start(fetch: @escaping Fetch) {
        stop()
        let gen = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                await self.refresh(fetch, generation: gen)
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    /// Stops polling and drops what the connection showed (seen marks are kept).
    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        activity = [:]
        attention = [:]
    }

    /// One pass. A failure is logged; the rows keep what they showed and the next pass tries again.
    func refresh(_ fetch: Fetch, generation gen: Int? = nil) async {
        let gen = gen ?? generation
        do {
            let listed = try await fetch()
            guard gen == generation else { return }
            apply(listed)
        } catch {
            log("bot activity: profiles.list failed: \(Redaction.describe(error))")
        }
    }

    /// The live fetch for a gateway connection.
    static func fetch(_ client: GatewayClient) -> Fetch {
        { try await BotRosterActivity.fetch { method, params in try await client.call(method, params) } }
    }
}
