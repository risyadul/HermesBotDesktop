import Foundation

// M2 Group Chat: typed views over the hosted-room `groups.*` wire shapes
// (`tui_gateway/methods_groups.py`, rows from `gateway/hosted_rooms.py` `_room_from_row` /
// `_event_from_row`, driver status from `tui_gateway/hosted_room_service.py` `status`).
// Shapes stay lenient: unknown keys are ignored, so a newer backend does not break decoding.

/// One room member (`members[]` of a room row; `gateway/hosted_room_discussion.py:233-276`).
public struct RoomMember: Sendable, Hashable, Identifiable {
    public var id: String { memberId }
    public let memberId: String
    public let profile: String
    public let handle: String
    public let displayName: String?

    public var title: String { (displayName?.isEmpty == false ? displayName : nil) ?? handle }

    public init(memberId: String, profile: String, handle: String, displayName: String? = nil) {
        self.memberId = memberId; self.profile = profile; self.handle = handle; self.displayName = displayName
    }

    init?(_ v: JSONValue) {
        guard let id = v["member_id"]?.string, let profile = v["profile"]?.string else { return nil }
        self.init(memberId: id, profile: profile, handle: v["handle"]?.string ?? id, displayName: v["display_name"]?.string)
    }

    /// Identifier rule for `member_id`/`profile`/`handle`/`room_id`/`thread_id`/`event_id`
    /// (`^[A-Za-z0-9][A-Za-z0-9._:-]*$`, ≤128 chars).
    public static func isIdentifier(_ s: String) -> Bool {
        guard (1...128).contains(s.count), let first = s.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The roster entry the app uses for one bot: `member_id` = `handle` = profile name.
    /// Handles `all`/`everyone` are reserved by the server; such a profile cannot join.
    public static func forBot(_ bot: Bot) -> RoomMember? {
        guard isIdentifier(bot.name), !["all", "everyone"].contains(bot.name.lowercased()) else { return nil }
        return RoomMember(memberId: bot.name, profile: bot.name, handle: bot.name, displayName: bot.displayName)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["member_id": .string(memberId), "profile": .string(profile), "handle": .string(handle)]
        if let displayName, !displayName.isEmpty { o["display_name"] = .string(displayName) }
        return .object(o)
    }
}

/// A hosted room row (`groups.list` / `groups.create` / `groups.state.room`).
public struct RoomSummary: Sendable, Hashable, Identifiable {
    public var id: String { roomId }
    public let roomId: String
    public private(set) var name: String
    public let members: [RoomMember]
    public let revision: Int
    public let createdAt: Double
    public let updatedAt: Double
    /// Present on `groups.list`/`groups.state` rows, absent on `groups.create`.
    public let latestSeq: Int?
    public let disbandedAt: Double?
    public let idempotent: Bool

    public init?(_ v: JSONValue) {
        guard let id = v["room_id"]?.string else { return nil }
        roomId = id
        name = v["name"]?.string ?? id
        members = (v["members"]?.array ?? []).compactMap(RoomMember.init)
        revision = v["revision"]?.int ?? 0
        createdAt = v["created_at"]?.double ?? 0
        updatedAt = v["updated_at"]?.double ?? 0
        latestSeq = v["latest_seq"]?.int
        disbandedAt = v["disbanded_at"]?.double
        idempotent = v["idempotent"]?.bool ?? false
    }

    public func member(_ memberId: String?) -> RoomMember? {
        guard let memberId else { return nil }
        return members.first { $0.memberId == memberId }
    }

    /// The same row under another name (the optimistic side of `groups.rename`).
    public func renamed(_ newName: String) -> RoomSummary {
        var copy = self
        copy.name = newName
        return copy
    }

    /// A room name as the server stores it (`hosted_rooms._validate_room_name`: stripped, 1–200
    /// characters, any text), or nil when it would be refused.
    public static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxNameChars).contains(name.unicodeScalars.count) else { return nil }
        return name
    }

    /// `MAX_ROOM_NAME_CHARS` (`gateway/hosted_rooms.py`), counted like Python `len` (code points).
    public static let maxNameChars = 200
}

/// One durable room-log event (`_event_from_row`).
public struct RoomEvent: Sendable, Equatable, Identifiable {
    public var id: Int { seq }
    public let seq: Int
    public let eventId: String
    public let kind: String
    public let actor: JSONValue
    public let payload: JSONValue
    public let createdAt: Double

