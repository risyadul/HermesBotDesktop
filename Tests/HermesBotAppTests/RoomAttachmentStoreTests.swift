import Foundation
import HermesGatewayKit
import XCTest
@testable import HermesBotApp

/// Copies of Group Chat attachments: private folders per room, never a path built from an odd room id,
/// cleaned up when a message is not sent and when the room is disbanded.
final class RoomAttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hba-store-\(UUID().uuidString)")
        source = FileManager.default.temporaryDirectory.appendingPathComponent("hba-src-\(UUID().uuidString).txt")
        try Data("report".utf8).write(to: source)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }

    func testCopyLandsInAPrivateRoomFolderAndSurvivesTheOriginal() throws {
        let checked = try RoomAttachments.check(source)
        let a = try RoomAttachmentStore.copy(checked, room: "hba-9c63e77525ef", root: root)
        let b = try RoomAttachmentStore.copy(checked, room: "hba-9c63e77525ef", root: root)
        XCTAssertNotEqual(a, b, "the same file twice never collides")
        XCTAssertEqual(a.lastPathComponent, source.lastPathComponent)
        XCTAssertTrue(a.path.hasPrefix(root.appendingPathComponent("hba-9c63e77525ef").path + "/"))
        for dir in [root!, a.deletingLastPathComponent().deletingLastPathComponent(), a.deletingLastPathComponent()] {
            let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
            XCTAssertEqual(perms, 0o700, dir.path)
        }
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "report", "the bots read the copy, not the original")

        RoomAttachmentStore.discard([b], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        RoomAttachmentStore.remove(room: "hba-9c63e77525ef", root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testOddRoomIdsNeverBecomePaths() throws {
        let checked = try RoomAttachments.check(source)
        for bad in ["", "..", "../etc", "a/b", "hba 1", String(repeating: "a", count: 200)] {
            XCTAssertThrowsError(try RoomAttachmentStore.copy(checked, room: bad, root: root), bad)
        }
        RoomAttachmentStore.discard([URL(fileURLWithPath: "/tmp/outside/x.txt")], root: root)  // outside root: ignored
    }

    func testFileIsCheckedAgainAtCopyTime() throws {
        let checked = try RoomAttachments.check(source)
        let h = try FileHandle(forWritingTo: source)
        try h.truncate(atOffset: UInt64(RoomAttachments.maxBytes + 1))  // grew past the cap after its chip was added
        try h.close()
        XCTAssertThrowsError(try RoomAttachmentStore.copy(checked, room: "hba-1", root: root))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)  // swapped for a folder
        XCTAssertThrowsError(try RoomAttachmentStore.copy(checked, room: "hba-1", root: root))
        try FileManager.default.removeItem(at: source)
    }

    func testDiscardOnlyRemovesAPerFileFolderAndContainsOnlyMatchesOwnCopies() throws {
        let copy = try RoomAttachmentStore.copy(try RoomAttachments.check(source), room: "hba-1", root: root)
        let roomDir = root.appendingPathComponent("hba-1")
        RoomAttachmentStore.discard([roomDir.appendingPathComponent("x")], root: root)  // one level too shallow
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the room folder is never removed by discard")
        RoomAttachmentStore.discard([URL(fileURLWithPath: copy.path + "/../../../x/y/z")], root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

        XCTAssertTrue(RoomAttachmentStore.contains(copy.path, room: "hba-1", root: root))
        XCTAssertFalse(RoomAttachmentStore.contains(copy.path, room: "hba-2", root: root), "another room's copy")
        XCTAssertFalse(RoomAttachmentStore.contains(NSHomeDirectory() + "/.ssh/id_rsa", room: "hba-1", root: root))
        XCTAssertFalse(RoomAttachmentStore.contains(roomDir.path + "/a/../../../../etc/passwd", room: "hba-1", root: root))
        XCTAssertFalse(RoomAttachmentStore.contains(roomDir.path + "/deep/er/x.txt", room: "hba-1", root: root))
    }
}
