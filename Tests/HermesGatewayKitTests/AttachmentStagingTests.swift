import CoreGraphics
import Foundation
import XCTest
@testable import HermesGatewayKit

/// `BotChatSession.submit(_:files:)`: attachments are staged only inside the send, in order, and every
/// image or PDF page staged by a send that fails is detached again (nothing rides into a later turn).
final class AttachmentStagingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func checked(_ name: String) throws -> ChatAttachments.Checked {
        let url = dir.appendingPathComponent(name)
        if url.pathExtension == "pdf" {
            var box = CGRect(x: 0, y: 0, width: 72, height: 72)
            let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
            for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.endPDFPage() }
            ctx.closePDF()
        } else {
            try Data("x".utf8).write(to: url)
        }
        return try ChatAttachments.check(url)
    }

    private func open(_ gw: FakeGateway, _ extra: @escaping @Sendable (String, JSONValue) -> JSONValue?) async throws
        -> (Backend, BotChatSession) {
        gw.responder = { m, p in
            if let r = extra(m, p) { return r }
            switch m {
            case "image.attach": return ["attached": true, "path": p["path"] ?? .null, "count": 1]
            case "pdf.attach": return ["attached": true, "filename": "doc.pdf", "pages_attached": 2,
                                       "pages": [["path": "/cache/doc-1.png"], ["path": "/cache/doc-2.png"]]]
            case "file.attach": return ["attached": true, "name": "notes.txt", "ref_text": "@file:notes.txt"]
            case "image.detach": return ["detached": true, "count": 0]
            case "prompt.submit": return ["status": "streaming"]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        return (backend, try await BotChatSession.open(backend, bot: Parity.bot, title: nil))
    }

    private func detached(_ gw: FakeGateway) -> [String] {
        gw.received.filter { $0["method"] == "image.detach" }.compactMap { $0["params"]?["path"]?.string }
    }

    func testStagingHappensInsideTheSendInOrder() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw) { _, _ in nil }
        defer { backend.client.close() }
        let files = [try checked("a.png"), try checked("doc.pdf"), try checked("notes.txt")]
        XCTAssertEqual(files[1].pages, 2)
        try await s.submit("look", files: files)
        XCTAssertEqual(Array(Parity.methods(gw).dropFirst(2)), ["image.attach", "pdf.attach", "file.attach", "prompt.submit"])
        XCTAssertEqual(gw.received.last?["params"]?["text"], "@file:notes.txt\n\nlook")
    }

    func testAFailingFileDetachesTheImageAndEveryPDFPageStagedBeforeIt() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw) { m, _ in
            m == "file.attach" ? ["__error": ["code": 4015, "message": "notes.txt: path required"]] : nil
        }
        defer { backend.client.close() }
        let png = try checked("a.png")
        do {
            try await s.submit("look", files: [png, try checked("doc.pdf"), try checked("notes.txt")])
            XCTFail("sent")
        } catch let e as ChatAttachments.StageFailure {
            XCTAssertEqual(e.index, 2)
            XCTAssertEqual(e.message, "notes.txt: path required")
        }
        XCTAssertEqual(detached(gw), [png.url.path, "/cache/doc-1.png", "/cache/doc-2.png"])
        XCTAssertFalse(Parity.methods(gw).contains("prompt.submit"))
    }

    func testAFailedSubmitDetachesWhatItStaged() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw) { m, _ in
            m == "prompt.submit" ? ["__error": ["code": 4090, "message": "SESSION_NOT_OWNED"]] : nil
        }
        defer { backend.client.close() }
        do { try await s.submit("hi", files: [try checked("doc.pdf")]); XCTFail("sent") }
        catch BotChatError.sessionNotOwned {}
        XCTAssertEqual(detached(gw), ["/cache/doc-1.png", "/cache/doc-2.png"])
    }

    func testPDFTheBackendCannotRenderGoesAsAFileReference() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, s) = try await open(gw) { m, _ in
            m == "pdf.attach" ? ["__error": ["code": 5028, "message": "pdftoppm not found"]] : nil
        }
        defer { backend.client.close() }
        try await s.submit("read", files: [try checked("doc.pdf")])
        XCTAssertEqual(Array(Parity.methods(gw).dropFirst(2)), ["pdf.attach", "file.attach", "prompt.submit"])
        XCTAssertEqual(gw.received.last?["params"]?["text"], "@file:notes.txt\n\nread")
    }
}