    public init(seq: Int, eventId: String, kind: String, actor: JSONValue = [:], payload: JSONValue = [:], createdAt: Double = 0) {
        self.seq = seq; self.eventId = eventId; self.kind = kind; self.actor = actor; self.payload = payload; self.createdAt = createdAt
    }

    public init?(_ v: JSONValue) {
        guard let seq = v["seq"]?.int, let kind = v["kind"]?.string else { return nil }
        self.init(seq: seq, eventId: v["event_id"]?.string ?? "", kind: kind, actor: v["actor"] ?? .null,
                  payload: v["payload"] ?? .null, createdAt: v["created_at"]?.double ?? 0)
    }

    public var actorKind: String? { actor["kind"]?.string }
    public var actorId: String? { actor["id"]?.string }
    public var text: String? { payload["text"]?.string }
    public var threadId: String? { payload["thread_id"]?.string }
    /// The user event a turn/activity belongs to (`discussion_event_id` = the stored `user:<sha256>` id).
    public var discussionEventId: String? { payload["discussion_event_id"]?.string }
    public var memberId: String? { payload["member_id"]?.string ?? (actorKind == "member" ? actorId : nil) }
}

/// One `groups.log` page: `{events, cursor, latest_seq, has_more, authority}`.
public struct RoomLogPage: Sendable, Equatable {
    public let events: [RoomEvent]
    public let cursor: Int
    public let latestSeq: Int
    public let hasMore: Bool

    public init(events: [RoomEvent], cursor: Int, latestSeq: Int, hasMore: Bool) {
        self.events = events; self.cursor = cursor; self.latestSeq = latestSeq; self.hasMore = hasMore
    }

    init(_ v: JSONValue, sinceSeq: Int) {
        events = (v["events"]?.array ?? []).compactMap(RoomEvent.init)
        cursor = v["cursor"]?.int ?? events.last?.seq ?? sinceSeq
        latestSeq = v["latest_seq"]?.int ?? cursor
        hasMore = v["has_more"]?.bool ?? false
    }
}

/// An approval a room member's hidden session is waiting on
/// (`HostedRoomRuntime._report_pending_action`, `tui_gateway/hosted_room_driver.py:392-405`).
public struct RoomApproval: Sendable, Equatable, Hashable {
    public let memberId: String
    public let taskId: String
    public let executionGeneration: Int
    public let requestId: String
    /// Server-filtered to `once`/`deny` (room approvals never offer session/always).
    public let choices: [String]
    public let command: String?
    public let description: String?
}

/// `driver_status.pending_actions[]` (`hosted_room_service.py:544-550`).
public enum RoomPendingAction: Sendable, Equatable, Hashable, Identifiable {
    /// A task in `indeterminate` or `deferred`: only an explicit `groups.retry` re-runs it.
    case retry(taskId: String)
    case approval(RoomApproval)
    case other(kind: String)

    public var id: String {
        switch self {
        case .retry(let t): return "retry:\(t)"
        case .approval(let a): return "approval:\(a.memberId):\(a.requestId)"
        case .other(let k): return "other:\(k)"
        }
    }

    init(_ v: JSONValue) {
        switch v["kind"]?.string {
        case "retry":
            self = .retry(taskId: v["task_id"]?.string ?? "")
        case "approval":
            let a = v["approval"] ?? [:]
            self = .approval(RoomApproval(
                memberId: v["member_id"]?.string ?? "", taskId: v["task_id"]?.string ?? "",
                executionGeneration: v["execution_generation"]?.int ?? 0,
                requestId: v["request_id"]?.string ?? a["request_id"]?.string ?? "",
                choices: (a["choices"]?.array ?? []).compactMap(\.string),
                command: a["command"]?.string, description: a["description"]?.string))
        case let k:
            self = .other(kind: k ?? "?")
        }
    }
}

