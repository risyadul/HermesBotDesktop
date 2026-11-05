import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// The send path after the review round: local chips staged only inside `submit` (rollback, restore),
/// the gates (activity, reconnect, a turn already running at resume), submit status notes, hidden
/// commands, compaction history, request state cleanup, pasted image files, the sidebar badge. Headless.
@MainActor
final class ChatModelSendTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link })
        m.log = { _ in }
        m.checkFile = { url in
            if url.pathExtension == "bin" { throw ChatAttachments.Failure.tooLarge(url.lastPathComponent, limitMB: 25) }
            return ChatAttachments.Checked(url: url, name: url.lastPathComponent, kind: ChatAttachments.kind(of: url), bytes: 1)
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

    private let cat = URL(fileURLWithPath: "/tmp/cat.png"), notes = URL(fileURLWithPath: "/tmp/notes.txt")

    // MARK: local chips (A-H1)

    func testChipsStayLocalUntilSendAndGoOutWithTheText() async throws {
        let link = FakeChatLink()
        link.submitDelay = 100_000_000
        let m = try await ready(link)
        m.addAttachments([cat, notes, cat])
        XCTAssertEqual(m.pending.count, 2, "a file already pending is not added twice")
        XCTAssertTrue(m.pending.allSatisfy(\.isReady), "no upload at pick time")
        XCTAssertEqual(link.calls.filter { $0 != "catalog" }, [], "nothing reaches the shared session before Send")
        m.removeAttachment(m.pending[1].id)
        XCTAssertEqual(link.calls.filter { $0 != "catalog" }, [], "removing a local chip needs no detach")
        m.addAttachments([notes])
        m.draft = "look"
        XCTAssertTrue(m.submit())
        XCTAssertTrue(m.pending.allSatisfy(\.isSending), "progress shows on the chips during the send")
        XCTAssertFalse(m.canSend)
        m.removeAttachment(m.pending[0].id)
        XCTAssertEqual(m.pending.count, 2, "a chip being staged cannot be removed")
        XCTAssertEqual(m.lines.last?.text, "look\n\nAttached: cat.png, notes.txt")
        try await waitUntil { m.pending.isEmpty }
        XCTAssertTrue(link.calls.contains("send:look|cat.png,notes.txt"))
    }

    func testStageFailureRestoresChipsAndDraftWithTheErrorOnTheFailedChip() async throws {
        let link = FakeChatLink()
        link.stageError = "notes.txt"
        let m = try await ready(link)
        m.addAttachments([cat, notes])
        m.draft = "look"
        XCTAssertTrue(m.submit())
        try await waitUntil { !m.busy }
        XCTAssertTrue(link.calls.contains("rollback:cat.png"), "what was staged in this send is taken back")
        XCTAssertEqual(m.draft, "look", "the draft comes back")
        XCTAssertEqual(m.pending.map(\.state), [.ready, .failed("notes.txt could not be attached.")])
        XCTAssertEqual(m.lines.last?.role, .error)
    }

    func testSessionNotOwnedKeepsTheDraftAndTheChips() async throws {
        let link = FakeChatLink()
        link.sendError = BotChatError.sessionNotOwned(bot: "Fake")
        let m = try await ready(link)
        m.addAttachments([cat])
        m.draft = "hi"
        XCTAssertTrue(m.submit())
        try await waitUntil { !m.busy }
        XCTAssertEqual(m.draft, "hi")
        XCTAssertEqual(m.pending.map(\.state), [.ready])
        XCTAssertEqual(m.lines.last?.text, BotChatError.sessionNotOwned(bot: "Fake").description)
    }

    func testRefusedChipStaysVisibleAndIsNotSent() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.addAttachments([URL(fileURLWithPath: "/tmp/big.bin"), cat])
        XCTAssertEqual(m.pending[0].error, "big.bin is too large; the limit is 25 MB.")
        m.draft = "x"
        XCTAssertTrue(m.submit())
        try await waitUntil { link.calls.contains("send:x|cat.png") }
        try await waitUntil { m.pending.count == 1 }
        XCTAssertTrue(m.pending[0].isFailed, "the refused chip keeps its error until removed")
    }

    func testSlashSendDirectiveLeavesChipsLocal() async throws {
        let link = FakeChatLink()
        link.slashResult = { _, _ in .send(message: "body", display: "/goal x", notice: nil) }
        let m = try await ready(link)
        m.addAttachments([cat])
        m.draft = "/goal x"
        XCTAssertTrue(m.submit())
        try await waitUntil { link.calls.contains("send:body|") }
        XCTAssertEqual(m.pending.map(\.state), [.ready], "a directive never carries the composer's files")
    }

    // MARK: gates (M3, reclaim, A-H2)

    func testActivityBlocksSending() async throws {
        let m = try await ready(FakeChatLink())
        m.activity = "Compacting the conversation"
        m.draft = "hi"
        XCTAssertFalse(m.canSend)
        XCTAssertFalse(m.submit())
        XCTAssertEqual(m.draft, "hi")
        m.activity = nil
        XCTAssertTrue(m.canSend)
    }

    func testReclaimBlocksSendingUntilResumed() async throws {
        let m = try await ready(FakeChatLink())
        m.apply(.other("session.reclaimed"))
        m.draft = "hi"
        XCTAssertFalse(m.canSend)
        XCTAssertFalse(m.submit())
        m.apply(.resumed(history: [], inflight: nil))
        XCTAssertTrue(m.submit())
    }

    func testResumeMidTurnJoinsTheRunningReplyWithTheGateClosed() async throws {
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "earlier")],
                                inflight: InflightTurn(user: "what now?", assistant: "Working on"))
        let m = try await ready(link)
        XCTAssertTrue(m.busy)
        XCTAssertEqual(m.lines.map(\.role), [.user, .user, .bot])
        XCTAssertEqual(m.lines.last?.text, "Working on")
        XCTAssertTrue(m.lines.last?.streaming == true)
        m.draft = "mine"
        XCTAssertFalse(m.submit(), "a send cannot redirect the turn Desktop is running")
        m.apply(.delta(" it"))
        m.apply(.completed(ChatCompletion(text: "Working on it")))
        XCTAssertEqual(m.lines.last?.text, "Working on it")
        XCTAssertTrue(m.submit())
    }

    func testQueuedSubmitIsToldToTheUser() async throws {
        let link = FakeChatLink()
        link.submitStatus = "queued"
        let m = try await ready(link)
        m.draft = "hi"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.role == .system }
        XCTAssertEqual(m.lines.last?.text, ChatModel.submitNote("queued", bot: "Fake"))
        XCTAssertNil(ChatModel.submitNote("streaming", bot: "Fake"))
        XCTAssertNotNil(ChatModel.submitNote("redirected", bot: "Fake"))
    }

    // MARK: slash (A-M4, L9)

    func testHiddenBuiltInIsRefusedWhenTyped() async throws {
        let link = FakeChatLink()
        link.catalogResult = {
            SlashCatalog(result: ["pairs": [["/goal", "Set a goal"]], "canon": ["/q": "/quit"],
                                  "commands": ["/quit": ["desktop": "terminal"], "/goal": ["desktop": nil]]])
        }
        let m = try await ready(link)
        m.draft = "/q"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.role == .system }
        XCTAssertEqual(m.lines.last?.text, "/quit is only available in the terminal interface.")
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("slash:") }, "never sent to slash.exec")
    }

    func testCompactionHistoryReplacesTheTranscript() async throws {
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "a"), ChatHistoryMessage(role: .assistant, text: "b")])
        link.compressHistory = [ChatHistoryMessage(role: .system, text: "summary")]
        let m = try await ready(link)
        m.draft = "/compress"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.text.hasPrefix("Conversation compacted") == true }
        XCTAssertEqual(m.lines.map(\.text), ["summary", "Conversation compacted: 40 → 6 messages."])
    }

    // MARK: requests (L7)

    func testDisconnectClearsAnsweringAndErrors() async throws {
        let m = try await ready(FakeChatLink())
        let r = ServerRequest(wireId: "srq-1", method: "approval", params: ["session_id": "rt-fake", "command": "ls"])
        m.apply(.request(r))
        m.answering.insert("srq-1")
        m.requestErrors["srq-1"] = "failed"
        m.apply(.disconnected("gone"))
        XCTAssertTrue(m.requests.isEmpty)
        XCTAssertTrue(m.answering.isEmpty)
        XCTAssertTrue(m.requestErrors.isEmpty)
    }

    // MARK: pasted images (SL3)

    func testPastedImageIsDeletedWhenItsTurnSettlesOrItsChipIsRemoved() async throws {
        let m = try await ready(FakeChatLink())
        // An injected temp folder: never the app's shared paste folder.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hba-paste-\(UUID().uuidString)")
        m.pasteFolder = folder
        defer { PasteboardAttachments.purge(folder: folder) }
        let sent = try XCTUnwrap(PasteboardAttachments.write(Data([1, 2]), in: folder))
        let dropped = try XCTUnwrap(PasteboardAttachments.write(Data([3]), in: folder))
        m.addAttachments([sent, dropped])
        XCTAssertTrue(m.pending.allSatisfy { PasteboardAttachments.isPasted($0.url, folder: folder) })
        m.removeAttachment(m.pending[1].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))
        m.draft = "see"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.pending.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sent.path), "the backend reads it during the turn")
        m.apply(.completed(ChatCompletion(text: "ok")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.path))
    }

    // MARK: sidebar badge (A-M5)

    func testSidebarBadge() {
        XCTAssertEqual(BotChatBadge.kind(requests: 0, busy: false), .none)
        XCTAssertEqual(BotChatBadge.kind(requests: 0, busy: true), .replying)
        XCTAssertEqual(BotChatBadge.kind(requests: 2, busy: true), .waiting(2))
        XCTAssertEqual(BotChatBadge.accessibilityLabel(.waiting(1), bot: "Fake"), "Fake needs your answer")
        XCTAssertNil(BotChatBadge.accessibilityLabel(.none, bot: "Fake"))
    }
}
