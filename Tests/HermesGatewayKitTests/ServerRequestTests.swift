import Foundation
import XCTest
@testable import HermesGatewayKit

/// Server→client requests: capabilities after ready, routing by `session_id`, response frames that
/// echo the id exactly, decline codes, `request.cancel`, and tool events on the same session.
final class ServerRequestTests: XCTestCase {
    private func approvalFrame(id: JSONValue = "srq-ab12cd34ef56", sid: String = "rt-1") -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": "approval",
         "params": ["session_id": .string(sid), "request_id": "q-1", "command": "rm -rf build",
                    "description": "dangerous", "choices": ["once", "session", "deny"], "tool_name": "terminal"]]
    }

    private func event(_ type: String, sid: String = "rt-1", _ payload: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": "event", "params": ["type": .string(type), "session_id": .string(sid), "payload": payload]]
    }

    private func openSession(_ gw: FakeGateway) async throws -> (Backend, BotChatSession, Collector<ChatEvent>) {
        let backend = try await Parity.backend(gw)
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        return (backend, s, events)
    }

    // MARK: - capabilities

    func testCapabilitiesAreAdvertisedRightAfterReady() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        XCTAssertEqual(Parity.methods(gw), ["client.capabilities"], "the first frame after gateway.ready")
        XCTAssertEqual(gw.received.first?["params"], ["server_requests": true])
        XCTAssertTrue(backend.requests.declinesNotShown, "the advertised decline policy is adopted")
    }

    func testOlderBackendWithoutCapabilitiesStillConnects() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in m == "client.capabilities" ? ["__error": ["code": -32601, "message": "unknown method"]] : nil }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        XCTAssertFalse(backend.requests.declinesNotShown, "no capabilities: never send a settling 4404")
    }

    // MARK: - routing + response frames

    func testApprovalIsRoutedToItsSessionAndAnsweredWithTheSameStringId() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, s, events) = try await openSession(gw)
        defer { backend.client.close() }
        gw.push(approvalFrame())
        try await Parity.waitUntil { events.all.contains { if case .request = $0 { return true }; return false } }
        guard case .request(let req)? = events.all.first(where: { if case .request = $0 { return true }; return false }),
              case .approval(let a) = req.kind else { return XCTFail("no approval request") }
        XCTAssertEqual(req.id, "srq-ab12cd34ef56")
        XCTAssertEqual(req.sessionId, "rt-1")
        XCTAssertEqual(a.requestId, "q-1")
        XCTAssertEqual(a.choices, [.once, .session, .deny])
        XCTAssertEqual(a.command, "rm -rf build")
        XCTAssertTrue(gw.responses.isEmpty, "nothing is answered before the user decides")

        try await s.answer(req, .approval(.session))
        try await Parity.waitUntil { gw.responses.count == 1 }
        XCTAssertEqual(gw.responses.first, ["jsonrpc": "2.0", "id": "srq-ab12cd34ef56",
                                            "result": ["choice": "session", "all": false]])
    }

    func testClarifyWithNumericIdRoundTripsAndValueAnswersStayOffTheWireTap() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, s, events) = try await openSession(gw)
        defer { backend.client.close() }
        let tap = Collector<String>()
        backend.client.onWire = { out, line in if out { tap.add(line) } }
        gw.push(["jsonrpc": "2.0", "id": 7, "method": "clarify",
                 "params": ["session_id": "rt-1", "questions": [["qid": "a", "question": "Which?", "choices": ["x", "y"]],
                                                                ["qid": "b", "question": "Why?"]]]])
        gw.push(["jsonrpc": "2.0", "id": "srq-000000000002", "method": "sudo", "params": ["session_id": "rt-1", "command": "apt install"]])
        try await Parity.waitUntil { events.all.filter { if case .request = $0 { return true }; return false }.count == 2 }
        let reqs = events.all.compactMap { e -> ServerRequest? in if case .request(let r) = e { return r }; return nil }
        guard case .clarify(let c) = reqs[0].kind, case .value(let v) = reqs[1].kind else { return XCTFail("kinds") }
        XCTAssertEqual(c.questions.map(\.qid), ["a", "b"])
        XCTAssertEqual(c.questions[0].choices, ["x", "y"])
        XCTAssertEqual(v.kind, .sudo)
        XCTAssertEqual(v.command, "apt install")

        try await s.answer(reqs[0], .clarify(["a": "x", "b": nil]))
        try await s.answer(reqs[1], .value("hunter2-sudo-pass"))
        try await Parity.waitUntil { gw.responses.count == 2 }
        XCTAssertEqual(gw.responses[0], ["jsonrpc": "2.0", "id": 7, "result": ["answers": ["a": "x", "b": nil]]])
        XCTAssertEqual(gw.responses[1]["result"], ["value": "hunter2-sudo-pass"])
        XCTAssertFalse(tap.all.joined().contains("hunter2-sudo-pass"), "answers never reach the wire tap")
    }

    func testDeclineCodes() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, session, events) = try await openSession(gw)
        defer { backend.client.close(); withExtendedLifetime(session) {} }
        gw.push(["jsonrpc": "2.0", "id": "srq-1", "method": "terminal.read", "params": ["session_id": "rt-1"]])
        gw.push(["jsonrpc": "2.0", "id": "srq-2", "method": "tour", "params": ["session_id": "rt-1", "action": "start"]])
        gw.push(["jsonrpc": "2.0", "id": "srq-3", "method": "brand.new.thing", "params": ["session_id": "rt-1"]])
        gw.push(approvalFrame(id: "srq-4", sid: "rt-someone-else"))
        try await Parity.waitUntil { gw.responses.count == 4 }
        let byId = Dictionary(uniqueKeysWithValues: gw.responses.map { ($0["id"]?.string ?? "", $0["error"]?["code"]?.int) })
        XCTAssertEqual(byId["srq-1"], 4404, "window bridge: not shown here")
        XCTAssertEqual(byId["srq-2"], 4404)
        XCTAssertEqual(byId["srq-3"], -32601, "unknown method")
        XCTAssertEqual(byId["srq-4"], 4404, "no session of this app owns it: decline, never beat another client")
        XCTAssertEqual(gw.responses.first?["error"]?["message"], "This window is not showing the session.")
        XCTAssertFalse(events.all.contains { if case .request = $0 { return true }; return false })
    }

    func testNoNotShownDeclineAgainstABackendThatSettlesOnFirstError() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in m == "client.capabilities" ? ["server_requests": [], "declines_not_shown": false] : nil }
        let (backend, _, _) = try await openSession(gw)
        defer { backend.client.close() }
        gw.push(["jsonrpc": "2.0", "id": "srq-1", "method": "preview.read", "params": ["session_id": "rt-1"]])
        gw.push(["jsonrpc": "2.0", "id": "srq-2", "method": "nope", "params": ["session_id": "rt-1"]])
        try await Parity.waitUntil { gw.responses.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gw.responses.map { $0["id"] }, ["srq-2"], "only the -32601; the bridge request stays unanswered")
    }

    func testClientWithoutHandlerAnswersMethodNotFound() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let client = Parity.client(gw)
        try await client.connect(timeout: 10)
        defer { client.close() }
        gw.push(approvalFrame())
        try await Parity.waitUntil { gw.responses.count == 1 }
        XCTAssertEqual(gw.responses.first?["id"], "srq-ab12cd34ef56")
        XCTAssertEqual(gw.responses.first?["error"]?["code"], -32601)
    }

    func testDetachedSessionNoLongerReceivesRequests() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, s, events) = try await openSession(gw)
        defer { backend.client.close() }
        s.detach()
        gw.push(approvalFrame())
        try await Parity.waitUntil { gw.responses.count == 1 }
        XCTAssertEqual(gw.responses.first?["error"]?["code"], 4404)
        XCTAssertTrue(events.all.isEmpty)
    }

    // MARK: - cancel + tool events

    func testCancelAndToolEventsDecode() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, session, events) = try await openSession(gw)
        defer { backend.client.close(); withExtendedLifetime(session) {} }
        gw.push(event("tool.generating", ["name": "terminal"]))
        gw.push(event("tool.start", ["tool_id": "t1", "name": "terminal", "context": "ls -la",
                                     "labels": [["kind": "tool", "text": "Terminal"]]]))
        gw.push(event("tool.complete", ["tool_id": "t1", "name": "terminal", "duration_s": .number(1.5), "summary": "3 files",
                                        "result": ["ok": true]]))
        gw.push(event("tool.complete", ["tool_id": "t2", "name": "web", "error": "timeout"]))
        gw.push(event("request.cancel", ["id": "srq-9", "method": "approval", "reason": "timeout"]))
        gw.push(event("approval.cancelled", ["request_ids": ["q-1", "q-2"], "reason": "interrupted"]))
        gw.push(event("tool.start", sid: "rt-other", ["tool_id": "x", "name": "other"]))
        try await Parity.waitUntil { events.all.count == 6 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(events.all, [
            .toolGenerating(name: "terminal"),
            .toolStarted(ToolStart(toolId: "t1", name: "terminal", context: "ls -la", label: "Terminal")),
            .toolCompleted(ToolCompletion(toolId: "t1", name: "terminal", duration: 1.5, summary: "3 files")),
            .toolCompleted(ToolCompletion(toolId: "t2", name: "web", failed: true)),
            .requestCancelled(id: "srq-9", reason: "timeout"),
            .approvalsCancelled(requestIds: ["q-1", "q-2"]),
        ], "another session's events are not delivered")
    }

    func testAnswerEncodings() {
        XCTAssertEqual(ServerRequestAnswer.approval(.always, all: true).result, ["choice": "always", "all": true])
        XCTAssertEqual(ServerRequestAnswer.clarifyCancel.result, [:])
        XCTAssertEqual(ServerRequestAnswer.value("").result, ["value": ""])
        let req = ServerRequest(wireId: "srq-x", method: "approval", params: ["session_id": "s"])
        guard case .approval(let a) = req.kind else { return XCTFail() }
        XCTAssertEqual(a.choices, ApprovalPrompt.Choice.allCases, "missing choices → all four offered")
        XCTAssertEqual(ServerRequest(wireId: 3, method: "vault.code", params: [:]).kind, .notShown)
        XCTAssertEqual(ServerRequest(wireId: 3, method: "vault.code", params: [:]).id, "3")
    }
}
