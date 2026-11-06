import CoreGraphics
import Foundation
import XCTest
@testable import HermesGatewayKit

/// Attachments: client-side checks (regular file, symlinks resolved, caps), prompt text ordering, and the
/// attach RPC sequence before `prompt.submit`.
final class ChatAttachmentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, bytes: Int = 4) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: min(bytes, 4)))
        if bytes > 4 {
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(bytes))  // sparse: cheap even for 50 MB
            try h.close()
        }
        return url
    }

    private func pdf(_ name: String, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        return url
    }

    // MARK: - prompt text

    func testPromptTextPutsRefLinesFirst() {
        XCTAssertEqual(ChatAttachments.promptText(refTexts: ["@file:a.txt", " @file:b.md "], userText: "  summarize  ", hasImages: false),
                       "@file:a.txt\n@file:b.md\n\nsummarize")
        XCTAssertEqual(ChatAttachments.promptText(refTexts: ["@file:a.txt"], userText: "", hasImages: true), "@file:a.txt")
        XCTAssertEqual(ChatAttachments.promptText(refTexts: [], userText: "", hasImages: true), ChatAttachments.imageOnlyCaption)
        XCTAssertEqual(ChatAttachments.promptText(refTexts: [], userText: "", hasImages: false), "")
        XCTAssertEqual(ChatAttachments.promptText(refTexts: [], userText: "hi", hasImages: true), "hi")
    }

    // MARK: - checks

    func testChecks() throws {
        let png = try file("shot.PNG")
        XCTAssertEqual(try ChatAttachments.check(png).kind, .image)
        XCTAssertEqual(try ChatAttachments.check(try file("notes.txt")).kind, .file)
        XCTAssertThrowsError(try ChatAttachments.check(dir.appendingPathComponent("missing.png"))) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .notFound("missing.png"))
        }
        XCTAssertThrowsError(try ChatAttachments.check(dir)) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .notRegularFile(dir.lastPathComponent))
        }
        XCTAssertNoThrow(try ChatAttachments.check(try file("max.jpg", bytes: ChatAttachments.maxImageBytes)))
        XCTAssertThrowsError(try ChatAttachments.check(try file("big.jpg", bytes: ChatAttachments.maxImageBytes + 1))) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .tooLarge("big.jpg", limitMB: 25))
            XCTAssertEqual(Redaction.describe($0), "big.jpg is too large; the limit is 25 MB.")
        }
        XCTAssertThrowsError(try ChatAttachments.check(try file("huge.pdf", bytes: ChatAttachments.maxPDFBytes + 1))) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .tooLarge("huge.pdf", limitMB: 50))
        }
        XCTAssertThrowsError(try ChatAttachments.check(try file("fake.pdf"))) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .unreadablePDF("fake.pdf"))
        }
        XCTAssertEqual(try ChatAttachments.check(try pdf("ok.pdf", pages: 25)).kind, .pdf)
        XCTAssertThrowsError(try ChatAttachments.check(try pdf("long.pdf", pages: 26))) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .tooManyPages("long.pdf", pages: 26, limit: 25))
        }
    }

    func testSymlinkIsResolvedAndCheckedAsItsTarget() throws {
        let target = try file("real.png")
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let c = try ChatAttachments.check(link)
        XCTAssertEqual(c.url.path, target.resolvingSymlinksInPath().path)
        XCTAssertEqual(c.name, "link.png")
        let dirLink = dir.appendingPathComponent("dirlink.png")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try ChatAttachments.check(dirLink))
    }

    // MARK: - over the wire

    func testAttachThenSendOrdersRefsBeforeText() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, p in
            switch m {
            case "image.attach": return ["attached": true, "path": p["path"] ?? .null, "name": "shot.png", "count": 1]
            case "file.attach": return ["attached": true, "name": "notes.txt", "path": "/ws/attachments/notes.txt",
                                        "ref_path": "attachments/notes.txt", "ref_text": "@file:attachments/notes.txt"]
            case "image.detach": return ["detached": true, "count": 0]
            case "prompt.submit": return ["status": "streaming"]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        let img = try await s.attach(try file("shot.png"))
        let txt = try await s.attach(try file("notes.txt"))
        XCTAssertEqual(img.kind, .image)
        XCTAssertNil(img.refText)
        XCTAssertEqual(txt.refText, "@file:attachments/notes.txt")
        try await s.send("what is in these?", attachments: [img, txt])
        XCTAssertEqual(Array(Parity.methods(gw).dropFirst(2)), ["image.attach", "file.attach", "prompt.submit"])
        XCTAssertEqual(gw.received.first { $0["method"] == "file.attach" }?["params"]?["name"], "notes.txt")
        XCTAssertEqual(gw.received.first { $0["method"] == "image.attach" }?["params"]?["session_id"], "rt-1")
        XCTAssertEqual(gw.received.last?["params"], ["session_id": "rt-1",
                                                     "text": "@file:attachments/notes.txt\n\nwhat is in these?"])
        let remaining = try await s.detachStaged(img)
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(gw.received.last?["params"], ["session_id": "rt-1", "path": .string(img.path)])
    }

    func testOversizedFileNeverReachesTheWire() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        do { _ = try await s.attach(try file("big.png", bytes: ChatAttachments.maxImageBytes + 1)); XCTFail("attached") }
        catch ChatAttachments.Failure.tooLarge {}
        XCTAssertFalse(Parity.methods(gw).contains("image.attach"))
    }
}
