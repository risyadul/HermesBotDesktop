import Foundation
import XCTest
@testable import HermesGatewayKit

/// Routing edges of an open canonical Bot Chat: events and requests that arrive before the consumer is
/// set are buffered (never lost), detach wins over a racing rebind, the wire tap omits request params,
/// and a resume mid-turn is reported as `inflight`.
final class SessionRoutingTests: XCTestCase {
    private static let found: JSONValue = ["sessions": [["id": "st-root", "title": "Bot Chat", "root_title": "Bot Chat"]]]

    private func open(_ gw: FakeGateway, resume: JSONValue = ["session_id": "rt-1", "messages": [], "info": [:]])
        async throws -> (Backend, BotChatSession) {
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume": return resume
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        return (backend, try await BotChatSession.openCanonical(backend, bot: Parity.bot))
    }

    private func request(_ id: String, sid: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": .string(id), "method": "approval", "params": ["session_id": .string(sid), "command": "ls"]]
    }

    func testRequestBeforeOnEventIsDeliveredInOrder() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw)
        defer { backend.client.close() }
        let wire = Collector<String>()
        backend.client.onWire = { out, line in if !out { wire.add(line) } }
        gw.push(request("srq-early", sid: "rt-1"))
        gw.push(["jsonrpc": "2.0", "method": "event",
                 "params": ["type": "message.delta", "session_id": "rt-1", "payload": ["text": "early"]]])
        try await Parity.waitUntil { wire.all.contains { $0.contains("early") } }
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        XCTAssertEqual(events.all.count, 2, "flushed synchronously when the consumer is set")
        guard case .request(let r) = events.all.first else { return XCTFail("\(events.all)") }
        XCTAssertEqual(r.id, "srq-early")
        XCTAssertEqual(events.all.last, .delta("early"))
        XCTAssertTrue(gw.responses.isEmpty, "the request was not declined")
    }

    func testRebindAfterDetachRoutesNothing() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw)
        defer { backend.client.close() }
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        s.detach()
        s.rebind(to: "rt-2", stored: "")
        XCTAssertEqual(s.sessionId, "rt-1", "a detached session does not move")
        gw.push(request("srq-late", sid: "rt-2"))
        try await Parity.waitUntil { !gw.responses.isEmpty }
        XCTAssertEqual(gw.responses.first?["error"]?["code"], .number(Double(ServerRequest.notShownCode)),
                       "no handler: declined so another client can answer")
        s.emit(.delta("after detach"))
        XCTAssertTrue(events.all.isEmpty, "detach clears the consumer")
    }

    func testWireTapOmitsRequestParamsAndAnswerRPCParams() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw)
        defer { backend.client.close() }
        s.onEvent { _ in }
        let lines = Collector<String>()
        backend.client.onWire = { _, line in lines.add(line) }
        let secret = "hunter2-" + UUID().uuidString
        gw.push(["jsonrpc": "2.0", "id": "srq-s", "method": "sudo", "params": ["session_id": "rt-1", "command": .string(secret)]])
        try await Parity.waitUntil { lines.all.contains { $0.contains("srq-s") } }
        _ = try await backend.client.call("clarify.lock", ["request_id": "srq-c", "question_id": "q", "answer": .string(secret)])
        _ = try await backend.client.call("approval.respond", ["session_id": "rt-1", "choice": .string(secret)])
        XCTAssertFalse(lines.all.contains { $0.contains(secret) }, lines.all.joined(separator: "\n"))
        XCTAssertTrue(lines.all.contains(#"{"id":"srq-s","method":"sudo","params":<omitted>}"#))
        XCTAssertTrue(lines.all.contains { $0.contains(#""method":"clarify.lock","params":<omitted>"#) })
    }

    func testResumeMidTurnReportsTheInflightTurn() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw, resume: [
            "session_id": "rt-1", "messages": [], "info": [:], "running": true, "status": "working",
            "inflight": ["user": "plan it", "assistant": "Step one", "streaming": true],
        ])
        defer { backend.client.close() }
        XCTAssertEqual(s.inflight, InflightTurn(user: "plan it", assistant: "Step one"))
        XCTAssertNil(InflightTurn(resume: ["running": false, "status": "idle"]))
        XCTAssertNil(InflightTurn(resume: ["running": false, "status": "idle",
                                           "inflight": ["user": "x", "assistant": "y", "streaming": false, "error": "boom"]]),
                     "a retained failed turn is not running")
        XCTAssertNotNil(InflightTurn(resume: ["status": "waiting"]), "waiting on an approval is mid-turn")
    }

    func testResumedRunningTurnHoldsTheGateAndKeepsGrowing() {
        var t = ChatTranscript()
        t.seed(history: [ChatHistoryMessage(role: .user, text: "plan it")])
        t.resumeRunningTurn(InflightTurn(user: "plan it", assistant: "Step one"))
        XCTAssertTrue(t.busy)
        XCTAssertEqual(t.lines.map(\.role), [.user, .bot], "the user line already in history is not repeated")
        XCTAssertNil(t.beginTurn("mine"))
        t.apply(.delta(", step two"))
        XCTAssertEqual(t.lines.last?.text, "Step one, step two")
    }
}