/// `groups.state.driver_status`: present only while this process's room worker runs and the room
/// is live (`methods_groups.py:367-378`). Built per process by `HostedRoomService.status`
/// (`hosted_room_service.py:536-556`): `counts`, `working` and the `retry` actions come from the
/// shared task table, so any backend process reports the same. `blocked` is the runtime blocked set
/// (in memory) OR an `indeterminate|stopping` task (shared). The `approval` actions are in-memory
/// state of the process whose worker runs the turn, so another process does not report them
/// (docs/gateway-contract.md §7.3, §7.7).
public struct RoomDriverStatus: Sendable, Equatable {
    public let running: Bool
    /// Any task `queued|running|stopping`.
    public let working: Bool
    /// Runtime blocked set, or any `indeterminate|stopping` task.
    public let blocked: Bool
    public let counts: [String: Int]
    public let pendingActions: [RoomPendingAction]

    public init(running: Bool = true, working: Bool, blocked: Bool = false, counts: [String: Int] = [:],
                pendingActions: [RoomPendingAction] = []) {
        self.running = running; self.working = working; self.blocked = blocked; self.counts = counts
        self.pendingActions = pendingActions
    }

    /// Tasks in a terminal-ish status (`settled|failed|cancelled|deferred`). Each one publishes a
    /// `turn.*` event to the log right after the status change (`HostedRoomService.prepare_room` →
    /// `_publish_terminal_tasks`), so more terminal tasks than `turn.*` events means a publication is
    /// still in flight.
    public var terminalTasks: Int { ["settled", "failed", "cancelled", "deferred"].reduce(0) { $0 + (counts[$1] ?? 0) } }

    init(_ v: JSONValue) {
        running = v["running"]?.bool ?? false
        working = v["working"]?.bool ?? false
        blocked = v["blocked"]?.bool ?? false
        counts = (v["counts"]?.object ?? [:]).compactMapValues(\.int)
        pendingActions = (v["pending_actions"]?.array ?? []).map(RoomPendingAction.init)
    }
}

public struct RoomStateSnapshot: Sendable, Equatable {
    public let room: RoomSummary
    public let driver: RoomDriverStatus?
}

/// Typed `groups.*` calls used by the M2 Group Chat (on top of the raw M0 `GroupsAPI` calls).
extension GroupsAPI {
    /// `groups.list {limit, offset}` → rooms ordered `updated_at DESC, room_id ASC`; `next_offset` is
    /// non-null only when the page is full (`methods_groups.py:344-354`).
    public func listRooms(limit: Int = 500, offset: Int = 0) async throws -> (rooms: [RoomSummary], nextOffset: Int?) {
        let r = try await list(limit: limit, offset: offset)
        return (SchemaLog.array(r, "rooms", method: "groups.list").compactMap(RoomSummary.init), r["next_offset"]?.int)
    }

    /// Every live room (follows `next_offset` while it moves forward: a repeated or smaller offset
    /// ends the walk instead of looping).
    public func allRooms() async throws -> [RoomSummary] {
        var out: [RoomSummary] = [], offset: Int? = 0
        while let o = offset, out.count < 5000 {
            let page = try await listRooms(offset: o)
            out += page.rooms
            offset = page.nextOffset.flatMap { $0 > o ? $0 : nil }
        }
        return out
    }

    /// `groups.create {room_id, name, members}`; idempotent on identical params.
    public func createRoom(roomId: String, name: String, members: [RoomMember]) async throws -> RoomSummary {
        let r = try await client.call("groups.create", ["room_id": .string(roomId), "name": .string(name),
                                                        "members": .array(members.map(\.json))])
        guard let room = r["room"].flatMap(RoomSummary.init) else { throw GatewayClient.ClientError.badFrame("groups.create: no room") }
        return room
    }

    public func roomState(roomId: String) async throws -> RoomStateSnapshot {
        let r = try await state(roomId: roomId)
        guard let room = r["room"].flatMap(RoomSummary.init) else { throw GatewayClient.ClientError.badFrame("groups.state: no room") }
        return RoomStateSnapshot(room: room, driver: r["driver_status"].map(RoomDriverStatus.init))
    }

    public func roomLog(roomId: String, sinceSeq: Int, limit: Int = 200) async throws -> RoomLogPage {
        RoomLogPage(try await log(roomId: roomId, sinceSeq: sinceSeq, limit: limit), sinceSeq: sinceSeq)
    }

