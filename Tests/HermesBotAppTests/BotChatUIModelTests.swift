import AppKit
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// View models behind the Bot Chat UI: slash menu keyboard model, clarify answers, approval buttons,
/// tool rows, attachment chips and pasteboard files. Headless (a private pasteboard, temp files only).
final class BotChatUIModelTests: XCTestCase {
    private let catalog = SlashCatalog(result: ["pairs": [["/model", "Switch model"], ["/goal", "Set a goal"],
                                                          ["/memory", "Memory"], ["/compress", "Compact"]]])

    // MARK: slash menu

    func testMenuOpensOnlyForABareCommandWord() {
        XCTAssertEqual(SlashMenuState.query("/"), "")
        XCTAssertEqual(SlashMenuState.query("/mo"), "mo")
        XCTAssertNil(SlashMenuState.query("/model gpt"), "closed once arguments start")
        XCTAssertNil(SlashMenuState.query("hi /model"))
        XCTAssertNil(SlashMenuState.query("//x"))
        let menu = SlashMenuState()
        XCTAssertFalse(menu.isOpen("/", catalog: nil), "no catalog yet")
        XCTAssertTrue(menu.isOpen("/", catalog: catalog))
        XCTAssertEqual(SlashMenuState.items("/m", catalog: catalog).map(\.name), ["/model", "/memory", "/compress"],
                       "prefix matches first, then substring matches")
        XCTAssertFalse(menu.isOpen("/zzz", catalog: catalog))
    }

    func testKeyboardMoveWrapsAndAcceptReplacesTheDraft() {
        var menu = SlashMenuState()
        let count = SlashMenuState.items("/", catalog: catalog).count
        XCTAssertEqual(menu.highlighted("/", catalog: catalog)?.name, "/model")
        menu.move(-1, count: count)
        XCTAssertEqual(menu.highlighted("/", catalog: catalog)?.name, "/compress", "up from the top wraps")
        menu.move(1, count: count)
        menu.move(1, count: count)
        XCTAssertEqual(menu.accept("/", catalog: catalog), "/goal ")
        menu.draftChanged("/g")
        XCTAssertEqual(menu.selection, 0, "typing resets the highlight")
    }

    func testEscClosesForThisDraftOnlyAndReturnAcceptsUnlessExact() {
        var menu = SlashMenuState()
        menu.dismiss("/mo")
        XCTAssertFalse(menu.isOpen("/mo", catalog: catalog))
        menu.draftChanged("/mod")
        XCTAssertTrue(menu.isOpen("/mod", catalog: catalog))
        XCTAssertTrue(menu.returnAccepts("/mod", catalog: catalog))
        XCTAssertFalse(menu.returnAccepts("/model", catalog: catalog), "an exact name is sent as typed")
    }

    // MARK: clarify

    private func clarify(_ questions: JSONValue, answers: JSONValue? = nil) -> ClarifyPrompt {
        var p: [String: JSONValue] = ["session_id": "rt", "questions": questions]
        if let answers { p["answers"] = answers }
        guard case .clarify(let c) = ServerRequest(wireId: "srq", method: "clarify", params: .object(p)).kind else {
            fatalError("not a clarify")
        }
        return c
    }

