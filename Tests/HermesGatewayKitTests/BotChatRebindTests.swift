import Foundation
import XCTest
@testable import HermesGatewayKit

/// Session-id changes under an open canonical Bot Chat: compression rotating the stored id
/// (`session.info`), the backend reclaiming the runtime (`session.reclaimed` → re-resume on a new runtime
/// id, events and requests re-routed), and `approval.received`. Also remote turns in the transcript.
final class BotChatRebindTests: XCTestCase {
    private static let found: JSONValue = ["sessions": [["id": "st-root", "resolved_id": "st-tip", "title": "Bot Chat",
                                                          "root_title": "Bot Chat"]]]

    private func event(_ type: String, sid: String, _ payload: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": "event", "params": ["type": .string(type), "session_id": .string(sid), "payload": payload]]
    }

    private func open(_ gw: FakeGateway, resumes: Collector<Int>) async throws -> (Backend, BotChatSession, Collector<ChatEvent>) {
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume":
                let n = resumes.bump(1)
                var r: JSONValue = ["session_id": .string("rt-\(n)"), "stored_session_id": "st-tip", "messages": [], "info": [:]]
                if n == 2 {
                    r = ["session_id": "rt-2", "stored_session_id": "st-tip2", "messages": [], "info": [:],
                         "open_requests": [["id": "srq-open", "method": "clarify",
                                            "params": ["session_id": "rt-2", "questions": [["qid": "q1", "question": "?"]]]]]]
                }
                return r
            case "approval.received": return ["acknowledged": true]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        return (backend, s, events)
    }

    func testCompressionRotatesTheStoredIdAndKeepsRouting() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s, events) = try await open(gw, resumes: Collector<Int>())
        defer { backend.client.close() }
        XCTAssertEqual(s.storedSessionId, "st-tip")
        gw.push(event("session.info", sid: "rt-1", ["stored_session_id": "st-continued", "running": false]))
        gw.push(event("message.delta", sid: "rt-1", ["text": "after"]))
        try await Parity.waitUntil { events.all.contains(.delta("after")) }
        XCTAssertEqual(s.storedSessionId, "st-continued")
        XCTAssertEqual(s.sessionId, "rt-1", "compression keeps the runtime id")
    }

    func testReclaimedRuntimeIsResumedAndRoutingMovesToTheNewId() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let resumes = Collector<Int>()
        let (backend, s, events) = try await open(gw, resumes: resumes)
        defer { backend.client.close() }
        // Someone else's runtime: ignored.
        gw.push(event("session.reclaimed", sid: "", ["session_id": "rt-other", "stored_session_id": "st-x", "reason": "lru_evict"]))
        gw.push(event("session.reclaimed", sid: "", ["session_id": "rt-1", "stored_session_id": "st-tip", "reason": "idle_timeout"]))
        try await Parity.waitUntil { events.all.contains { if case .resumed = $0 { return true }; return false } }
        XCTAssertEqual(resumes.all.count, 2, "one re-resume, only for our runtime")
        XCTAssertEqual(s.sessionId, "rt-2")
        XCTAssertEqual(s.storedSessionId, "st-tip2")
        XCTAssertEqual(Array(Parity.methods(gw).suffix(2)), ["session.list", "session.resume"], "lookup at the tip, then resume")
        XCTAssertTrue(events.all.contains { if case .request(let r) = $0 { return r.id == "srq-open" }; return false },
                      "open requests of the new runtime are re-shown")

        gw.push(event("message.delta", sid: "rt-1", ["text": "stale"]))
        gw.push(event("message.delta", sid: "rt-2", ["text": "fresh"]))
        gw.push(["jsonrpc": "2.0", "id": "srq-new", "method": "approval",
                 "params": ["session_id": "rt-2", "request_id": "q-9", "command": "ls"]])
        try await Parity.waitUntil { events.all.contains(.delta("fresh"))
            && events.all.contains { if case .request(let r) = $0 { return r.id == "srq-new" }; return false } }
        XCTAssertFalse(events.all.contains(.delta("stale")), "the old runtime is no longer routed")

        try await s.send("hi")
        XCTAssertEqual(gw.received.last { $0["method"]?.string == "prompt.submit" }?["params"]?["session_id"], "rt-2")
    }

    func testReclaimAfterDetachDoesNothing() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let resumes = Collector<Int>()
        let (backend, s, _) = try await open(gw, resumes: resumes)
        defer { backend.client.close() }
        s.detach()
        gw.push(event("session.reclaimed", sid: "", ["session_id": "rt-1", "stored_session_id": "st-tip", "reason": "idle_timeout"]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(resumes.all.count, 1)
    }

    func testApprovalReceivedSendsTheQueueId() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s, _) = try await open(gw, resumes: Collector<Int>())
        defer { backend.client.close() }
        let ack = try await s.approvalReceived(requestId: "q-1")
        XCTAssertTrue(ack)
        XCTAssertEqual(gw.received.last { $0["method"]?.string == "approval.received" }?["params"],
                       ["session_id": "rt-1", "request_id": "q-1"])
    }

    // MARK: - remote turns (ChatTranscript)

    func testTurnStartedElsewhereStreamsAsBotBubblesAndHoldsTheGate() {
        var t = ChatTranscript()
        t.apply(.started)
        XCTAssertTrue(t.busy, "a turn started from Hermes Desktop holds the submit gate")
        XCTAssertNil(t.beginTurn("mine"), "no local send interleaves with it")
        t.apply(.delta("Hello from "))
        t.apply(.delta("Desktop"))
        t.apply(.completed(ChatCompletion(text: "Hello from Desktop")))
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.lines.map(\.role), [.bot])
        XCTAssertEqual(t.lines.first?.text, "Hello from Desktop")
        XCTAssertEqual(t.beginTurn("now mine"), "now mine", "the gate opens once the remote turn settles")
    }

    func testDeltaWithoutStartWhileIdleAlsoHoldsTheGateUntilDisconnect() {
        var t = ChatTranscript()
        t.apply(.delta("joined mid-turn"))
        XCTAssertTrue(t.busy)
        t.apply(.disconnected("socket closed"))
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.lines.map(\.role), [.bot, .error])
    }
}
