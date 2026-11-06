import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Fix round 2 on the model: Stop on a turn whose settling event never comes, `.idle`, the reclaim reseed,
/// send gates while reconnecting / compacting mid-turn, the offline slash refusal, failed sends, pasted
/// files per submit status, and the fake link's single-consumer buffering. Headless.
@MainActor
final class ChatModelSettleTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hba-paste-\(UUID().uuidString)")
    }

    override func tearDown() async throws { PasteboardAttachments.purge(folder: folder) }

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link })
        m.log = { _ in }
        m.pasteFolder = folder
        m.stopSettleDelay = 50_000_000
        m.checkFile = { url in
            ChatAttachments.Checked(url: url, name: url.lastPathComponent, kind: ChatAttachments.kind(of: url), bytes: 1)
        }
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

    // MARK: stop / idle (item 2b)

    func testStopOnASeededTurnSettlesLocallyWhenNoEventArrives() async throws {
        let link = FakeChatLink(inflight: InflightTurn(user: "q", assistant: "half"))
        let m = try await ready(link)
        XCTAssertTrue(m.busy)
        m.stop()
        try await waitUntil { !m.busy }
        XCTAssertTrue(link.calls.contains("interrupt"))
        XCTAssertEqual(m.lines.last?.text, "Stopped.")
        m.draft = "next"
        XCTAssertTrue(m.submit(), "the gate reopened")
    }

    func testStopDoesNotSettleWhenTheTurnSettlesItself() async throws {
        let m = try await ready(FakeChatLink(inflight: InflightTurn(user: "q", assistant: "half")))
        m.stopSettleDelay = 300_000_000
        m.stop()
        m.apply(.completed(ChatCompletion(text: "half done", status: "interrupted")))
        XCTAssertFalse(m.busy)
        m.draft = "again"
        XCTAssertTrue(m.submit(), "a new local turn")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(m.busy, "the delayed check never touches a newer turn")
        XCTAssertFalse(m.lines.contains { $0.text == "Stopped." })
    }

    func testIdleReportSettlesASeededTurn() async throws {
        let m = try await ready(FakeChatLink(inflight: InflightTurn(user: "q", assistant: "half")))
        m.apply(.idle)
        XCTAssertFalse(m.busy)
    }

    // MARK: reclaim reseed (item 3)

    func testResumedReseedsHistoryAndJoinsTheRunningTurn() async throws {
        let m = try await ready(FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "old")]))
        m.apply(.other("session.reclaimed"))
        m.apply(.resumed(history: [ChatHistoryMessage(role: .user, text: "a"), ChatHistoryMessage(role: .assistant, text: "b")],
                         inflight: InflightTurn(user: "c", assistant: "d")))
        XCTAssertFalse(m.reconnecting)
        XCTAssertEqual(m.lines.map(\.text), ["a", "b", "c", "d"])
        XCTAssertTrue(m.busy, "the running turn holds the gate")
    }

    func testSlashSendDirectiveIsRefusedWhileReconnecting() async throws {
        let link = FakeChatLink()
        link.slashResult = { _, _ in .send(message: "expanded", display: "/goal x", notice: nil) }
        let m = try await ready(link)
        m.apply(.other("session.reclaimed"))
        m.render(.send(message: "expanded", display: "/goal x", notice: nil), typed: "/goal x")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("send:") })
        XCTAssertFalse(m.busy)
    }

    // MARK: slash gates (items 4, 5)

    func testHiddenBuiltInIsRefusedWhenTheCatalogFailed() async throws {
        let link = FakeChatLink()
        link.catalogResult = { throw GatewayClient.ClientError.notConnected }
        let m = try await ready(link)
        m.draft = "/config"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.role == .system }
        XCTAssertEqual(m.lines.last?.text, "/config is only available in the terminal interface.")
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("slash:") }, "never fails open")
    }

    func testCompressCannotBeSentMidTurn() async throws {
        let m = try await ready(FakeChatLink(inflight: InflightTurn(user: "q", assistant: "")))
        m.draft = "/compress"
        XCTAssertFalse(m.canSend, "Send mirrors the compress guard")
        m.draft = "/stop"
        XCTAssertTrue(m.canSend)
    }

    // MARK: failed send (item 6)

    func testFailedSendRemovesTheUserLineSoAResendIsNotDuplicated() async throws {
        let link = FakeChatLink()
        link.sendError = GatewayClient.ClientError.notConnected
        let m = try await ready(link)
        m.draft = "hello"
        XCTAssertTrue(m.submit())
        try await waitUntil { !m.busy }
        XCTAssertEqual(m.draft, "hello")
        XCTAssertFalse(m.lines.contains { $0.role == .user })
        link.sendError = nil
        XCTAssertTrue(m.submit())
        XCTAssertEqual(m.lines.filter { $0.role == .user }.count, 1)
    }

    // MARK: pasted files per status (items 11, 17)

    private func pasted(_ m: ChatModel) throws -> URL {
        let url = try XCTUnwrap(PasteboardAttachments.write(Data([1]), in: folder))
        m.addAttachments([url])
        return url
    }

    func testPastedFileGoesAtOnceWhenTheTurnSettledBeforeTheSubmitReply() async throws {
        let link = FakeChatLink()
        link.submitDelay = 100_000_000
        let m = try await ready(link)
        let url = try pasted(m)
        m.draft = "look"
        XCTAssertTrue(m.submit())
        m.apply(.completed(ChatCompletion(text: "seen")))  // settles before `prompt.submit` returns
        try await waitUntil { m.pending.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(m.sentTemporaryFiles.isEmpty)
    }

    func testQueuedPastedFileIsKeptUntilClose() async throws {
        let link = FakeChatLink()
        link.submitStatus = "queued"
        let m = try await ready(link)
        let url = try pasted(m)
        m.draft = "look"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.pending.isEmpty }
        m.apply(.completed(ChatCompletion(text: "the turn before")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the queued turn has not read it yet")
        m.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: fake link parity (item 16)

    func testFakeLinkBuffersEventsUntilTheConsumerIsSet() {
        let link = FakeChatLink()
        let got = LockedEvents()
        link.emit(.delta("a"))
        link.emit(.delta("b"))
        link.onEvent { got.add($0) }
        link.emit(.delta("c"))
        XCTAssertEqual(got.all, [.delta("a"), .delta("b"), .delta("c")])
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatEvent] = []
    func add(_ e: ChatEvent) { lock.withLock { events.append(e) } }
    var all: [ChatEvent] { lock.withLock { events } }
}