    func testClarifySingleMultiTextAndSkip() {
        let p = clarify([["qid": "env", "question": "Where?", "choices": ["prod", "staging"]],
                         ["qid": "tags", "question": "Tags?", "choices": ["a", "b/c"], "multi_select": true],
                         ["qid": "why", "question": "Why?"]])
        var d = ClarifyDraft(p)
        XCTAssertFalse(d.canSubmit(p))
        d.toggle("prod", in: p.questions[0])
        d.toggle("staging", in: p.questions[0])
        d.toggle("a", in: p.questions[1])
        d.toggle("b/c", in: p.questions[1])
        d.setText("extra", for: p.questions[1])
        d.setText("because", for: p.questions[2])
        d.skip(p.questions[2])
        XCTAssertTrue(d.canSubmit(p))
        let answers = d.answers(p)
        XCTAssertEqual(answers["env"], .some("staging"), "single select keeps one choice")
        XCTAssertEqual(answers["tags"], .some(#"["a","b/c","extra"]"#), "multi select: JSON array, typed text added")
        XCTAssertEqual(answers["why"], .some(nil), "skipped → null")
        XCTAssertEqual(ServerRequestAnswer.clarify(answers).result["answers"]?["why"], .null)
    }

    func testClarifyReplayPrefillsLockedAnswers() {
        let p = clarify([["qid": "env", "question": "Where?", "choices": ["prod"]], ["qid": "why", "question": "Why?"],
                         ["qid": "skip", "question": "?"]],
                        answers: ["env": "prod", "why": "typed", "skip": nil])
        let d = ClarifyDraft(p)
        XCTAssertEqual(d.entry("env").picked, ["prod"])
        XCTAssertEqual(d.entry("why").text, "typed")
        XCTAssertTrue(d.entry("skip").skipped)
    }

    func testApprovalButtonsOrderAndWeight() {
        XCTAssertEqual(ApprovalButtons.ordered([.deny, .always, .once]), [.once, .always, .deny])
        XCTAssertEqual(ApprovalButtons.kind(.once), .primary)
        XCTAssertEqual(ApprovalButtons.kind(.deny), .danger)
        XCTAssertEqual(ApprovalButtons.title(.session), "This session")
    }

    // MARK: tool rows

    func testToolRowPresentation() {
        var line = ChatLine(role: .tool, text: "  ls -la  ", tool: ToolLine(toolId: "t", name: "terminal", state: .running))
        var p = ToolRowPresentation(line)
        XCTAssertNil(p.symbol, "running shows a spinner")
        XCTAssertEqual(p.title, "Ran ls -la", "a terminal call without args is titled from its preview")
        XCTAssertNil(p.context)
        XCTAssertFalse(p.expandable)
        XCTAssertEqual(p.accessibilityLabel, "Ran ls -la, running")
        line.tool = ToolLine(toolId: "t", name: "terminal", state: .failed, duration: 125, summary: "exit 1")
        p = ToolRowPresentation(line)
        XCTAssertEqual(p.symbol, "xmark.circle.fill")
        XCTAssertEqual(p.duration, "2m 05s")
        XCTAssertTrue(p.expandable)
        XCTAssertEqual(ToolRowPresentation.format(0.42), "0.4s")
        XCTAssertEqual(ToolRowPresentation.format(12.4), "12s")
        XCTAssertEqual(ChatComposer.busyText(bot: "Fake", drafting: "terminal"), "Fake is drafting terminal")
        XCTAssertEqual(ChatComposer.busyText(bot: "Fake", drafting: nil), "Fake is replying")
    }

    // MARK: attachments

    func testAttachmentChipStates() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        var chip = PendingAttachment(url: url) { u in
            ChatAttachments.Checked(url: u, name: "report.pdf", kind: .pdf, bytes: 10, pages: 3)
        }
        XCTAssertTrue(chip.isReady, "chips are local: ready at once, no upload spinner")
        XCTAssertEqual(chip.symbol, "doc.richtext")
        XCTAssertEqual(chip.detail, "3 pages")
        XCTAssertEqual(chip.accessibilityLabel, "File report.pdf, ready to send")
        chip.state = .sending
        XCTAssertEqual(chip.detail, "Sending…")
        let refused = PendingAttachment(url: url) { _ in
            throw ChatAttachments.Failure.tooManyPages("report.pdf", pages: 30, limit: 25)
        }
        XCTAssertTrue(refused.isFailed)
        XCTAssertNil(refused.checked)
        XCTAssertEqual(refused.error, "report.pdf has 30 pages; at most 25 pages can be attached at once.")
        XCTAssertTrue(refused.accessibilityLabel.contains("could not be attached"))
    }

    func testChipNameShowsHiddenCharacters() {
        let chip = PendingAttachment(url: URL(fileURLWithPath: "/tmp/invoice\u{202E}fdp.exe")) { _ in throw ChatAttachments.Failure.notFound("x") }
        XCTAssertEqual(chip.name, "invoice⟨U+202E⟩fdp.exe")
    }

    func testPasteboardFilesWinAndTextIsLeftAlone() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("hba-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertTrue(PasteboardAttachments.urls(from: pb).isEmpty)

        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hba-paste-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        XCTAssertEqual(PasteboardAttachments.urls(from: pb).map(\.lastPathComponent), [file.lastPathComponent])

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hba-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pb.clearContents()
        pb.writeObjects([image])
        let folder = dir.appendingPathComponent("pasted")
        let pasted = PasteboardAttachments.urls(from: pb, folder: folder)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(pasted.first?.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.first?.path ?? ""))
        let perms = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700, "pasted images live in a private folder")
        XCTAssertTrue(PasteboardAttachments.isPasted(pasted[0], folder: folder))
        XCTAssertFalse(PasteboardAttachments.isPasted(file, folder: folder))
        PasteboardAttachments.delete([file, pasted[0]], folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "only files in the paste folder are deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasted[0].path))
        _ = PasteboardAttachments.write(Data([1]), in: folder)
        PasteboardAttachments.purge(folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "quit removes the folder")
    }

    func testEmptyChatCopyNoLongerSaysDeleted() {
        XCTAssertFalse(BotChatView.sharedChatNote.contains("deleted"))
        XCTAssertTrue(BotChatView.sharedChatNote.contains("kept"))
    }
}
