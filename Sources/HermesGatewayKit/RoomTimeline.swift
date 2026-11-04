import Foundation

/// One rendered row of a Group Chat.
public struct RoomLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case user, member, status, error }
    /// The event seq (unique per room).
    public let id: Int
    public let kind: Kind
    public let author: String
    public let text: String
}

/// How far the discussion opened by one user message has got.
public enum DiscussionPhase: Sendable, Equatable {
    /// No `room.activity` terminal yet and not behind a stop fence: bots may still answer.
    case pending
    /// `room.activity {status: settled|bounded, reason_code}` for this discussion.
    case settled(reason: String)
    case bounded(reason: String)
    /// A `room.stop_requested` fence with a higher seq: the policy never plans it again
    /// (`hosted_room_discussion.py` `_pending_discussion`).
    case stopped
    /// A later user message in the same thread replaced it before it settled.
    case superseded
}

/// The durable room log as the app holds it, plus everything derived from it. UI-free and
/// unit tested.
///
/// Update model (docs/gateway-contract.md §7): rooms have NO WS push. The client polls
/// `groups.log {since_seq: cursor}` (following `has_more`) and `groups.state`. Events are
/// append-only with a per-room monotonic `seq`, so applying pages is idempotent: an event at or
/// below the cursor is a duplicate and is skipped.
public struct RoomTimeline: Sendable, Equatable {
    public private(set) var events: [RoomEvent] = []
    /// Highest seq applied; the next `groups.log` uses `since_seq = cursor`.
    public private(set) var cursor = 0
    /// Server's latest seq at the last page (≥ cursor).
    public private(set) var latestSeq = 0
    /// Set when a page skipped seqs (should not happen: seq is contiguous per room). The caller
    /// then reloads from 0.
    public private(set) var gapDetected = false

    public init() {}

    /// Applies one page; returns how many new events were appended.
    @discardableResult
    public mutating func apply(_ page: RoomLogPage) -> Int {
        var added = 0
        for e in page.events.sorted(by: { $0.seq < $1.seq }) where e.seq > cursor {
            if e.seq != cursor + 1 { gapDetected = true }
            events.append(e)
            cursor = e.seq
            added += 1
        }
        latestSeq = max(latestSeq, page.latestSeq, cursor)
        return added
    }

    /// Whether the server holds events this timeline has not applied yet.
    public var behind: Bool { latestSeq > cursor }

    // MARK: - derived state

    /// Highest seq of a `room.stop_requested` fence.
    public var stoppedThroughSeq: Int { events.last(where: { $0.kind == "room.stop_requested" })?.seq ?? 0 }

    public var userMessages: [RoomEvent] { events.filter { $0.kind == "message.user" } }

    public func phase(of user: RoomEvent) -> DiscussionPhase {
        if let a = events.last(where: { $0.kind == "room.activity" && $0.discussionEventId == user.eventId }) {
            let reason = a.payload["reason_code"]?.string ?? ""
            switch a.payload["status"]?.string {
            case "settled": return .settled(reason: reason)
            case "bounded": return .bounded(reason: reason)
            default: break
            }
        }
        // Only the latest user message per thread is ever pending: an older one is superseded.
        if user.seq < stoppedThroughSeq { return .stopped }
        if let later = userMessages.last(where: { $0.threadId == user.threadId }), later.seq > user.seq { return .superseded }
        return .pending
    }

    /// True while the latest user message (per thread) still has bots to hear from.
    public var awaitingDiscussion: Bool {
        var latest: [String: RoomEvent] = [:]
        for e in userMessages { latest[e.threadId ?? ""] = e }
        return latest.values.contains { phase(of: $0) == .pending }
    }

    /// `turn.settled|failed|cancelled|deferred` events in the log.
    public var terminalEvents: Int { events.filter { $0.kind.hasPrefix("turn.") }.count }

    /// Member turns of one discussion, keyed by `(round_index, member_id)`, with their terminal kind.
    public func terminals(of user: RoomEvent) -> [RoomEvent] {
        events.filter { $0.kind.hasPrefix("turn.") && $0.discussionEventId == user.eventId }
    }

    /// Rows for the UI. Member display names come from the roster when the event lacks one.
    public func lines(room: RoomSummary?) -> [RoomLine] {
        func name(_ memberId: String?) -> String {
            room?.member(memberId)?.title ?? memberId ?? "bot"
        }
        return events.compactMap { e -> RoomLine? in
            switch e.kind {
            case "message.user":
                return RoomLine(id: e.seq, kind: .user, author: "You", text: e.text ?? "")
            case "message.member":
                let author = e.actor["display_name"]?.string ?? name(e.memberId)
                return RoomLine(id: e.seq, kind: .member, author: author, text: e.text ?? "")
            case "turn.settled":
                // The reply itself is the message.member row; only a pass is worth a line.
                return e.payload["passed"]?.bool == true
                    ? RoomLine(id: e.seq, kind: .status, author: name(e.memberId), text: "passed (no reply)") : nil
            case "turn.failed":
                let err = e.payload["error"]?.string ?? "failed"
                return RoomLine(id: e.seq, kind: .error, author: name(e.memberId), text: "turn failed: \(err)")
            case "turn.cancelled":
                return RoomLine(id: e.seq, kind: .status, author: name(e.memberId),
                                text: "turn cancelled" + (e.payload["reason"]?.string.map { " (\($0))" } ?? ""))
            case "turn.deferred":
                return RoomLine(id: e.seq, kind: .status, author: name(e.memberId),
                                text: "turn deferred" + (e.payload["reason"]?.string.map { " (\($0))" } ?? "") + ": Retry re-runs it")
            case "room.activity":
                let status = e.payload["status"]?.string ?? "?", reason = e.payload["reason_code"]?.string ?? ""
                let text = status == "settled" ? "discussion settled" : status == "bounded" ? "discussion ended (limit)" : status
                return RoomLine(id: e.seq, kind: .status, author: "room", text: reason.isEmpty ? text : "\(text) · \(reason)")
            case "room.stop_requested":
                return RoomLine(id: e.seq, kind: .status, author: "room", text: "stop requested")
            case "room.renamed":
                return RoomLine(id: e.seq, kind: .status, author: "room", text: "renamed to \(e.payload["name"]?.string ?? "?")")
            default:
                return RoomLine(id: e.seq, kind: .status, author: "room", text: e.kind)
            }
        }
    }
}

