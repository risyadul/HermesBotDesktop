import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// In-memory `groups.*` side for headless RoomModel / RoomDigestHub tests: records every call, answers from
/// settable state, never touches a gateway. `holdRename()` parks the next rename until `releaseRename()`.
final class FakeRoomActions: RoomActions, RoomDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _sends: [(text: String, thread: String)] = []
    private var _renames: [(eventId: String, name: String)] = []
    private var _logRequests: [(room: String, since: Int)] = []
    private var _rooms: [RoomSummary]
    private var _events: [String: [RoomEvent]] = [:]
    private var _drivers: [String: RoomDriverStatus] = [:]
    private var _renameError: Error?
    private var _sendError: Error?
    private var holdNextRename = false
    private var renameGate: CheckedContinuation<Void, Never>?

    init(rooms: [RoomSummary]) { _rooms = rooms }

    var calls: [String] { lock.withLock { _calls } }
    var sends: [(text: String, thread: String)] { lock.withLock { _sends } }
    var renames: [(eventId: String, name: String)] { lock.withLock { _renames } }
    var logRequests: [(room: String, since: Int)] { lock.withLock { _logRequests } }

    func setEvents(_ roomId: String, _ events: [RoomEvent]) { lock.withLock { _events[roomId] = events } }
    func setRooms(_ rooms: [RoomSummary]) { lock.withLock { _rooms = rooms } }
    func setDriver(_ roomId: String, _ d: RoomDriverStatus?) { lock.withLock { _drivers[roomId] = d } }
    func failRename(_ e: Error?) { lock.withLock { _renameError = e } }
    func failSend(_ e: Error?) { lock.withLock { _sendError = e } }
    func holdRename() { lock.withLock { holdNextRename = true } }
    func releaseRename() { lock.withLock { renameGate?.resume(); renameGate = nil } }
    var renameParked: Bool { lock.withLock { renameGate != nil } }

    private func record(_ c: String) { lock.withLock { _calls.append(c) } }

    // MARK: RoomSource / RoomDirectory

    func allRooms() async throws -> [RoomSummary] {
        record("list")
        return lock.withLock { _rooms }
    }

    func roomLog(roomId: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPage {
        let events: [RoomEvent] = lock.withLock {
            _calls.append("log:\(roomId):\(sinceSeq)")
            _logRequests.append((roomId, sinceSeq))
            return Array((_events[roomId] ?? []).filter { $0.seq > sinceSeq }.prefix(limit))
        }
        let latest = lock.withLock { _events[roomId]?.last?.seq ?? 0 }
        let cursor = events.last?.seq ?? sinceSeq
        return RoomLogPage(events: events, cursor: cursor, latestSeq: latest, hasMore: cursor < latest)
    }

    func roomState(roomId: String) async throws -> RoomStateSnapshot {
        record("state:\(roomId)")
        let (room, driver) = lock.withLock { (_rooms.first { $0.roomId == roomId }, _drivers[roomId]) }
        guard let room else { throw GatewayClient.RPCError(code: 4114, message: "hosted room not found", data: nil) }
        return RoomStateSnapshot(room: room, driver: driver)
    }

    // MARK: RoomActions

    func sendMessage(roomId: String, eventId: String, text: String, threadId: String) async throws -> RoomEvent {
        let error: Error? = lock.withLock {
            _calls.append("send:\(threadId)")
            _sends.append((text, threadId))
            return _sendError
        }
        if let error { throw error }
        return RoomEvent(seq: 99, eventId: "user:x", kind: "message.user", payload: ["text": .string(text), "thread_id": .string(threadId)])
    }

    func stopRoom(roomId: String, cancelId: String) async throws -> Int { record("stop"); return 0 }
    func retry(roomId: String, taskId: String) async throws -> JSONValue { record("retry"); return [:] }
    func approve(roomId: String, approval: RoomApproval, choice: String) async throws -> JSONValue { record("approve"); return [:] }
    func disbandRoom(roomId: String, cancelId: String) async throws -> JSONValue { record("disband"); return [:] }

    func renameRoom(roomId: String, eventId: String, name: String) async throws -> RoomSummary {
        let hold: Bool = lock.withLock {
            _calls.append("rename")
            _renames.append((eventId, name))
            defer { holdNextRename = false }
            return holdNextRename
        }
        if hold { await withCheckedContinuation { c in lock.withLock { renameGate = c } } }
        if let e = lock.withLock({ _renameError }) { throw e }
        let room = lock.withLock { _rooms.first { $0.roomId == roomId } }
        guard let room else { throw GatewayClient.RPCError(code: 4117, message: "hosted room not found", data: nil) }
        let renamed = RoomFixtures.room(roomId, name: name, revision: room.revision + 1)  // as the server: revision + 1
        lock.withLock { _rooms = _rooms.map { $0.roomId == roomId ? renamed : $0 } }
        return renamed
    }
}

/// Fixtures shared by the room model tests.
enum RoomFixtures {
    static func room(_ id: String = "hba-test-0", name: String = "Ops", latestSeq: Int? = nil, revision: Int = 1) -> RoomSummary {
        var v: [String: JSONValue] = [
            "room_id": .string(id), "name": .string(name), "revision": .number(Double(revision)), "created_at": 1, "updated_at": 1,
            "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Alpha"],
                        ["member_id": "beta", "profile": "beta", "handle": "beta"]],
        ]
        if let latestSeq { v["latest_seq"] = .number(Double(latestSeq)) }
        return RoomSummary(.object(v))!
    }

    static func user(_ seq: Int, _ text: String = "hi", thread: String = "main", time: Double = 100) -> RoomEvent {
        RoomEvent(seq: seq, eventId: "user:\(seq)", kind: "message.user", actor: ["kind": "user", "id": "desktop"],
                  payload: ["text": .string(text), "thread_id": .string(thread)], createdAt: time)
    }

    static func member(_ seq: Int, _ m: String, _ text: String = "hello", thread: String = "main", disc: String = "user:1",
                       time: Double = 200) -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dmessage:\(seq)", kind: "message.member", actor: ["kind": "member", "id": .string(m)],
                  payload: ["text": .string(text), "member_id": .string(m), "discussion_event_id": .string(disc),
                            "thread_id": .string(thread)], createdAt: time)
    }

    static func settled(_ seq: Int, disc: String = "user:1", thread: String = "main") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dactivity:\(seq)", kind: "room.activity",
                  payload: ["status": "settled", "reason_code": "silent_round", "thread_id": .string(thread),
                            "discussion_event_id": .string(disc)])
    }

    static let approval = RoomDriverStatus(working: true, pendingActions: [.approval(RoomApproval(
        memberId: "alpha", taskId: "dtask:1", executionGeneration: 1, requestId: "req-1", choices: ["once", "deny"],
        command: "rm -rf build", description: nil))])
}

@MainActor
func eventually(_ timeout: TimeInterval = 5, _ cond: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { return XCTFail("condition not met in \(timeout)s", file: file, line: line) }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
