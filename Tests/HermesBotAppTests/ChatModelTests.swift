import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// `ChatModel` state machine against an in-memory `FakeChatLink`: open → seed → ready / failed + Retry,
/// the send gate with attachments, slash commands, server request cards, detach-only close. Headless.
@MainActor
final class ChatModelTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!

    private func model(_ opener: @escaping ChatOpener) -> ChatModel {
        let m = ChatModel(bot: bot, opener: opener)
        m.log = { _ in }
        return m
    }

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = model { _ in link }
        m.open()
        try await waitUntil { m.isReady }
        return m
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func approval(_ id: String, queue: String) -> ServerRequest {
        ServerRequest(wireId: .string(id), method: "approval",
                      params: ["session_id": "rt-fake", "request_id": .string(queue), "command": "rm -rf build"])
    }

    // MARK: open

    func testOpenSeedsHistoryAndReshowsOpenRequests() async throws {
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "hi"),
                                          ChatHistoryMessage(role: .assistant, text: "hello")],
                                openRequests: [approval("srq-1", queue: "q-1")])
        let m = model { _ in link }
        XCTAssertEqual(m.phase, .idle)
        m.open()
        XCTAssertEqual(m.phase, .loading)
        try await waitUntil { m.isReady }
        XCTAssertEqual(m.lines.map(\.role), [.user, .bot])
        XCTAssertEqual(m.requests.map(\.id), ["srq-1"])
        try await waitUntil { m.catalog != nil }
        XCTAssertEqual(link.calls.filter { $0 == "catalog" }.count, 1, "the catalog is fetched once per chat")
        m.open()
        XCTAssertEqual(m.phase, .ready, "open is idempotent")
    }

    func testOpenFailureShowsTheErrorAndRetryOpens() async throws {
        let attempts = Counter()
        let link = FakeChatLink()
        let m = model { _ in
            if attempts.next() == 1 { throw BotChatError.lookupFailed("db locked") }
            return link
        }
        m.open()
        try await waitUntil { if case .failed = m.phase { return true }; return false }
        XCTAssertEqual(m.phase, .failed(BotChatError.lookupFailed("db locked").description))
        m.open()  // Retry
        try await waitUntil { m.isReady }
    }

    func testSessionNotOwnedHasUserFacingText() {
        let text = ChatModel.message(GatewayClient.RPCError(code: 4090, message: "SESSION_NOT_OWNED", data: nil), bot: bot)
        XCTAssertEqual(text, BotChatError.sessionNotOwned(bot: "Fake").description)
        XCTAssertTrue(text.contains("another Hermes app"))
    }

    func testCloseOnlyDetaches() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.close()
        XCTAssertEqual(link.calls.filter { $0 != "catalog" }, ["detach"])
        XCTAssertTrue(link.detached)
    }

    func testCloseWhileOpeningDetachesTheLateSession() async throws {
        let link = FakeChatLink()
        // Like `openCanonical` (a shared flight), the open finishes even though the caller went away.
        let m = model { _ in try? await Task.sleep(nanoseconds: 100_000_000); return link }
        m.open()
        m.close()
        try await waitUntil { link.detached }
        XCTAssertNotEqual(m.phase, .ready)
    }

    // MARK: send gate

    func testSubmitGate() async throws {
        let link = FakeChatLink()
        let early = model { _ in link }
        early.draft = "too early"
        XCTAssertFalse(early.submit(), "nothing is sent before the chat is open")
        XCTAssertEqual(early.draft, "too early")

        let m = try await ready(link)
        m.draft = "   "
        XCTAssertFalse(m.submit())
        m.draft = "hello"
        XCTAssertTrue(m.submit())
        XCTAssertEqual(m.draft, "")
        XCTAssertEqual(m.lines.last?.text, "hello")
        m.draft = "second"
        XCTAssertFalse(m.submit(), "busy: the draft stays")
        XCTAssertEqual(m.draft, "second")
        try await waitUntil { link.calls.contains("send:hello|") }
    }

    func testTurnFromAnotherClientHoldsTheGate() async throws {
        let m = try await ready(FakeChatLink())
        m.apply(.started)
        m.apply(.delta("from Desktop"))
        m.draft = "mine"
        XCTAssertFalse(m.submit())
        m.apply(.completed(ChatCompletion(text: "from Desktop")))
        XCTAssertEqual(m.lines.map(\.role), [.bot])
        XCTAssertTrue(m.submit())
    }

    func testSendFailureEndsTheTurnWithTheError() async throws {
        let link = FakeChatLink()
        link.sendError = BotChatError.sessionNotOwned(bot: "Fake")
        let m = try await ready(link)
        m.draft = "hi"
        XCTAssertTrue(m.submit())
        try await waitUntil { !m.busy }
        XCTAssertEqual(m.lines.last?.role, .error)
        XCTAssertEqual(m.lines.last?.text, BotChatError.sessionNotOwned(bot: "Fake").description)
    }

    // MARK: slash commands

    func testSlashOutputBecomesASystemLine() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "/skills list"
        XCTAssertTrue(m.submit())
        XCTAssertEqual(m.draft, "")
        try await waitUntil { m.lines.last?.role == .system }
        XCTAssertEqual(m.lines.last?.text, "/skills ran")
        XCTAssertTrue(link.calls.contains("slash:skills list"))
        XCTAssertNil(m.activity)
        XCTAssertFalse(m.busy, "slash output is not a turn")
    }

    func testSlashSendDirectiveSubmitsATurnShowingTheDisplayText() async throws {
        let link = FakeChatLink()
        link.slashResult = { _, _ in .send(message: "expanded body", display: "/goal ship it", notice: "Goal set") }
        let m = try await ready(link)
        m.draft = "/goal ship it"
        XCTAssertTrue(m.submit())
        try await waitUntil { link.calls.contains("send:expanded body|") }
        XCTAssertEqual(m.lines.map(\.role), [.system, .user])
        XCTAssertEqual(m.lines.map(\.text), ["Goal set", "/goal ship it"], "the model-facing body is never shown")
        XCTAssertTrue(m.busy)
    }

    func testSlashPrefillPutsTextInTheComposer() async throws {
        let link = FakeChatLink()
        link.slashResult = { _, _ in .prefill(message: "previous prompt", notice: nil) }
        let m = try await ready(link)
        m.draft = "/undo"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.draft == "previous prompt" }
    }

    func testNewIsRewrittenToCompressWithTheNotice() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "/new"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.count == 2 }
        XCTAssertEqual(m.lines.map(\.text), [SlashInvocation.neverResetsNotice, "Conversation compacted: 40 → 6 messages."])
        XCTAssertTrue(link.calls.contains("compress:"))
    }

    func testHelpUnavailableAndStop() async throws {
        let link = FakeChatLink(openRequests: [approval("srq-1", queue: "q-1")])
        let m = try await ready(link)
        m.draft = "/title x"
        XCTAssertTrue(m.submit())
        XCTAssertEqual(m.lines.last?.text, "The Bot Chat keeps its name; /title is not available here.")
        m.draft = "/help"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.text.hasPrefix("Commands:") == true }
        XCTAssertTrue(m.lines.last!.text.contains("/goal — Set a goal"))
        m.draft = "/stop"
        XCTAssertTrue(m.submit())
        XCTAssertTrue(m.requests.isEmpty, "stop declines the open requests")
        try await waitUntil { link.calls.contains("interrupt") }
        XCTAssertTrue(link.calls.contains("decline:srq-1:\(ServerRequest.interruptedCode)"))
    }

    func testBackendSlashRunsMidTurnAndTheBackendDecides() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "hi"
        XCTAssertTrue(m.submit())
        m.draft = "/status-like x"
        XCTAssertTrue(m.submit(), "backend commands may run while a reply runs (/steer, /queue…)")
        try await waitUntil { link.calls.contains("slash:status-like x") }
        try await waitUntil { m.activity == nil }
        m.draft = "/compress"
        XCTAssertFalse(m.submit(), "compaction still waits for the turn")
        m.draft = "/stop"
        XCTAssertTrue(m.submit())
    }

    // MARK: server requests

    func testRequestCardsLifecycle() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        let a = approval("srq-a", queue: "q-a")
        m.apply(.request(a))
        m.apply(.request(a))
        XCTAssertEqual(m.requests.map(\.id), ["srq-a"], "duplicates are ignored")
        m.cardShown(a)
        m.cardShown(a)
        try await waitUntil { link.calls.contains("received:q-a") }
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("received:") }.count, 1, "approval.received once per card")

        m.apply(.approvalsCancelled(requestIds: ["q-a"]))
        XCTAssertTrue(m.requests.isEmpty)

        let b = approval("srq-b", queue: "q-b")
        m.apply(.request(b))
        m.apply(.requestCancelled(id: "srq-b", reason: "timeout"))
        XCTAssertTrue(m.requests.isEmpty)

        let c = approval("srq-c", queue: "q-c")
        m.apply(.request(c))
        m.respond(c, .approval(.once))
        XCTAssertTrue(m.answering.contains("srq-c"))
        try await waitUntil { m.requests.isEmpty }
        XCTAssertTrue(link.calls.contains("answer:srq-c"))
        XCTAssertFalse(m.answering.contains("srq-c"))
    }

    func testReclaimDropsRequestsAndEndsARunningTurn() async throws {
        let m = try await ready(FakeChatLink())
        m.draft = "hi"
        XCTAssertTrue(m.submit())
        m.apply(.request(approval("srq-1", queue: "q-1")))
        m.apply(.other("session.reclaimed"))
        XCTAssertTrue(m.requests.isEmpty)
        XCTAssertFalse(m.busy)
        XCTAssertEqual(m.lines.last?.role, .error)
    }
}

/// Thread-safe counter for opener closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
