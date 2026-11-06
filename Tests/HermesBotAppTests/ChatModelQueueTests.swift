import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B8: steering the running turn and the message queue (Return steers, ⌘Return queues, auto-drain when the
/// turn settles, Stop pauses, Edit / Send now / Delete). Headless, against `FakeChatLink`.
@MainActor
final class ChatModelQueueTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link })
        m.log = { _ in }
        m.drainFallbackDelay = 0
        m.checkFile = { url in ChatAttachments.Checked(url: url, name: url.lastPathComponent, kind: ChatAttachments.kind(of: url), bytes: 1) }
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

    private func sends(_ link: FakeChatLink) -> [String] { link.calls.filter { $0.hasPrefix("send:") } }

    /// A local turn that is still running.
    private func running(_ m: ChatModel, _ link: FakeChatLink, prompt: String = "first") async throws {
        m.draft = prompt
        XCTAssertTrue(m.submit())
        try await waitUntil { link.calls.contains("send:\(prompt)|") }
        m.apply(.delta("working"))
    }

    // MARK: composer action

    func testComposerActionFollowsTheTurn() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "hi"
        XCTAssertEqual(m.composerAction, .send)
        try await running(m, link)
        m.draft = "faster please"
        XCTAssertEqual(m.composerAction, .steer, "Return steers a turn this chat started")
        XCTAssertTrue(m.canPrimary)
        m.draft = "/help"
        XCTAssertEqual(m.composerAction, .send, "slash commands still run at once")
        m.draft = "with a file"
        m.addAttachments([URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertEqual(m.composerAction, .queue, "a correction carries text only: files queue")
    }

    func testATurnRunningElsewhereIsQueuedNotRedirected() async throws {
        let link = FakeChatLink(inflight: InflightTurn(user: "from Desktop", assistant: "Work"))
        let m = try await ready(link)
        XCTAssertTrue(m.busy)
        m.draft = "mine"
        XCTAssertEqual(m.composerAction, .queue)
        XCTAssertFalse(m.steer())
        XCTAssertTrue(m.primaryAction())
        XCTAssertEqual(m.queue.map(\.text), ["mine"])
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("redirect:") }, "Desktop's reply is never redirected from here")
    }

    // MARK: steer

    func testReturnSteersTheRunningTurnWithSessionRedirect() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "shorter"
        XCTAssertTrue(m.primaryAction())
        XCTAssertEqual(m.draft, "")
        XCTAssertEqual(m.lines.map(\.role), [.user, .bot, .user], "the correction sits below what streamed")
        try await waitUntil { link.calls.contains("redirect:shorter") }
        m.apply(.delta("Short."))
        m.apply(.completed(ChatCompletion(text: "Short.")))
        XCTAssertEqual(m.lines.map(\.text), ["first", "working", "shorter", "Short."])
        XCTAssertTrue(m.queue.isEmpty)
        XCTAssertEqual(sends(link), ["send:first|"], "a steer is no new turn")
    }

    func testARefusedSteerIsQueuedAndSentWhenTheTurnEnds() async throws {
        let link = FakeChatLink()
        link.redirectResult = { _ in "rejected" }
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "then this"
        XCTAssertTrue(m.steer())
        try await waitUntil { m.queue.map(\.text) == ["then this"] }
        XCTAssertEqual(m.lines.map(\.role), [.user, .bot], "the refused line is taken back")
        XCTAssertEqual(m.lines.last?.streaming, true, "and the reply keeps growing in one bubble")
        m.apply(.completed(ChatCompletion(text: "working")))
        try await waitUntil { self.sends(link) == ["send:first|", "send:then this|"] }
        XCTAssertTrue(m.queue.isEmpty)
        XCTAssertEqual(m.lines.last?.text, "then this")
    }

    func testAFailedSteerIsQueuedToo() async throws {
        let link = FakeChatLink()
        link.redirectResult = { _ in throw GatewayClient.RPCError(code: 4010, message: "agent does not support active-turn redirect", data: nil) }
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "keep me"
        XCTAssertTrue(m.steer())
        try await waitUntil { m.queue.map(\.text) == ["keep me"] }
    }

    func testASteerTheBackendQueuedKeepsTheLineWithANote() async throws {
        let link = FakeChatLink()
        link.redirectResult = { _ in "queued" }
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "after this step"
        XCTAssertTrue(m.steer())
        try await waitUntil { m.lines.contains { $0.role == .system } }
        XCTAssertTrue(m.lines.contains { $0.role == .user && $0.text == "after this step" })
        XCTAssertTrue(m.queue.isEmpty, "the backend holds it; nothing is queued twice")
    }

    // MARK: queue

    func testCommandReturnQueuesWhileBusyAndSendsWhenIdle() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "idle send"
        XCTAssertTrue(m.queueOrSend(), "⌘Return when idle is Send")
        try await waitUntil { link.calls.contains("send:idle send|") }
        m.apply(.delta("…"))
        m.draft = "one"
        XCTAssertTrue(m.queueOrSend())
        m.draft = "two"
        XCTAssertTrue(m.queueOrSend())
        XCTAssertEqual(m.queue.map(\.text), ["one", "two"])
        XCTAssertEqual(m.draft, "")
        XCTAssertEqual(sends(link), ["send:idle send|"])

        m.apply(.completed(ChatCompletion(text: "…")))
        m.apply(.idle)
        try await waitUntil { self.sends(link).count == 2 }
        XCTAssertEqual(m.queue.map(\.text), ["two"], "one at a time: the next waits for this turn")
        XCTAssertTrue(m.busy)
        m.apply(.completed(ChatCompletion(text: "ok")))
        try await waitUntil { self.sends(link) == ["send:idle send|", "send:one|", "send:two|"] }
        XCTAssertTrue(m.queue.isEmpty)
    }

    func testQueuedFilesGoOutWithTheirMessage() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.addAttachments([URL(fileURLWithPath: "/tmp/notes.txt")])
        m.draft = "read this"
        XCTAssertTrue(m.queueOrSend())
        XCTAssertTrue(m.pending.isEmpty, "the chips move into the queued message")
        XCTAssertEqual(m.queue.first?.preview, "read this\n\nAttached: notes.txt")
        m.apply(.completed(ChatCompletion(text: "done")))
        try await waitUntil { link.calls.contains("send:read this|notes.txt") }
    }

    func testStopPausesTheQueueUntilResume() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "later"
        m.queueOrSend()
        m.stop()
        XCTAssertTrue(m.queueParked)
        try await waitUntil { link.calls.contains("interrupt") }
        m.apply(.completed(ChatCompletion(text: "working", status: "interrupted")))
        m.apply(.idle)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sends(link), ["send:first|"], "a paused queue waits")
        m.resumeQueue()
        try await waitUntil { self.sends(link) == ["send:first|", "send:later|"] }
        XCTAssertFalse(m.queueParked)
    }

    func testSendNowWhileBusyInterruptsAndSendsThatMessageNext() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "a"; m.queueOrSend()
        m.draft = "b"; m.queueOrSend()
        m.sendQueuedNow(m.queue[1].id)
        XCTAssertEqual(m.queue.map(\.text), ["b", "a"], "promoted to the head")
        XCTAssertFalse(m.queueParked, "Send now does not pause the queue")
        try await waitUntil { link.calls.contains("interrupt") }
        m.apply(.completed(ChatCompletion(text: "working", status: "interrupted")))
        try await waitUntil { self.sends(link).last == "send:b|" }
    }

    func testSendNowWhenIdleSendsAPausedMessage() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "x"; m.queueOrSend()
        m.stop()
        m.apply(.completed(ChatCompletion(text: "working", status: "interrupted")))
        XCTAssertTrue(m.queueParked)
        m.sendQueuedNow(m.queue[0].id)
        try await waitUntil { self.sends(link).last == "send:x|" }
    }

    func testEditAndDelete() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "typo"; m.queueOrSend()
        m.draft = "gone"; m.queueOrSend()
        m.draft = "my unsent draft"
        m.beginQueueEdit(m.queue[0].id)
        XCTAssertEqual(m.draft, "typo")
        XCTAssertEqual(m.composerAction, .saveEdit)
        m.draft = "fixed"
        XCTAssertTrue(m.primaryAction())
        XCTAssertEqual(m.queue.map(\.text), ["fixed", "gone"])
        XCTAssertEqual(m.draft, "my unsent draft", "the draft from before Edit comes back")
        XCTAssertNil(m.editingQueueId)

        m.beginQueueEdit(m.queue[0].id)
        m.draft = "discarded"
        m.cancelQueueEdit()
        XCTAssertEqual(m.queue.map(\.text), ["fixed", "gone"])
        XCTAssertEqual(m.draft, "my unsent draft")

        m.deleteQueued(m.queue[1].id)
        XCTAssertEqual(m.queue.map(\.text), ["fixed"])
        m.beginQueueEdit(m.queue[0].id)
        m.draft = "  "
        m.saveQueueEdit()
        XCTAssertTrue(m.queue.isEmpty, "an emptied message is deleted")
    }

    func testTheMessageBeingEditedIsNotSent() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "editing"; m.queueOrSend()
        m.draft = "next"; m.queueOrSend()
        m.beginQueueEdit(m.queue[0].id)
        m.apply(.completed(ChatCompletion(text: "working")))
        try await waitUntil { self.sends(link).last == "send:next|" }
        XCTAssertEqual(m.queue.map(\.text), ["editing"])
    }

    func testAFailedQueuedSendGoesBackPaused() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "will fail"; m.queueOrSend()
        link.sendError = GatewayClient.ClientError.closed("gone")
        m.apply(.completed(ChatCompletion(text: "working")))
        try await waitUntil { m.queueParked }
        XCTAssertEqual(m.queue.map(\.text), ["will fail"])
        XCTAssertFalse(m.busy)
        XCTAssertEqual(m.lines.last?.role, .error)
    }

    func testAMessageHeldByAClientActionGoesOutWhenItEnds() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "after"; m.queueOrSend()
        m.activity = "Running /goal"
        m.apply(.completed(ChatCompletion(text: "working")))
        m.apply(.idle)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sends(link), ["send:first|"], "held while the action runs")
        m.activity = nil
        try await waitUntil { self.sends(link) == ["send:first|", "send:after|"] }
    }

    func testSlashCommandsAreNotQueued() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        try await running(m, link)
        m.draft = "/help"
        XCTAssertFalse(m.canQueue)
        XCTAssertTrue(m.queueOrSend(), "runs now, like Return")
        XCTAssertTrue(m.queue.isEmpty)
    }

    func testCloseDeletesPastedFilesOfQueuedMessages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hba-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasted = folder.appendingPathComponent("paste.png")
        try Data([1]).write(to: pasted)
        let link = FakeChatLink()
        let m = try await ready(link)
        m.pasteFolder = folder
        try await running(m, link)
        m.addAttachments([pasted])
        m.draft = "img"
        m.queueOrSend()
        m.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasted.path))
        XCTAssertTrue(m.queue.isEmpty)
    }

    func testHintsAndLabelsSayWhatReturnDoes() {
        XCTAssertEqual(ChatComposer.primaryLabel(.steer), "Steer")
        XCTAssertEqual(ChatComposer.hints(.steer).map(\.keys), ["Return", "⌘Return"])
        XCTAssertEqual(ChatComposer.hints(.queue).map(\.label), ["queue"])
        XCTAssertEqual(ChatQueuePanel.title(count: 2, parked: true), "2 queued · paused")
        XCTAssertEqual(ChatQueuePanel.title(count: 1, parked: false), "1 queued")
    }
}
