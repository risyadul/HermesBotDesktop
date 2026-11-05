import Foundation
import XCTest
@testable import HermesGatewayKit

/// Group Chat attachments travel as a block of absolute paths (rooms are text-only); this app folds the
/// block back into attachments.
final class RoomAttachmentsTests: XCTestCase {
    func testComposeAndSplitRoundTrip() {
        let paths = ["/Users/me/Library/Application Support/HermesBotApp/Room Attachments/hba-1/3f2a91c0/report.pdf",
                     "/Users/me/x/shot 1.png"]
        let sent = RoomAttachments.compose(text: "  @default lihat ini  ", paths: paths)
        XCTAssertEqual(sent, "@default lihat ini\n\n" + RoomAttachments.header + "\n- " + paths[0] + "\n- " + paths[1])
        let back = RoomAttachments.split(sent)
        XCTAssertEqual(back.text, "@default lihat ini")
        XCTAssertEqual(back.paths, paths)
        XCTAssertEqual(RoomAttachments.mediaRefs(back.paths).map(\.kind), [.pdf, .image])

        let only = RoomAttachments.compose(text: " ", paths: [paths[1]])
        XCTAssertTrue(only.hasPrefix(RoomAttachments.header), "files alone: the block is the message")
        XCTAssertEqual(RoomAttachments.split(only).text, "")
        XCTAssertEqual(RoomAttachments.compose(text: "hi", paths: []), "hi")
    }

    func testTextThatOnlyLooksLikeABlockIsLeftAlone() {
        for message in ["no block here",
                        "quote:\n\n" + RoomAttachments.header + "\n- relative/path.txt",
                        "x\n\n" + RoomAttachments.header + "\n- /a.txt\nand then prose",
                        "x\n\n" + RoomAttachments.header] {
            XCTAssertEqual(RoomAttachments.split(message).text, message, message)
            XCTAssertTrue(RoomAttachments.split(message).paths.isEmpty, message)
        }
    }

    func testCheckRefusesLargeFilesDirectoriesAndMultilineNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-room-att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: ok)
        XCTAssertEqual(try RoomAttachments.check(ok).kind, .file)
        let multiline = dir.appendingPathComponent("evil\nname.txt")
        try Data("x".utf8).write(to: multiline)
        XCTAssertThrowsError(try RoomAttachments.check(multiline)) { XCTAssertTrue($0 is RoomAttachments.Failure) }
        XCTAssertThrowsError(try RoomAttachments.check(dir))
        let spaced = dir.appendingPathComponent("notes.txt ")
        try Data("x".utf8).write(to: spaced)
        XCTAssertThrowsError(try RoomAttachments.check(spaced), "an edge space would not survive the block round trip")
        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(RoomAttachments.maxBytes + 1))
        try h.close()
        XCTAssertThrowsError(try RoomAttachments.check(big)) {
            XCTAssertEqual($0 as? ChatAttachments.Failure, .tooLarge("big.bin", limitMB: 50))
        }
        let manyPages = dir.appendingPathComponent("long.pdf")
        try Data("%PDF-1.4".utf8).write(to: manyPages)
        XCTAssertEqual(try RoomAttachments.check(manyPages).kind, .pdf, "no page limit or PDF parse: bots read it themselves")
    }
}