/// Send gate for the Group Chat composer. Unlike 1:1 chat, a user may post while bots are still
/// working (the server supersedes the older message in the same thread), so the gate blocks only a
/// second submit while one `groups.send` is in flight, and any submit once the room is being
/// disbanded or is gone. Callers clear their draft only when `beginSend` returns non-nil; every
/// submit path (Return, the Send button, scripts) goes through it, so a disabled button is not the
/// gate.
public struct RoomComposer: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case open
        /// `groups.disband` in flight: nothing is posted; back to `open` if it fails.
        case closing
        /// Disbanded (by this client or found retired): final.
        case closed
    }

    public private(set) var sending = false
    public private(set) var availability: Availability = .open
    public init() {}

    /// Whether the room accepts actions (send, stop, retry, approve, disband).
    public var isOpen: Bool { availability == .open }
    public var canSend: Bool { isOpen && !sending }

    /// Returns the trimmed text to send, or nil (nothing changes) when blank, too long, busy or the
    /// room is closing/closed.
    public mutating func beginSend(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty, text.utf8.count <= RoomComposer.maxTextBytes else { return nil }
        sending = true
        return text
    }

    public mutating func finishSend() { sending = false }

    /// Starts a disband. False when one is already in flight or the room is closed.
    public mutating func beginClosing() -> Bool {
        guard availability == .open else { return false }
        availability = .closing
        return true
    }

    /// The disband failed: the room is usable again. No-op unless closing.
    public mutating func reopen() { if availability == .closing { availability = .open } }

    /// The room is disbanded/retired for good.
    public mutating func close() { availability = .closed }

    /// `text` ≤ 64 KiB (`hosted_room_discussion.py:198-203`).
    public static let maxTextBytes = 64 * 1024
}

/// Poll cadence. The server's own room worker polls every 0.25 s while active and 5 s idle
/// (`hosted_room_service.py:30-31`); a client needs no more than ~1 s while something can change.
public enum RoomPollPolicy {
    public static let active: TimeInterval = 1.0
    public static let idle: TimeInterval = 5.0

    /// Fast while a task is queued/running/stopping, while the latest user message has not settled
    /// (the next member turn is admitted between polls), while a finished task's `turn.*` event is not
    /// in the log yet (e.g. right after Stop: the task is `cancelled` before `turn.cancelled` is
    /// appended), or while the log is known to be behind.
    public static func interval(driver: RoomDriverStatus?, timeline: RoomTimeline) -> TimeInterval {
        if timeline.behind { return 0 }
        if busy(driver: driver, timeline: timeline) { return active }
        return idle
    }

    /// Something in the room can still change without user action.
    public static func busy(driver: RoomDriverStatus?, timeline: RoomTimeline) -> Bool {
        driver?.working == true || driver?.blocked == true || timeline.awaitingDiscussion
            || publicationPending(driver: driver, timeline: timeline)
    }

    public static func publicationPending(driver: RoomDriverStatus?, timeline: RoomTimeline) -> Bool {
        (driver?.terminalTasks ?? 0) > timeline.terminalEvents
    }
}

/// Anything that can answer `groups.log` / `groups.state` (the live `GroupsAPI`, or a fake in tests).
public protocol RoomSource: Sendable {
    func roomLog(roomId: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPage
    func roomState(roomId: String) async throws -> RoomStateSnapshot
}

extension GroupsAPI: RoomSource {}

public enum RoomSync {
    /// One sync pass: read the log from the timeline's cursor until `has_more` is false (bounded by
    /// `maxPages`), then the room state. A detected seq gap restarts from 0 once.
    public static func refresh(_ source: RoomSource, roomId: String, timeline: RoomTimeline,
                               maxPages: Int = 20) async throws -> (timeline: RoomTimeline, state: RoomStateSnapshot) {
        var t = timeline
        var pages = 0
        while pages < maxPages {
            let page = try await source.roomLog(roomId: roomId, sinceSeq: t.cursor, limit: 200)
            t.apply(page)
            pages += 1
            if t.gapDetected && timeline.cursor > 0 {
                return try await refresh(source, roomId: roomId, timeline: RoomTimeline(), maxPages: maxPages)
            }
            if !page.hasMore { break }
        }
        let state = try await source.roomState(roomId: roomId)
        return (t, state)
    }
}
