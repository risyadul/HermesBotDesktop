import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B3 regenerate / edit / restore, B4 branch, B10 error cards, B11 URL / folder / long paste and image zoom,
/// B14 approval mode, on `ChatModel` against `FakeChatLink` (headless: no gateway, no prompt reaches a backend).
@MainActor
final class ChatRewindModelTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake", "model": "m1", "provider": "anthropic"])!

    private static let history = [
        ChatHistoryMessage(role: .user, text: "first", rowId: 10),
        ChatHistoryMessage(role: .assistant, text: "one", rowId: 11),
        ChatHistoryMessage(role: .user, text: "second", rowId: 12),
        ChatHistoryMessage(role: .assistant, text: "two", rowId: 13),
    ]

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link })
        m.log = { _ in }
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

    private func line(_ m: ChatModel, _ text: String) -> ChatLine { m.lines.first { $0.text == text }! }

    // MARK: B3 regenerate

    func testTailRegenerateRewindsWithoutAsking() async throws {
        let l = FakeChatLink(history: Self.history)
        l.rewindResult = { _ in RewindReceipt(status: "streaming", survivorMap: [10: 20, 11: 21], userRowId: 22, truncated: true) }
        let m = try await ready(l)
        m.regenerate(from: line(m, "two").id)
        XCTAssertNil(m.rewindConfirm)
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertEqual(l.rewinds, [.init(text: "second", rowId: 12, confirmDeep: false, rebind: [10, 11, 12, 13])])
        XCTAssertEqual(m.lines.map(\.text), ["first", "one", "second"], "cut back to the rerun prompt")
        XCTAssertTrue(m.busy)
        try await waitUntil { m.lines[2].rowId == 22 }
        XCTAssertEqual(m.lines.map(\.rowId), [20, 21, 22], "survivors rebound to their new rows")
        XCTAssertFalse(l.calls.contains { $0.hasPrefix("send:") }, "a rewind is one truncating submit, not a send")
    }

    func testOlderRegenerateAsksAndThenCutsDeep() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.regenerate(from: line(m, "one").id)
        let c = try XCTUnwrap(m.rewindConfirm)
        XCTAssertEqual(c.title, RewindConfirm.restoreTitle)
        XCTAssertTrue(c.message.contains("1 later message"))
        XCTAssertTrue(l.rewinds.isEmpty, "nothing is sent before the user agrees")
        m.confirmRewind()
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertEqual(l.rewinds.first, .init(text: "first", rowId: 10, confirmDeep: true, rebind: [10, 11, 12, 13]))
        XCTAssertEqual(m.lines.map(\.text), ["first"])
    }

    func testCancelledConfirmSendsNothing() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.restore(from: line(m, "second").id)
        XCTAssertNotNil(m.rewindConfirm, "restore always asks")
        m.cancelRewind()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(l.rewinds.isEmpty)
        XCTAssertEqual(m.lines.count, 4)
    }

    func testRestoreRerunsTheOriginalPrompt() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.restore(from: line(m, "second").id)
        m.confirmRewind()
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertEqual(l.rewinds.first?.text, "second")
        XCTAssertEqual(l.rewinds.first?.confirmDeep, false, "nothing later to archive")
    }

    func testConfirmIsDroppedWhenTheConversationMoved() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.regenerate(from: line(m, "one").id)
        // A turn from another client lands while the dialog is open.
        m.apply(.delta("remote"))
        m.apply(.completed(ChatCompletion(text: "remote")))
        m.transcript.seed(history: Self.history + [ChatHistoryMessage(role: .user, text: "third", rowId: 14)])
        m.confirmRewind()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(l.rewinds.isEmpty)
        XCTAssertTrue(m.lines.last?.text.contains("nothing was sent") == true)
    }

    // MARK: B3 edit

    func testEditResubmitsTheNewText() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.beginEdit(line(m, "second").id)
        XCTAssertEqual(m.editing?.text, "second")
        XCTAssertFalse(m.commitEdit("second"), "unchanged: nothing to send")
        XCTAssertTrue(m.commitEdit("second, but better"))
        XCTAssertNil(m.editing)
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertEqual(l.rewinds.first?.text, "second, but better")
        XCTAssertEqual(l.rewinds.first?.rowId, 12)
        XCTAssertEqual(m.lines.map(\.text), ["first", "one", "second, but better"])
    }

    func testEditOfAMessageWithAttachmentsSaysTheyAreNotResent() async throws {
        let l = FakeChatLink()
        let m = try await ready(l)
        m.draft = "look"
        m.addURL("https://example.com/x")
        XCTAssertTrue(m.submit())
        try await waitUntil { l.calls.contains { $0.hasPrefix("send:") } }
        m.apply(.completed(ChatCompletion(text: "ok")))
        m.beginEdit(m.lines[0].id)
        XCTAssertEqual(m.editing?.text, "look")
        XCTAssertEqual(m.editing?.hadAttachments, true)
    }

    // MARK: B3 row-id resolution

    func testUnknownRowIdIsResolvedFromSessionHistory() async throws {
        let l = FakeChatLink()
        l.historyResult = [HistoryRow(role: "user", text: "hello", rowId: 77)]
        let m = try await ready(l)
        m.draft = "hello"
        XCTAssertTrue(m.submit())
        try await waitUntil { l.calls.contains("send:hello|") }
        m.apply(.completed(ChatCompletion(text: "hi")))
        m.regenerate(from: m.lines.last!.id)
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertTrue(l.reads.contains("history"))
        XCTAssertEqual(l.rewinds.first?.rowId, 77)
    }

    func testUnresolvableTurnIsResentWithoutCutting() async throws {
        let l = FakeChatLink()
        let m = try await ready(l)
        m.draft = "hello"
        XCTAssertTrue(m.submit())
        try await waitUntil { l.calls.contains("send:hello|") }
        m.apply(.completed(ChatCompletion(text: "hi")))
        m.regenerate(from: m.lines.last!.id)
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertNil(l.rewinds.first?.rowId)
        XCTAssertEqual(m.lines.filter { $0.role == .user }.map(\.text), ["hello", "hello"], "appended, not cut")
        try await waitUntil { m.lines.contains { $0.text == ChatModel.plainResendNote } }
    }

    func testSubmitBindsTheTurnsRowId() async throws {
        let l = FakeChatLink()
        l.submitExtra = ["user_row_id": 55]
        let m = try await ready(l)
        m.draft = "hey"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.first?.rowId == 55 }
        XCTAssertEqual(m.lines.first?.prompt, "hey")
    }

    // MARK: B3 failures

    func testRefusedRewindPutsTheTranscriptBack() async throws {
        let l = FakeChatLink(history: Self.history)
        l.rewindResult = { _ in throw GatewayClient.RPCError(code: 4018, message: "stale target", data: nil) }
        let m = try await ready(l)
        m.regenerate(from: line(m, "two").id)
        try await waitUntil { m.lines.last?.text.hasPrefix("Couldn't regenerate") == true }
        XCTAssertEqual(m.lines.dropLast().map(\.text), ["first", "one", "second", "two"])
        XCTAssertFalse(m.busy)
    }

    func testBackendDeepCutRefusalAsksThenForcesTheDeepCut() async throws {
        let l = FakeChatLink(history: Self.history)
        l.rewindResult = { c in
            if !c.confirmDeep { throw GatewayClient.RPCError(code: RewindError.deepCutUnconfirmed, message: "confirm", data: nil) }
            return RewindReceipt(status: "streaming", truncated: true)
        }
        let m = try await ready(l)
        m.regenerate(from: line(m, "two").id)
        try await waitUntil { m.rewindConfirm != nil }
        XCTAssertEqual(m.rewindConfirm?.forced, true)
        XCTAssertEqual(m.lines.count, 4, "transcript restored while asking")
        m.confirmRewind()
        try await waitUntil { l.rewinds.count == 2 }
        XCTAssertEqual(l.rewinds.last?.confirmDeep, true)
    }

    func testNoRewindWhileAReplyRuns() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.apply(.delta("streaming"))
        XCTAssertFalse(m.canRewind)
        m.performRewind(RewindPlanner.plan(.regenerate, from: line(m, "one").id, in: m.lines)!, display: nil, confirmDeep: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(l.rewinds.isEmpty)
        XCTAssertTrue(BotChatActions.reply(line(m, "two"), chat: m).allSatisfy { !$0.enabled })
    }

    // MARK: B4 branch

    func testBranchOpensASideChatFromTheMessage() async throws {
        let l = FakeChatLink(history: Self.history)
        l.historyResult = Self.history.map { HistoryRow(role: $0.role.rawValue, text: $0.text, rowId: $0.rowId) }
        let m = try await ready(l)
        m.branchFrom(line(m, "one").id)
        try await waitUntil { m.branch?.isReady == true }
        XCTAssertEqual(l.branches.map(\.count), [2])
        XCTAssertTrue(l.branches[0].key.hasPrefix("branch-"))
        let b = try XCTUnwrap(m.branch)
        XCTAssertTrue(b.isBranch)
        XCTAssertEqual(b.branchTitle, "Branch")
        XCTAssertEqual(b.lines.map(\.text), ["first", "one"])
        XCTAssertEqual(m.lines.count, 4, "the Bot Chat is untouched")
        XCTAssertTrue(BotChatActions.user(b.lines[0], chat: b).allSatisfy { $0.title != "Branch into New Chat" }, "no nested branches")
        m.closeBranch()
        XCTAssertNil(m.branch)
        XCTAssertFalse(l.calls.contains { $0.hasPrefix("rewind") || $0.hasPrefix("send") })
    }

    func testBranchNeedsAnIdleChat() async throws {
        let l = FakeChatLink(history: Self.history)
        let m = try await ready(l)
        m.apply(.delta("busy"))
        m.branchFrom(line(m, "one").id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(l.branches.isEmpty)
        XCTAssertTrue(m.lines.contains { $0.text == "Stop the current reply before branching." })
    }

    func testClosingTheChatClosesItsBranch() async throws {
        let l = FakeChatLink(history: Self.history)
        let branchLink = FakeChatLink(history: Array(Self.history.prefix(2)))
        l.branchResult = { _, _ in branchLink }
        let m = try await ready(l)
        m.branchFrom(line(m, "one").id)
        try await waitUntil { m.branch?.isReady == true }
        m.close()
        XCTAssertTrue(branchLink.detached)
    }

    // MARK: B10 error cards

    func testErrorCardActions() async throws {
        let l = FakeChatLink(history: Array(Self.history.prefix(2)))
        l.submitExtra = ["user_row_id": 30]
        let m = try await ready(l)
        m.draft = "q"
        XCTAssertTrue(m.submit())
        try await waitUntil { l.calls.contains("send:q|") }
        m.apply(.completed(ChatCompletion(text: "", status: "error", error: "402 payment required",
                                          errorSurface: ErrorSurface(layer: "billing", code: "billing", retryable: true))))
        let err = try XCTUnwrap(m.lines.last)
        XCTAssertEqual(err.role, .error)
        XCTAssertEqual(m.recovery(for: err), ErrorRecoveryPlan(retry: true, switchProvider: true))
        XCTAssertTrue(m.diagnostics(err.failure!).contains("code: billing"))
        m.switchProvider()
        XCTAssertTrue(m.modelPickerShown)
        m.retry(errorLine: err.id)
        try await waitUntil { !l.rewinds.isEmpty }
        XCTAssertEqual(l.rewinds.first?.text, "q", "Retry reruns the failed prompt")
        XCTAssertFalse(m.lines.contains { $0.role == .error }, "the failed turn was cut back")
    }

    func testDismissAndNoRetryForASendFailure() async throws {
        let l = FakeChatLink()
        l.sendError = GatewayClient.RPCError(code: 5000, message: "boom", data: nil)
        let m = try await ready(l)
        m.draft = "q"
        XCTAssertTrue(m.submit())
        try await waitUntil { m.lines.last?.role == .error }
        let err = m.lines.last!
        XCTAssertEqual(m.recovery(for: err)?.retry, false, "the draft came back; nothing to rerun")
        m.dismissError(err.id)
        XCTAssertFalse(m.lines.contains { $0.role == .error })
    }

    // MARK: B11 URL, folder, long paste

    func testURLAndFolderRefsRideInThePrompt() async throws {
        let l = FakeChatLink()
        let m = try await ready(l)
        XCTAssertFalse(m.addURL("not a url"))
        XCTAssertTrue(m.addURL("https://example.com/doc"))
        XCTAssertTrue(m.addURL("https://example.com/doc"))
        XCTAssertEqual(m.pending.count, 1, "the same URL is attached once")
        m.addFolders([URL(fileURLWithPath: "/tmp/My Folder", isDirectory: true)])
        XCTAssertEqual(m.pending.map(\.name), ["example.com", "My Folder"])
        XCTAssertEqual(m.pending.map(\.symbol), ["link", "folder"])
        m.draft = "summarise"
        XCTAssertTrue(m.submit())
        try await waitUntil { !m.pending.contains { $0.isSending } && l.calls.contains { $0.hasPrefix("send:") } }
        XCTAssertEqual(l.calls.last { $0.hasPrefix("send:") },
                       "send:@url:https://example.com/doc\n@folder:`/tmp/My Folder`\n\nsummarise|", "no files staged")
        XCTAssertEqual(m.lines.first?.text, "summarise\n\nAttached: example.com, My Folder")
    }

    func testDroppedFoldersBecomeFolderRefs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = FakeChatLink()
        let m = try await ready(l)
        m.checkFile = { ChatAttachments.Checked(url: $0, name: $0.lastPathComponent, kind: .file, bytes: 1) }
        m.addDropped([dir, URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertEqual(m.pending.compactMap(\.contextRef?.kind), [.folder])
        XCTAssertEqual(m.pending.filter { $0.contextRef == nil }.map(\.name), ["a.txt"])
    }

    func testLongPasteBecomesATextAttachment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hba-paste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let l = FakeChatLink()
        let m = try await ready(l)
        m.pasteFolder = folder
        XCTAssertFalse(m.attachLongPaste(String(repeating: "a", count: 3_000)), "short pastes stay in the field")
        XCTAssertTrue(m.pending.isEmpty)
        let long = String(repeating: "b", count: 3_001)
        XCTAssertTrue(m.attachLongPaste(long))
        let chip = try XCTUnwrap(m.pending.first)
        XCTAssertTrue(chip.name.hasPrefix("Pasted content ("))
        XCTAssertTrue(LargePaste.isPastedContent(chip.url.lastPathComponent))
        XCTAssertEqual(try String(contentsOf: chip.url, encoding: .utf8), long)
        XCTAssertTrue(PasteboardAttachments.isPasted(chip.url, folder: folder), "deleted with the turn like pasted images")
        m.removeAttachment(chip.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chip.url.path))
    }

    func testImageZoomState() {
        var z = ImageZoomState()
        z.pan(by: CGSize(width: 10, height: 10))
        XCTAssertEqual(z.offset, .zero, "no pan at 1×")
        z.step(1)
        XCTAssertEqual(z.scale, 1.5)
        z.pan(by: CGSize(width: 10, height: 5))
        XCTAssertEqual(z.offset, CGSize(width: 10, height: 5))
        for _ in 0..<10 { z.step(1) }
        XCTAssertEqual(z.scale, ImageZoomState.maxScale)
        for _ in 0..<10 { z.step(-1) }
        XCTAssertEqual(z.scale, 1)
        XCTAssertEqual(z.offset, .zero)
        z.step(1); z.reset()
        XCTAssertEqual(z, ImageZoomState())
    }

    // MARK: B14 approval mode

    func testApprovalModeLoadsAndChanges() async throws {
        let l = FakeChatLink()
        l.approval = .smart
        let m = try await ready(l)
        try await waitUntil { m.approvalMode == .smart }
        m.selectApprovalMode(.off)
        XCTAssertEqual(m.approvalMode, .off, "painted at once")
        try await waitUntil { l.calls.contains("approval:off") }
        m.apply(.info(SessionInfoSnapshot(model: "m1", provider: "anthropic", approvalMode: .manual)))
        XCTAssertEqual(m.approvalMode, .manual, "session.info reconciles it")
    }

    func testRefusedApprovalModeRollsBack() async throws {
        let l = FakeChatLink()
        l.approval = .manual
        l.approvalSetError = GatewayClient.RPCError(code: 4002, message: "nope", data: nil)
        let m = try await ready(l)
        try await waitUntil { m.approvalMode == .manual }
        m.selectApprovalMode(.off)
        try await waitUntil { m.approvalMode == .manual && m.lines.contains { $0.text.hasPrefix("Couldn't change the approval mode") } }
    }

    // MARK: B16 card helpers

    func testChangedFilesCardCopy() {
        XCTAssertEqual(ChangedFilesCard.title([ChangedFile(path: "/a", added: 1, removed: 0, diffs: [])]), "1 file changed")
        XCTAssertTrue(ChangedFilesCard.canReveal("/repo/a.swift"))
        XCTAssertFalse(ChangedFilesCard.canReveal("src/a.swift"), "relative to an unknown working folder")
        let text = DiffText.attributed((0..<405).map { "+\($0)" }.joined(separator: "\n"))
        XCTAssertTrue(String(text.characters).hasSuffix("… 5 more lines"))
    }
}
