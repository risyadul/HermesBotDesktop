import Foundation
import XCTest
@testable import HermesGatewayKit

/// M2 Group Chat logic: log reduction, discussion phases, send gate, poll cadence, wire decoding and
/// the `groups.*` request shapes. No live backend.
final class GroupChatTests: XCTestCase {
    // MARK: fixtures (shapes as observed in evidence/m2/*/scenario.json)

    private let room = RoomSummary([
        "room_id": "hba-x", "name": "Test", "revision": 1, "latest_seq": 0, "created_at": 1, "updated_at": 1,
        "members": [["member_id": "translator", "profile": "translator", "handle": "translator", "display_name": "Translator"],
                    ["member_id": "code-reviewer", "profile": "code-reviewer", "handle": "code-reviewer"]],
    ])!

    private func user(_ seq: Int, _ id: String = "user:aaa", thread: String = "main") -> RoomEvent {
        RoomEvent(seq: seq, eventId: id, kind: "message.user", actor: ["kind": "user", "id": "desktop"],
                  payload: ["text": "hi", "thread_id": .string(thread)])
    }
    private func member(_ seq: Int, _ m: String, disc: String = "user:aaa", text: String = "hello") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dmessage:\(seq)", kind: "message.member", actor: ["kind": "member", "id": .string(m)],
                  payload: ["text": .string(text), "member_id": .string(m), "discussion_event_id": .string(disc), "thread_id": "main"])
    }
    private func turn(_ seq: Int, _ kind: String, _ m: String, disc: String = "user:aaa", extra: [String: JSONValue] = [:]) -> RoomEvent {
        var p: [String: JSONValue] = ["member_id": .string(m), "discussion_event_id": .string(disc), "thread_id": "main",
                                      "task_id": .string("dtask:\(seq)")]
        extra.forEach { p[$0] = $1 }
        return RoomEvent(seq: seq, eventId: "dterminal:\(seq)", kind: kind, actor: ["kind": "gateway", "id": "install:x"], payload: .object(p))
    }
    private func activity(_ seq: Int, _ status: String, _ reason: String, disc: String = "user:aaa") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dactivity:\(seq)", kind: "room.activity", actor: ["kind": "gateway", "id": "install:x"],
                  payload: ["status": .string(status), "reason_code": .string(reason), "thread_id": "main", "discussion_event_id": .string(disc)])
    }
    private func stopFence(_ seq: Int) -> RoomEvent {
        RoomEvent(seq: seq, eventId: "room-stop:\(seq)", kind: "room.stop_requested", payload: ["cancel_id": "hba-stop-1"])
    }
    private func page(_ events: [RoomEvent], latest: Int? = nil, more: Bool = false) -> RoomLogPage {
        RoomLogPage(events: events, cursor: events.last?.seq ?? 0, latestSeq: latest ?? events.last?.seq ?? 0, hasMore: more)
    }

    // MARK: RoomTimeline

    func testApplyIsIdempotentAndTracksCursor() {
        var t = RoomTimeline()
        XCTAssertEqual(t.apply(page([user(1), member(2, "translator")])), 2)
        XCTAssertEqual(t.apply(page([member(2, "translator")])), 0, "a re-delivered page adds nothing")
        XCTAssertEqual(t.apply(page([member(2, "translator"), turn(3, "turn.settled", "translator")])), 1)
        XCTAssertEqual(t.cursor, 3)
        XCTAssertEqual(t.events.map(\.seq), [1, 2, 3])
        XCTAssertFalse(t.gapDetected)
    }

    func testBehindWhenServerHasMore() {
        var t = RoomTimeline()
        t.apply(page([user(1)], latest: 5, more: true))
        XCTAssertTrue(t.behind)
        XCTAssertEqual(RoomPollPolicy.interval(driver: nil, timeline: t), 0, "behind → fetch again immediately")
    }

    func testGapDetected() {
        var t = RoomTimeline()
        t.apply(page([user(1)]))
        t.apply(page([member(3, "translator")]))
        XCTAssertTrue(t.gapDetected)
    }

    func testPhasesSettledBoundedStoppedSupersededPending() {
        var t = RoomTimeline()
        let first = user(1, "user:a")
        t.apply(page([first, member(2, "translator", disc: "user:a"), turn(3, "turn.settled", "translator", disc: "user:a")]))
        XCTAssertEqual(t.phase(of: first), .pending)
        XCTAssertTrue(t.awaitingDiscussion)
        t.apply(page([activity(4, "settled", "silent_round", disc: "user:a")]))
        XCTAssertEqual(t.phase(of: first), .settled(reason: "silent_round"))
        XCTAssertFalse(t.awaitingDiscussion)

        let second = user(5, "user:b")
        t.apply(page([second]))
        XCTAssertEqual(t.phase(of: second), .pending)
        t.apply(page([stopFence(6)]))
        XCTAssertEqual(t.phase(of: second), .stopped, "a later stop fence ends the discussion")
        XCTAssertFalse(t.awaitingDiscussion)

        let third = user(7, "user:c"), fourth = user(8, "user:d")
        t.apply(page([third, fourth]))
        XCTAssertEqual(t.phase(of: third), .superseded)
        XCTAssertEqual(t.phase(of: fourth), .pending)
        t.apply(page([activity(9, "bounded", "max_rounds", disc: "user:d")]))
        XCTAssertEqual(t.phase(of: fourth), .bounded(reason: "max_rounds"))
        XCTAssertFalse(t.awaitingDiscussion)
    }

    func testThreadsAreIndependent() {
        var t = RoomTimeline()
        let a = user(1, "user:a", thread: "t1"), b = user(2, "user:b", thread: "t2")
        t.apply(page([a, b, activity(3, "settled", "silent_round", disc: "user:a")]))
        XCTAssertEqual(t.phase(of: a), .settled(reason: "silent_round"))
        XCTAssertEqual(t.phase(of: b), .pending, "another thread is not superseded")
        XCTAssertTrue(t.awaitingDiscussion)
    }

    func testLinesUseRosterNamesAndHideOrdinarySettles() {
        var t = RoomTimeline()
        t.apply(page([
            user(1), member(2, "translator"), turn(3, "turn.settled", "translator", extra: ["passed": false]),
            turn(4, "turn.settled", "code-reviewer", extra: ["passed": true]),
            turn(5, "turn.failed", "translator", extra: ["error": "boom"]),
            turn(6, "turn.cancelled", "code-reviewer", extra: ["reason": "hba-stop-1"]),
            turn(7, "turn.deferred", "translator", extra: ["reason": "member_unavailable", "execution_generation": 1]),
            activity(8, "settled", "silent_round"), stopFence(9),
            RoomEvent(seq: 10, eventId: "x", kind: "room.renamed", payload: ["name": "New"]),
        ]))
        let lines = t.lines(room: room)
        XCTAssertEqual(lines.map(\.id), [1, 2, 4, 5, 6, 7, 8, 9, 10], "a plain turn.settled adds no row (the reply is the row)")
        XCTAssertEqual(lines[0].kind, .user)
        XCTAssertEqual(lines[1].author, "Translator", "display name from the roster")
        XCTAssertEqual(lines[1].text, "hello")
        XCTAssertEqual(lines[2].text, "passed (no reply)")
        XCTAssertEqual(lines[2].author, "code-reviewer", "handle when no display name")
        XCTAssertEqual(lines[3].kind, .error)
        XCTAssertTrue(lines[3].text.contains("boom"))
        XCTAssertTrue(lines[4].text.contains("cancelled"))
        XCTAssertTrue(lines[5].text.contains("deferred") && lines[5].text.contains("Retry"))
        XCTAssertEqual(lines[6].text, "discussion settled · silent_round")
        XCTAssertEqual(lines[7].text, "stop requested")
        XCTAssertEqual(lines[8].text, "renamed to New")
    }

    // MARK: composer + poll policy

    func testComposerGate() {
        var c = RoomComposer()
        XCTAssertNil(c.beginSend("   \n"))
        XCTAssertFalse(c.sending)
        XCTAssertEqual(c.beginSend("  hi  "), "hi")
        XCTAssertNil(c.beginSend("second"), "one groups.send in flight at a time")
        c.finishSend()
        XCTAssertEqual(c.beginSend("second"), "second")
        c.finishSend()
        XCTAssertNil(c.beginSend(String(repeating: "x", count: RoomComposer.maxTextBytes + 1)), "over the 64 KiB payload limit")
        XCTAssertFalse(c.sending)
    }

    func testPollPolicy() {
        var t = RoomTimeline()
        XCTAssertEqual(RoomPollPolicy.interval(driver: RoomDriverStatus(working: false), timeline: t), RoomPollPolicy.idle)
        XCTAssertEqual(RoomPollPolicy.interval(driver: RoomDriverStatus(working: true), timeline: t), RoomPollPolicy.active)
        XCTAssertEqual(RoomPollPolicy.interval(driver: RoomDriverStatus(working: false, blocked: true), timeline: t), RoomPollPolicy.active)
        t.apply(page([user(1)]))
        XCTAssertEqual(RoomPollPolicy.interval(driver: RoomDriverStatus(working: false), timeline: t), RoomPollPolicy.active,
                       "between member turns working can be false while the discussion is unsettled")
        t.apply(page([activity(2, "settled", "silent_round")]))
        XCTAssertEqual(RoomPollPolicy.interval(driver: RoomDriverStatus(working: false), timeline: t), RoomPollPolicy.idle)
    }

    func testPollFastUntilTerminalEventIsPublished() {
        // Observed after Stop: the task is already `cancelled` (working=false) one poll before
        // `turn.cancelled` lands in the log (evidence/m2/app-stop).
        var t = RoomTimeline()
        t.apply(page([user(1), stopFence(2)]))
        let d = RoomDriverStatus(working: false, counts: ["cancelled": 1])
        XCTAssertFalse(t.awaitingDiscussion)
        XCTAssertTrue(RoomPollPolicy.publicationPending(driver: d, timeline: t))
        XCTAssertEqual(RoomPollPolicy.interval(driver: d, timeline: t), RoomPollPolicy.active)
        t.apply(page([turn(3, "turn.cancelled", "translator")]))
        XCTAssertFalse(RoomPollPolicy.publicationPending(driver: d, timeline: t))
        XCTAssertEqual(RoomPollPolicy.interval(driver: d, timeline: t), RoomPollPolicy.idle)
        // A retried deferred task: two events (deferred, settled) for one task is not "pending".
        t.apply(page([turn(4, "turn.deferred", "translator"), turn(5, "turn.settled", "translator")]))
        XCTAssertFalse(RoomPollPolicy.publicationPending(driver: RoomDriverStatus(working: false, counts: ["settled": 1, "cancelled": 1]), timeline: t))
    }

    // MARK: decoding

    func testDriverStatusDecodesApprovalAndRetryActions() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"running":true,"working":true,"blocked":false,"counts":{"running":1,"indeterminate":1},"peer_routes":[],
         "pending_actions":[{"kind":"retry","task_id":"dtask:r"},
          {"kind":"approval","task_id":"dtask:a","execution_generation":2,"run_id":null,"session_id":"b09892fe",
           "request_id":"req-1","member_id":"alpha",
           "approval":{"command":"rm -rf /tmp/x","description":"delete in root path","choices":["once","deny"],"request_id":"req-1"}}]}
        """#.utf8))
        let d = RoomDriverStatus(v)
        XCTAssertTrue(d.working)
        XCTAssertEqual(d.counts, ["running": 1, "indeterminate": 1])
        XCTAssertEqual(d.pendingActions.first, .retry(taskId: "dtask:r"))
        guard case .approval(let a) = d.pendingActions[1] else { return XCTFail("approval") }
        XCTAssertEqual(a, RoomApproval(memberId: "alpha", taskId: "dtask:a", executionGeneration: 2, requestId: "req-1",
                                       choices: ["once", "deny"], command: "rm -rf /tmp/x", description: "delete in root path"))
        XCTAssertEqual(RoomPendingAction(["kind": "weird"]), .other(kind: "weird"))
    }

    func testRoomAndPageDecoding() {
        XCTAssertEqual(room.members.map(\.title), ["Translator", "code-reviewer"])
        XCTAssertEqual(room.latestSeq, 0)
        let created = RoomSummary(["room_id": "hba-y", "name": "N", "members": [], "idempotent": true])!
        XCTAssertNil(created.latestSeq, "groups.create rows carry no latest_seq")
        XCTAssertTrue(created.idempotent)
        let p = RoomLogPage(["events": [["seq": 3, "kind": "message.user", "event_id": "user:1", "payload": ["text": "x", "thread_id": "main"]]],
                             "cursor": 3, "latest_seq": 7, "has_more": true], sinceSeq: 2)
        XCTAssertEqual(p.events.first?.text, "x")
        XCTAssertEqual(p.cursor, 3); XCTAssertEqual(p.latestSeq, 7); XCTAssertTrue(p.hasMore)
        XCTAssertEqual(RoomLogPage(["events": []], sinceSeq: 9).cursor, 9, "an empty page keeps since_seq")
    }

    func testMemberRules() {
        XCTAssertTrue(RoomMember.isIdentifier("web-implementer"))
        XCTAssertTrue(RoomMember.isIdentifier("a.b:c_d-1"))
        XCTAssertFalse(RoomMember.isIdentifier("-x"))
        XCTAssertFalse(RoomMember.isIdentifier("has space"))
        XCTAssertFalse(RoomMember.isIdentifier("é"))
        XCTAssertFalse(RoomMember.isIdentifier(String(repeating: "a", count: 129)))
        XCTAssertEqual(RoomMember.forBot(Bot(["name": "translator", "display_name": "Translator"])!)?.json,
                       ["member_id": "translator", "profile": "translator", "handle": "translator", "display_name": "Translator"])
        XCTAssertNil(RoomMember.forBot(Bot(["name": "all"])!), "reserved handle")
    }

    // MARK: RoomSync

    func testSyncFollowsHasMoreThenReadsState() async throws {
        let src = FakeRoomSource(pages: [[user(1), member(2, "translator")], [turn(3, "turn.settled", "translator")], []],
                                 latest: 3, room: room)
        let (t, s) = try await RoomSync.refresh(src, roomId: "hba-x", timeline: RoomTimeline())
        XCTAssertEqual(t.cursor, 3)
        XCTAssertEqual(src.calls, ["log:0", "log:2", "state"])
        XCTAssertEqual(s.room.roomId, "hba-x")
        let (t2, _) = try await RoomSync.refresh(src, roomId: "hba-x", timeline: t)
        XCTAssertEqual(t2, t, "nothing new → unchanged")
        XCTAssertEqual(src.calls.suffix(2), ["log:3", "state"])
    }

    func testSyncReloadsFromZeroOnGap() async throws {
        var t = RoomTimeline()
        t.apply(page([user(1)]))
        let (u1, m2, m3) = (user(1), member(2, "translator"), member(3, "translator"))
        let src = FakeRoomSource(pages: [], latest: 3, room: room, override: { since in
            since == 1 ? [m3] : [u1, m2, m3]
        })
        let (t2, _) = try await RoomSync.refresh(src, roomId: "hba-x", timeline: t)
        XCTAssertEqual(t2.events.map(\.seq), [1, 2, 3])
        XCTAssertFalse(t2.gapDetected)
        XCTAssertEqual(src.calls, ["log:1", "log:0", "state"])
    }

    // MARK: wire shapes (fake /api/ws)

    func testGroupsRequestShapes() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        var c = URLComponents(); c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(gw.port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: "t")]
        let client = GatewayClient(url: c.url!)
        try await client.connect(timeout: 10)
        let api = GroupsAPI(client: client)
        let a = RoomApproval(memberId: "alpha", taskId: "dtask:a", executionGeneration: 2, requestId: "req-1",
                             choices: ["once", "deny"], command: nil, description: nil)
        _ = try await api.stopRoom(roomId: "hba-x")
        _ = try await api.stopRoom(roomId: "hba-x")
        _ = try await api.approve(roomId: "hba-x", approval: a, choice: "once")
        _ = try await api.retry(roomId: "hba-x", taskId: "dtask:r")
        _ = try? await api.sendMessage(roomId: "hba-x", eventId: "hba-msg-1", text: "hi", threadId: "main")
        let frames = gw.received
        let stops = frames.filter { $0["method"] == "groups.stop" }.compactMap { $0["params"]?["cancel_id"]?.string }
        XCTAssertEqual(stops.count, 2)
        XCTAssertNotEqual(stops[0], stops[1], "each Stop needs a fresh cancel_id or the fence does not move")
        XCTAssertTrue(stops.allSatisfy { $0.hasPrefix("hba-stop-") && RoomMember.isIdentifier($0) })
        XCTAssertEqual(frames.first { $0["method"] == "groups.approve" }?["params"],
                       ["room_id": "hba-x", "member_id": "alpha", "task_id": "dtask:a", "execution_generation": 2,
                        "choice": "once", "request_id": "req-1"])
        XCTAssertEqual(frames.first { $0["method"] == "groups.retry" }?["params"], ["room_id": "hba-x", "task_id": "dtask:r"])
        XCTAssertEqual(frames.first { $0["method"] == "groups.send" }?["params"],
                       ["room_id": "hba-x", "event_id": "hba-msg-1", "payload": ["text": "hi", "thread_id": "main"]])
        client.close()
    }
}

final class FakeRoomSource: RoomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [[RoomEvent]]
    private let latest: Int
    private let room: RoomSummary
    private let override: (@Sendable (Int) -> [RoomEvent])?
    private(set) var calls: [String] = []

    init(pages: [[RoomEvent]], latest: Int, room: RoomSummary, override: (@Sendable (Int) -> [RoomEvent])? = nil) {
        self.pages = pages; self.latest = latest; self.room = room; self.override = override
    }

    func roomLog(roomId: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPage {
        let events: [RoomEvent] = lock.withLock {
            calls.append("log:\(sinceSeq)")
            if let override { return override(sinceSeq) }
            return pages.isEmpty ? [] : pages.removeFirst()
        }
        let cursor = events.last?.seq ?? sinceSeq
        return RoomLogPage(events: events, cursor: cursor, latestSeq: latest, hasMore: cursor < latest && !events.isEmpty)
    }

    func roomState(roomId: String) async throws -> RoomStateSnapshot {
        lock.withLock { calls.append("state") }
        return RoomStateSnapshot(room: room, driver: RoomDriverStatus(working: false))
    }
}
