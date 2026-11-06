import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K3 "message the running worker" / "Requeue with note" and K2 attachments, against `FakeKanbanService` and
/// a temporary folder (never the user's caches, never NSWorkspace: `openFile` is replaced). Headless.
@MainActor
final class KanbanCardActionsTests: XCTestCase {
    private var temp: URL!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("hba-kanban-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func fake() -> FakeKanbanService {
        FakeKanbanService(columns: [
            ("todo", [FakeKanbanService.task("t_1", "Write the spec", status: "todo")]),
            ("ready", []),
            ("running", [FakeKanbanService.task("t_r", "Busy one", status: "running", assignee: "alice")]),
            ("blocked", [FakeKanbanService.task("t_b", "Stuck one", status: "blocked", assignee: "bob")]),
            ("done", []),
        ])
    }

    /// A loaded model with `id` open and its details in.
    private func opened(_ api: FakeKanbanService, _ id: String) async -> KanbanBoardModel {
        let m = KanbanBoardModel(slug: "main", api: api, sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
        m.attachmentRoot = temp.appendingPathComponent("downloads", isDirectory: true)
        m.openFile = { _, _ in XCTFail("openFile not expected") }
        await m.refresh()
        m.select(id)
        // `select` loads the details in a task of its own; wait for whichever load lands last.
        let end = Date().addingTimeInterval(5)
        while m.detail?.task.id != id, Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        await m.loadDetail()
        XCTAssertEqual(m.detail?.task.id, id)
        return m
    }

    // MARK: - message vs comment

    func testComposerAddressesTheWorkerOnlyOnARunningCard() async {
        let running = KanbanComposerCopy(running: true)
        XCTAssertEqual(running.placeholder, "Message the running worker…")
        XCTAssertEqual(running.send, "Send")
        XCTAssertNotNil(running.hint)
        XCTAssertTrue(running.hint?.contains("current turn within a few seconds") ?? false)
        XCTAssertTrue(running.showsRequeue)
        let idle = KanbanComposerCopy(running: false)
        XCTAssertEqual(idle.placeholder, "Add a comment…")
        XCTAssertEqual(idle.send, "Comment")
        XCTAssertNil(idle.hint)
        XCTAssertFalse(idle.showsRequeue, "Desktop offers Requeue with note on running cards only")

        let api = fake()
        let m = await opened(api, "t_r")
        XCTAssertTrue(m.selectedIsRunning)
        for id in ["t_1", "t_b"] {
            m.select(id)
            XCTAssertFalse(m.selectedIsRunning, id)
        }
    }

    func testMessagingTheRunningWorkerIsAPlainComment() async {
        let api = fake()
        let m = await opened(api, "t_r")
        let ok = await m.addComment("Use the other API")
        XCTAssertTrue(ok)
        XCTAssertEqual(api.count("comment"), 1)
        XCTAssertEqual(api.count("reclaim"), 0, "the server delivers it to the live turn; nothing else is sent")
        XCTAssertEqual(m.detail?.comments.map(\.body), ["Use the other API"])
    }

    func testCommentDraftsArePerCardAndALateSendClearsOnlyItsOwn() async {
        let api = fake()
        let m = await opened(api, "t_1")
        m.commentDraft = "For the spec"
        m.select("t_b")
        XCTAssertEqual(m.commentDraft, "", "a draft never shows on another card")
        m.commentDraft = "Unblock me"
        m.select("t_1")
        XCTAssertEqual(m.commentDraft, "For the spec", "each card keeps its own draft")

        api.with { $0.holdNextComment = true }
        let sending = Task { await m.addComment(m.commentDraft) }
        let deadline = Date().addingTimeInterval(5)
        while !api.isParked, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(api.isParked)
        m.select("t_b")  // another card opened while the send is in flight
        m.commentDraft = "Unblock me, please"
        api.release()
        let ok = await sending.value
        XCTAssertTrue(ok)
        XCTAssertEqual(m.commentDraft, "Unblock me, please", "the late send left the open card's draft alone")
        XCTAssertNil(m.commentDrafts["t_1"], "the sent card's draft was cleared")
        XCTAssertEqual(api.with { $0.comments["t_1"]?.count }, 1, "posted to the card it was written on")
    }

    func testAFailedSendKeepsTheDraft() async {
        let api = fake()
        let m = await opened(api, "t_1")
        m.commentDraft = "Keep me"
        api.with { $0.commentError = PluginREST.Failure.http(status: 500, detail: "x") }
        let ok = await m.addComment(m.commentDraft)
        XCTAssertFalse(ok)
        XCTAssertEqual(m.commentDraft, "Keep me")
    }

    // MARK: - requeue with note

    func testRequeuePostsTheNoteThenReclaims() async throws {
        let api = fake()
        let m = await opened(api, "t_r")
        m.commentDraft = "  Start over with plan B  "
        let posted = await m.requeueWithNote(m.commentDraft)
        XCTAssertTrue(posted)
        XCTAssertEqual(m.commentDraft, "", "the posted note's draft goes")
        XCTAssertEqual(api.calls.filter { $0 == "comment" || $0 == "reclaim" }, ["comment", "reclaim"], "comment first, then reclaim")
        XCTAssertEqual(m.detail?.comments.map(\.body), ["Start over with plan B"])
        XCTAssertEqual(m.inspectorNote, KanbanBoardModel.requeuedNote)
        XCTAssertNil(m.error)
        XCTAssertEqual(m.detail?.task.status, "ready", "details reloaded after the reclaim")
        let blank = await m.requeueWithNote("   ")
        XCTAssertFalse(blank)
        XCTAssertEqual(api.count("reclaim"), 1, "a blank note sends nothing")
    }

    func testRequeueDoesNotReclaimWhenTheNoteFails() async {
        let api = fake()
        let m = await opened(api, "t_r")
        api.with { $0.commentError = PluginREST.Failure.http(status: 500, detail: "db locked") }
        let posted = await m.requeueWithNote("Start over")
        XCTAssertFalse(posted, "the draft stays")
        XCTAssertEqual(api.count("reclaim"), 0)
        XCTAssertEqual(m.error, "Requeue with note failed: db locked")
        XCTAssertNil(m.inspectorNote)
    }

    func testRequeueReclaimFailureKeepsThePostedNoteAndSaysSo() async {
        let api = fake()
        let m = await opened(api, "t_r")
        let secret = "hbaSecret_" + UUID().uuidString
        api.with { $0.reclaimError = PluginREST.Failure.transport("connection reset for http://127.0.0.1:9/api/ws?token=\(secret)") }
        let posted = await m.requeueWithNote("Start over")
        XCTAssertTrue(posted, "the note went out, so the draft is cleared")
        XCTAssertEqual(api.calls.filter { $0 == "comment" || $0 == "reclaim" }, ["comment", "reclaim"])
        XCTAssertTrue(m.error?.hasPrefix("The note was posted, but the requeue failed:") ?? false, m.error ?? "")
        XCTAssertFalse(m.error?.contains(secret) ?? true, "errors are redacted")
        XCTAssertNil(m.inspectorNote)
    }

    // MARK: - attachments

    func testDetailsBringTheAttachmentsAndUploadAddsFilesUnderTheLimit() async throws {
        let api = fake()
        api.with { $0.attachments["t_1"] = [FakeKanbanService.attachment(5, task: "t_1", name: "brief.pdf", size: 4096)] }
        let m = await opened(api, "t_1")
        XCTAssertEqual(m.attachments.map(\.filename), ["brief.pdf"])

        let small = temp.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: small)
        let big = temp.appendingPathComponent("huge.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(KanbanAPI.maxAttachmentBytes + 1))  // sparse: nothing is written
        try handle.close()
        let folder = temp.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await m.upload([small, big, folder])
        let uploads = api.with { $0.uploads }
        XCTAssertEqual(uploads.map(\.name), ["notes.txt"], "the oversized file and the folder are refused before sending")
        XCTAssertEqual(uploads.first?.contentType, "text/plain")
        XCTAssertEqual(uploads.first?.bytes, 5)
        XCTAssertEqual(api.count("upload"), 1)
        XCTAssertEqual(m.attachments.map(\.filename), ["brief.pdf", "notes.txt"], "list reloaded from GET /attachments")
        XCTAssertEqual(m.uploading, 0)
        let error = try XCTUnwrap(m.attachmentError)
        XCTAssertTrue(error.contains("huge.bin is larger than 25 MB"), error)
        XCTAssertTrue(error.contains("a folder is a folder"), error)
    }

    func testUploadFailureIsShownInPlainWords() async throws {
        let api = fake()
        let m = await opened(api, "t_1")
        api.with { $0.uploadError = PluginREST.Failure.http(status: 413, detail: "attachment exceeds 25 MB limit") }
        let file = temp.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        await m.upload([file])
        XCTAssertEqual(m.attachmentError, "Upload failed: a.txt: attachment exceeds 25 MB limit")
    }

    func testOpenSavesASanitizedCopyAndHandsTheCheckedActionOn() async throws {
        let api = fake()
        let m = await opened(api, "t_1")
        var opened: [(URL, KanbanAttachmentFiles.Action)] = []
        m.openFile = { opened.append(($0, $1)) }
        let root = m.attachmentRoot.standardizedFileURL.resolvingSymlinksInPath().path

        for (name, expected) in [("../../escape.txt", "escape.txt"), ("", "attachment-9"), ("run.command", "run.command")] {
            await m.open(KanbanAttachment(json: FakeKanbanService.attachment(9, task: "t_1", name: name))!)
            let (url, _) = try XCTUnwrap(opened.last)
            XCTAssertEqual(url.lastPathComponent, expected)
            XCTAssertTrue(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/"), "stays under the download folder")
            XCTAssertEqual(try Data(contentsOf: url), Data("placeholder bytes".utf8))
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o600, "never executable")
        }
        XCTAssertEqual(opened.map(\.1), [.open, .reveal, .reveal], "text opens; no extension and scripts are only revealed")
        XCTAssertEqual(api.count("download"), 3)
        XCTAssertNil(m.attachmentError)
        XCTAssertTrue(m.opening.isEmpty)
    }

    func testOpenFailureIsShownAndNothingIsOpened() async {
        let api = fake()
        let m = await opened(api, "t_1")
        api.with { $0.downloadError = PluginREST.Failure.http(status: 404, detail: "attachment file missing on disk") }
        await m.open(KanbanAttachment(json: FakeKanbanService.attachment(4, task: "t_1", name: "gone.pdf"))!)
        XCTAssertEqual(m.attachmentError, "“gone.pdf” could not be downloaded: attachment file missing on disk")
    }

    func testDeleteCallsTheRouteAndReloadsTheList() async {
        let api = fake()
        api.with { $0.attachments["t_1"] = [FakeKanbanService.attachment(5, task: "t_1", name: "a.pdf"),
                                            FakeKanbanService.attachment(6, task: "t_1", name: "b.pdf")] }
        let m = await opened(api, "t_1")
        let ok = await m.delete(m.attachments[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(api.count("delete"), 1)
        XCTAssertEqual(m.attachments.map(\.id), [6])
        api.with { $0.deleteError = PluginREST.Failure.http(status: 404, detail: "attachment not found") }
        let failed = await m.delete(m.attachments[0])
        XCTAssertFalse(failed)
        XCTAssertEqual(m.attachmentError, "Delete “b.pdf” failed: attachment not found")
        XCTAssertEqual(m.attachments.map(\.id), [6], "kept when the server refused")
    }

    func testSelectingAnotherCardClearsAttachmentState() async {
        let api = fake()
        api.with { $0.attachments["t_1"] = [FakeKanbanService.attachment(5, task: "t_1", name: "a.pdf")] }
        let m = await opened(api, "t_1")
        XCTAssertEqual(m.attachments.count, 1)
        m.select("t_b")
        XCTAssertTrue(m.attachments.isEmpty)
        XCTAssertNil(m.attachmentError)
        XCTAssertNil(m.inspectorNote)
    }

    // MARK: - local file rules

    func testDownloadNamesCannotLeaveTheFolderOrHideTheirType() {
        let cases: [(String, String)] = [
            ("../x", "x"), ("../../etc/passwd", "passwd"), ("..\\..\\win.ini", "win.ini"), ("/", "attachment-3"),
            ("", "attachment-3"), (".", "attachment-3"), ("..", "attachment-3"), ("   ", "attachment-3"),
            (".hidden", "hidden"), ("...env", "env"), ("a:b.txt", "a_b.txt"), ("bad\u{0}name\n.txt", "badname.txt"),
            ("report\u{202E}fdp.exe", "reportfdp.exe"), ("  spaced.pdf  ", "spaced.pdf"), ("résumé.pdf", "résumé.pdf"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(KanbanAttachmentFiles.safeName(raw, id: 3), expected, raw.debugDescription)
        }
        let long = KanbanAttachmentFiles.safeName(String(repeating: "a", count: 300) + ".pdf", id: 1)
        XCTAssertEqual(long.count, KanbanAttachmentFiles.maxNameLength)
        XCTAssertTrue(long.hasSuffix(".pdf"), "the type survives the cap")
    }

    func testOnlyPassiveDocumentsOpenEverythingElseIsRevealed() throws {
        func action(_ name: String) throws -> KanbanAttachmentFiles.Action {
            let url = try KanbanAttachmentFiles.save(Data("x".utf8), filename: name, id: 1, root: temp)
            return KanbanAttachmentFiles.action(for: url)
        }
        for name in ["a.txt", "a.pdf", "a.png", "a.md", "a.csv"] {
            XCTAssertEqual(try action(name), .open, name)
        }
        for name in ["a.command", "a.sh", "a.app", "a.py", "a.scpt", "a.pkg", "a.dmg", "a.jar", "a.html", "a.svg", "a.zip",
                     "a.webloc", "a.terminal", "a.workflow", "noextension", "a.unknownext", "server.pem", "id_rsa"] {
            XCTAssertEqual(try action(name), .reveal, name)
        }
    }

    func testSaveUsesAFreshPrivateFolderAndPrunesOldDownloads() throws {
        let root = temp.appendingPathComponent("dl", isDirectory: true)
        let first = try KanbanAttachmentFiles.save(Data("1".utf8), filename: "same.txt", id: 1, root: root)
        let second = try KanbanAttachmentFiles.save(Data("2".utf8), filename: "same.txt", id: 1, root: root)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent(), "two downloads never collide")
        let perms = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700)
        _ = try KanbanAttachmentFiles.save(Data("3".utf8), filename: "later.txt", id: 2, root: root,
                                           now: Date().addingTimeInterval(KanbanAttachmentFiles.keepDownloads + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "downloads older than a day are removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
}
