import Foundation
import XCTest
@testable import HermesGatewayKit

/// Frames the backend sends for a session before this client subscribed to it (the gap between the
/// backend attaching our socket inside `session.resume` and its reply), plus the subscription edges around
/// it: held requests expire into a `4404`, `detach` before `onEvent` declines buffered requests, `attach`
/// after `detach` keeps nothing, the reclaim re-resume reseeds, stranded staged images are taken back.
final class SessionGapTests: XCTestCase {
    private static let found: JSONValue = ["sessions": [["id": "st-root", "resolved_id": "st-tip", "title": "Bot Chat",
                                                          "root_title": "Bot Chat"]]]

    private static func event(_ type: String, sid: String, _ payload: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": "event", "params": ["type": .string(type), "session_id": .string(sid), "payload": payload]]
    }

    private static func approval(_ id: String, sid: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": .string(id), "method": "approval",
         "params": ["session_id": .string(sid), "request_id": "q-1", "command": "ls"]]
    }

    private func requestIds(_ events: [ChatEvent]) -> [String] {
        events.compactMap { if case .request(let r) = $0 { return r.id }; return nil }
    }

    func testDeltaRequestAndCompleteSentBeforeTheResumeReplyAreDeliveredAfterAttach() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume":
                // The backend attaches the socket before replying: these frames precede the reply.
                gw.pushInline(Self.event("message.delta", sid: "rt-9", ["text": "early "]))
                gw.pushInline(Self.approval("srq-early", sid: "rt-9"))
                gw.pushInline(Self.event("message.complete", sid: "rt-9", ["text": "early done", "status": "complete"]))
                return ["session_id": "rt-9", "stored_session_id": "st-tip", "messages": [], "info": [:]]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw, holdWindow: 5)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        try await Parity.waitUntil {
            events.all.contains(.delta("early ")) && self.requestIds(events.all) == ["srq-early"]
                && events.all.contains(.completed(ChatCompletion(text: "early done")))
        }
        let delta = events.all.firstIndex(of: .delta("early "))
        let done = events.all.firstIndex(of: .completed(ChatCompletion(text: "early done")))
        XCTAssertLessThan(try XCTUnwrap(delta), try XCTUnwrap(done), "replayed in arrival order")
        XCTAssertTrue(gw.responses.isEmpty, "a held request that was claimed is never declined")
        XCTAssertEqual(backend.requests.heldCount, 0)
    }

    func testUnclaimedHeldRequestIsDeclinedOnlyAfterTheWindow() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let backend = try await Parity.backend(gw, holdWindow: 0.6)
        defer { backend.client.close() }
        gw.push(Self.approval("srq-orphan", sid: "rt-nobody"))
        try await Parity.waitUntil { backend.requests.heldCount == 1 }
        XCTAssertTrue(gw.responses.isEmpty, "not declined at once: a subscriber may still attach")
        try await Parity.waitUntil { gw.responses.count == 1 }
        XCTAssertEqual(gw.responses.first?["id"], "srq-orphan")
        XCTAssertEqual(gw.responses.first?["error"]?["code"], 4404)
        XCTAssertEqual(backend.requests.heldCount, 0)
    }

    func testDisconnectDropsHeldRequestsWithoutALateDecline() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        // A long hold window: only the disconnect (not expiry) can empty the hold within the 2 s wait below.
        let backend = try await Parity.backend(gw, holdWindow: 30)
        defer { backend.client.close() }
        gw.push(Self.approval("srq-dropped", sid: "rt-nobody"))
        try await Parity.waitUntil { backend.requests.heldCount == 1 }
        gw.dropAll()
        try await Parity.waitUntil(2) { backend.requests.heldCount == 0 }
        XCTAssertTrue(gw.responses.isEmpty, "a request held when the socket dropped is never declined later")
    }

    func testDetachBeforeOnEventDeclinesBufferedRequests() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        gw.push(Self.approval("srq-buffered", sid: "rt-1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(gw.responses.isEmpty, "buffered for the consumer to come")
        s.detach()
        try await Parity.waitUntil { gw.responses.count == 1 }
        XCTAssertEqual(gw.responses.first?["id"], "srq-buffered")
        XCTAssertEqual(gw.responses.first?["error"]?["code"], 4404)
    }

    func testAttachAfterDetachKeepsNoSubscription() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try BotChatSession(backend: backend, bot: Parity.bot, result: ["session_id": "rt-x"])
        s.detach()
        s.attach()
        XCTAssertEqual(backend.router.subscriberCount, 0, "events, disconnect and broadcast subscriptions dropped")
        XCTAssertEqual(backend.requests.subscriberCount, 0)
    }

    func testReclaimReResumeEmitsTheNewHistoryAndRunningTurn() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let resumes = Collector<Int>()
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume":
                guard resumes.bump(1) == 2 else { return ["session_id": "rt-1", "messages": [], "info": [:]] }
                return ["session_id": "rt-2", "messages": [["role": "user", "text": "hi"], ["role": "assistant", "text": "yo"]],
                        "running": true, "inflight": ["user": "next?", "assistant": "Thinking", "streaming": true], "info": [:]]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        gw.push(Self.event("session.reclaimed", sid: "", ["session_id": "rt-1", "reason": "idle_timeout"]))
        try await Parity.waitUntil { events.all.contains { if case .resumed = $0 { return true }; return false } }
        XCTAssertTrue(events.all.contains(.resumed(history: [ChatHistoryMessage(role: .user, text: "hi"),
                                                             ChatHistoryMessage(role: .assistant, text: "yo")],
                                                   inflight: InflightTurn(user: "next?", assistant: "Thinking"))))
    }

    func testImagesStrandedByASocketDropAreDetachedOnTheNextOpen() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let bot = Bot(["name": .string("strand-\(UUID().uuidString.prefix(8))")])!
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume": return ["session_id": "rt-live", "messages": [], "info": [:]]
            case "image.attach": return ["attached": true, "path": "/tmp/hba-strand.png", "count": 1]
            case "prompt.submit":
                gw.dropInline()  // the socket is gone after the attach, before the submit is answered
                return [:]
            default: return Parity.defaults(m)
            }
        }
        let first = try await Parity.backend(gw)
        let s = try await BotChatSession.openCanonical(first, bot: bot)
        let image = ChatAttachments.Checked(url: URL(fileURLWithPath: "/tmp/hba-strand.png"), name: "hba-strand.png",
                                            kind: .image, bytes: 1)
        do { _ = try await s.submit("look", files: [image]); XCTFail("submitted") } catch {}
        XCTAssertEqual(StrandedImages.shared.take(bot.name), ["/tmp/hba-strand.png"])
        StrandedImages.shared.strand(bot.name, ["/tmp/hba-strand.png"])  // put back for the reopen below
        first.client.close()

        let second = try await Parity.backend(gw)
        defer { second.client.close() }
        _ = try await BotChatSession.openCanonical(second, bot: bot)
        let detach = gw.received.last { $0["method"]?.string == "image.detach" }
        XCTAssertEqual(detach?["params"], ["session_id": "rt-live", "path": "/tmp/hba-strand.png"])
        XCTAssertTrue(StrandedImages.shared.take(bot.name).isEmpty)
    }
}
