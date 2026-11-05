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
}
