import Foundation
import HermesGatewayKit

/// What one room asks of the user, folded from its log and `groups.state`: the approvals its members wait
/// on (D2 badge, D1 approval notifications) and discussions that settled after a member addressed `@user`
/// (D1). Fed by the room's own poller while its pane shows (RoomModel sync) and by `RoomAttentionWatcher`
/// otherwise; events at or below the cursor are duplicates and skipped, so both feeds can overlap.
struct RoomAttention: Equatable {
    struct Mention: Equatable {
        let discussion: String
        let author: String
        let text: String
    }

    /// Highest seq applied; nil until the first batch (the baseline, which never signals).
    private(set) var cursor: Int?
    private(set) var approvals: [RoomApproval] = []
    /// The latest `@user` message per discussion not yet settled.
    private var openMentions: [String: Mention] = [:]
    private var signalled: Set<String> = []

    var baselined: Bool { cursor != nil }

    /// Applies new log events; returns the `@user` discussions that settled in them (none for the baseline).
    @discardableResult
    mutating func apply(events: [RoomEvent], room: RoomSummary?) -> [Mention] {
        let first = cursor == nil
        var out: [Mention] = []
        for e in events.sorted(by: { $0.seq < $1.seq }) where e.seq > (cursor ?? -1) {
            cursor = e.seq
            guard let discussion = e.discussionEventId, !discussion.isEmpty else { continue }
            switch e.kind {
            case "message.member":
                guard let text = e.text, UserMention.mentionsUser(text) else { continue }
                let author = e.actor["display_name"]?.string ?? room?.member(e.memberId)?.title ?? e.memberId ?? "A bot"
                openMentions[discussion] = Mention(discussion: discussion, author: author, text: text)
            case "room.activity":
                let status = e.payload["status"]?.string
                guard status == "settled" || status == "bounded", let m = openMentions.removeValue(forKey: discussion),
                      signalled.insert(discussion).inserted else { continue }
                if !first { out.append(m) }
            default: continue
            }
        }
        return out
    }

    /// Marks the log as read up to `seq` without events (a watcher baseline on a room with no history).
    mutating func baseline(through seq: Int) {
        if cursor == nil { cursor = seq }
    }

    /// The room's current approvals (`driver_status.pending_actions`; none when no worker reports).
    /// Returns those that appeared and those that went since the last call.
    mutating func apply(driver: RoomDriverStatus?) -> (new: [RoomApproval], gone: [RoomApproval]) {
        let now = (driver?.pendingActions ?? []).compactMap { action -> RoomApproval? in
            if case .approval(let a) = action { return a }
            return nil
        }
        let key = { (a: RoomApproval) in "\(a.memberId)|\(a.requestId)" }
        let before = Set(approvals.map(key)), after = Set(now.map(key))
        let new = now.filter { !before.contains(key($0)) }
        let gone = approvals.filter { !after.contains(key($0)) }
        approvals = now
        return (new, gone)
    }
}

/// Keeps `RoomAttention` current for every listed room, including rooms whose pane is not open (their
/// `RoomModel` does not poll): `groups.state` each `interval`, then `groups.log` from the cursor when the
/// room's `latest_seq` moved. The first read of a room starts at most `baselineWindow` events back, so an
/// `@user` message of a discussion that is still running is remembered without replaying the whole log.
@MainActor
final class RoomAttentionWatcher {
    var interval: TimeInterval = 8
    static let baselineWindow = 200
    private(set) var states: [String: RoomAttention] = [:]
    private(set) var rooms: [String: RoomSummary] = [:]
    private var source: RoomSource?
    private var loop: Task<Void, Never>?
    /// New approvals, gone approvals, settled `@user` discussions.
    var onApprovals: ((RoomSummary, _ new: [RoomApproval], _ gone: [RoomApproval]) -> Void)?
    var onMentions: ((RoomSummary, [RoomAttention.Mention]) -> Void)?
    var log: (String) -> Void = { _ in }

    var approvalCounts: [String: Int] { states.mapValues(\.approvals.count).filter { $0.value > 0 } }

    func approval(room: String, member: String, request: String) -> RoomApproval? {
        states[room]?.approvals.first { $0.requestId == request && (member.isEmpty || $0.memberId == member) }
    }

    /// The rooms `groups.list` returned; state of rooms no longer listed goes (their approvals with it).
    func setRooms(_ list: [RoomSummary]) {
        let old = rooms
        rooms = Dictionary(list.map { ($0.roomId, $0) }, uniquingKeysWith: { a, _ in a })
        for id in states.keys.sorted() where rooms[id] == nil {
            let gone = states.removeValue(forKey: id)?.approvals ?? []
            if !gone.isEmpty, let room = old[id] { onApprovals?(room, [], gone) }
        }
    }

    /// `polling: false` (tests) attaches the source without the loop; passes are then run with `pollOnce`.
    func start(source: RoomSource, polling: Bool = true) {
        stop()
        self.source = source
        guard polling else { return }
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        source = nil
    }

    /// Everything goes (connection lost or replaced).
    func reset() {
        stop()
        states = [:]
        rooms = [:]
    }

    /// One pass over every listed room. Errors leave that room as it was until the next pass.
    func pollOnce() async {
        guard let source else { return }
        for id in rooms.keys.sorted() {
            do {
                let snapshot = try await source.roomState(roomId: id)
                guard self.source != nil, rooms[id] != nil else { return }
                var events: [RoomEvent] = []
                let latest = snapshot.room.latestSeq ?? 0
                let cursor = states[id]?.cursor
                if cursor == nil || latest > (cursor ?? 0) {
                    var since = cursor ?? max(0, latest - Self.baselineWindow)
                    for _ in 0..<10 {
                        let page = try await source.roomLog(roomId: id, sinceSeq: since, limit: Self.baselineWindow)
                        events += page.events
                        since = max(since, page.events.last?.seq ?? since)
                        if !page.hasMore || page.events.isEmpty { break }
                    }
                }
                guard self.source != nil, rooms[id] != nil else { return }
                ingest(room: snapshot.room, events: events, driver: snapshot.driver, latestSeq: latest)
            } catch {
                log("room \(id): attention poll failed: \(Redaction.describe(error))")
            }
        }
    }

    /// One sync of a room (its own poller or this watcher).
    func ingest(room: RoomSummary, events: [RoomEvent], driver: RoomDriverStatus?, latestSeq: Int? = nil) {
        guard rooms[room.roomId] != nil else { return }
        var state = states[room.roomId] ?? RoomAttention()
        let mentions = state.apply(events: events, room: room)
        if let latestSeq { state.baseline(through: latestSeq) }
        let (new, gone) = state.apply(driver: driver)
        states[room.roomId] = state
        if !new.isEmpty || !gone.isEmpty { onApprovals?(room, new, gone) }
        if !mentions.isEmpty { onMentions?(room, mentions) }
    }
}