    /// `groups.send` → the stored `message.user` event. ACK only: it proves the append, not a bot turn.
    public func sendMessage(roomId: String, eventId: String, text: String, threadId: String) async throws -> RoomEvent {
        let r = try await send(roomId: roomId, eventId: eventId, text: text, threadId: threadId)
        guard let e = r["event"].flatMap(RoomEvent.init) else { throw GatewayClient.ClientError.badFrame("groups.send: no event") }
        return e
    }

    /// `groups.stop {room_id, cancel_id}` → `cancelled` = tasks touched. `cancel_id` MUST be unique per
    /// Stop: the fence event id is `room-stop:<sha256(cancel_id)>`, so a reused id returns the old
    /// fence idempotently and does not cover newer user messages (`hosted_rooms.py:1029-1036`).
    public func stopRoom(roomId: String, cancelId: String = "hba-stop-\(UUID().uuidString.lowercased())") async throws -> Int {
        try await stop(roomId: roomId, cancelId: cancelId)["cancelled"]?.int ?? 0
    }

    /// `groups.retry {room_id, task_id}` → `{retried: true, task: {room_id, task_id, thread_id, turn_id,
    /// status, execution_generation, cancel_generation}}` (`methods_groups.py:448-462`).
    public func retry(roomId: String, taskId: String) async throws -> JSONValue {
        try await client.call("groups.retry", ["room_id": .string(roomId), "task_id": .string(taskId)])
    }

    /// `groups.approve` for one exact pending approval; `choice` ∈ {once, deny}
    /// (`hosted_room_service.py:498-534`) → `{approved: true, result}`.
    public func approve(roomId: String, approval: RoomApproval, choice: String) async throws -> JSONValue {
        try await client.call("groups.approve", [
            "room_id": .string(roomId), "member_id": .string(approval.memberId), "task_id": .string(approval.taskId),
            "execution_generation": .number(Double(approval.executionGeneration)),
            "choice": .string(choice), "request_id": .string(approval.requestId)])
    }

    /// `groups.rename {room_id, event_id, name}` → `{room: {…room, event}}`: the renamed row (revision + 1)
    /// plus its `room.renamed` log event (`hosted_rooms.rename_room`). Idempotent per `event_id` with the
    /// same name; it needs no room worker. Errors: 4117 for a room error (unknown or disbanded room, invalid
    /// name, an `event_id` reused with another name), 5117 otherwise (`methods_groups.py` `_passthrough`).
    public func renameRoom(roomId: String, eventId: String, name: String) async throws -> RoomSummary {
        let r = try await client.call("groups.rename", ["room_id": .string(roomId), "event_id": .string(eventId),
                                                        "name": .string(name)])
        guard let room = r["room"].flatMap(RoomSummary.init) else { throw GatewayClient.ClientError.badFrame("groups.rename: no room") }
        return room
    }

    /// `groups.disband {room_id}` → `{tombstone}`. It first stops the room and REFUSES (5114
    /// "room work is still stopping…") while a stop is unacknowledged; retry later.
    public func disbandRoom(roomId: String, cancelId: String = "hba-disband-\(UUID().uuidString.lowercased())") async throws -> JSONValue {
        try await client.call("groups.disband", ["room_id": .string(roomId), "cancel_id": .string(cancelId)])
    }
}

/// The room actions `RoomModel` sends, on top of the poll reads. `GroupsAPI` is the live one; app tests
/// use an in-memory fake. Ids (`event_id`, `cancel_id`) are minted by the caller, fresh per action.
public protocol RoomActions: RoomSource {
    func sendMessage(roomId: String, eventId: String, text: String, threadId: String) async throws -> RoomEvent
    func stopRoom(roomId: String, cancelId: String) async throws -> Int
    func retry(roomId: String, taskId: String) async throws -> JSONValue
    func approve(roomId: String, approval: RoomApproval, choice: String) async throws -> JSONValue
    func disbandRoom(roomId: String, cancelId: String) async throws -> JSONValue
    func renameRoom(roomId: String, eventId: String, name: String) async throws -> RoomSummary
    /// Change Members (C2.2) creates the replacement room through the old room's actions.
    func createRoom(roomId: String, name: String, members: [RoomMember]) async throws -> RoomSummary
}

extension GroupsAPI: RoomActions {}

/// Every live room plus its log/state reads: what the sidebar's room digests poll.
public protocol RoomDirectory: RoomSource {
    func allRooms() async throws -> [RoomSummary]
}

extension GroupsAPI: RoomDirectory {}
