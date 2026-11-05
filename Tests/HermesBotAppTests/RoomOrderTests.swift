import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// C1.4: pinned rooms first, the user's order within each group, Move Up / Move Down, drag and drop inside a
/// group only, saved in UserDefaults (a throwaway suite here, never the app's).
@MainActor
final class RoomOrderTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "hba-room-order-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Backend order: most recently updated first (`groups.list`).
    private let rooms = ["a", "b", "c", "d", "e"].map { RoomFixtures.room("hba-\($0)", name: $0.uppercased()) }

    private func ids(_ store: RoomOrderStore) -> [String] { store.sorted(rooms).map(\.roomId) }

    func testWithoutChangesTheBackendOrderIsKept() {
        XCTAssertEqual(ids(RoomOrderStore(defaults: defaults)), ["hba-a", "hba-b", "hba-c", "hba-d", "hba-e"])
    }

    func testPinnedRoomsComeFirstInTheOrderTheyWerePinned() {
        let store = RoomOrderStore(defaults: defaults)
        store.setPinned("hba-d", true, rooms: rooms)
        store.setPinned("hba-b", true, rooms: rooms)
        XCTAssertEqual(ids(store), ["hba-d", "hba-b", "hba-a", "hba-c", "hba-e"])
        XCTAssertTrue(store.isPinned("hba-d"))
        // Unpinned: back to the top of the others.
        store.setPinned("hba-d", false, rooms: rooms)
        XCTAssertEqual(ids(store), ["hba-b", "hba-d", "hba-a", "hba-c", "hba-e"])
        XCTAssertFalse(store.isPinned("hba-d"))
    }

    func testMoveUpAndDownStayInsideTheGroup() {
        let store = RoomOrderStore(defaults: defaults)
        store.setPinned("hba-c", true, rooms: rooms)  // c | a b d e
        XCTAssertFalse(store.canMove("hba-c", .up, rooms: rooms), "first room")
        XCTAssertFalse(store.canMove("hba-c", .down, rooms: rooms), "the only pinned room does not leave its group")
        XCTAssertFalse(store.canMove("hba-a", .up, rooms: rooms), "the first unpinned room does not jump above a pinned one")
        XCTAssertFalse(store.canMove("hba-e", .down, rooms: rooms), "last room")
        store.move("hba-a", .down, rooms: rooms)
        XCTAssertEqual(ids(store), ["hba-c", "hba-b", "hba-a", "hba-d", "hba-e"])
        store.move("hba-e", .up, rooms: rooms)
        XCTAssertEqual(ids(store), ["hba-c", "hba-b", "hba-a", "hba-e", "hba-d"])
        store.move("hba-c", .up, rooms: rooms)  // no-op at the edge
        XCTAssertEqual(ids(store), ["hba-c", "hba-b", "hba-a", "hba-e", "hba-d"])
    }

    func testDragTakesTheTargetsPlace() {
        let store = RoomOrderStore(defaults: defaults)
        XCTAssertTrue(store.drop(RoomOrderStore.dragPayload("hba-a"), onto: "hba-d", rooms: rooms), "dragged down: after d")
        XCTAssertEqual(ids(store), ["hba-b", "hba-c", "hba-d", "hba-a", "hba-e"])
        XCTAssertTrue(store.drop(RoomOrderStore.dragPayload("hba-e"), onto: "hba-b", rooms: rooms), "dragged up: before b")
        XCTAssertEqual(ids(store), ["hba-e", "hba-b", "hba-c", "hba-d", "hba-a"])
    }

    func testDropsAcrossGroupsOrFromElsewhereAreRefused() {
        let store = RoomOrderStore(defaults: defaults)
        store.setPinned("hba-e", true, rooms: rooms)
        let before = ids(store)
        XCTAssertFalse(store.drop(RoomOrderStore.dragPayload("hba-a"), onto: "hba-e", rooms: rooms), "unpinned onto pinned")
        XCTAssertFalse(store.drop(RoomOrderStore.dragPayload("hba-e"), onto: "hba-a", rooms: rooms), "pinned onto unpinned")
        XCTAssertFalse(store.drop("hba-a", onto: "hba-c", rooms: rooms), "plain text dragged in from another app")
        XCTAssertFalse(store.drop(RoomOrderStore.dragPayload("hba-zzz"), onto: "hba-c", rooms: rooms), "not a room of this list")
        XCTAssertFalse(store.drop(RoomOrderStore.dragPayload("hba-c"), onto: "hba-c", rooms: rooms), "onto itself")
        XCTAssertEqual(ids(store), before)
        XCTAssertNil(RoomOrderStore.roomId(fromDrag: RoomOrderStore.dragPrefix))
    }

    func testANewRoomShowsAtTheTopOfTheOthersAfterARearrange() {
        let store = RoomOrderStore(defaults: defaults)
        store.move("hba-a", .down, rooms: rooms)
        let newer = [RoomFixtures.room("hba-new", name: "New")] + rooms
        XCTAssertEqual(store.sorted(newer).map(\.roomId), ["hba-new", "hba-b", "hba-a", "hba-c", "hba-d", "hba-e"])
    }

    func testOrderIsSavedAndForgottenOnDisband() {
        let store = RoomOrderStore(defaults: defaults)
        store.setPinned("hba-c", true, rooms: rooms)
        store.move("hba-e", .up, rooms: rooms)
        let reloaded = RoomOrderStore(defaults: defaults)
        XCTAssertEqual(ids(reloaded), ids(store), "kept across launches")
        XCTAssertEqual(defaults.stringArray(forKey: RoomOrderStore.pinnedKey), ["hba-c"])
        reloaded.forget("hba-c")
        XCTAssertFalse(reloaded.isPinned("hba-c"))
        XCTAssertFalse(RoomOrderStore(defaults: defaults).order.arranged.contains("hba-c"))
    }

    func testDisbandingARoomDropsItsPinAndPicture() async throws {
        let store = RoomOrderStore(defaults: defaults)
        let room = RoomFixtures.room()
        store.setPinned(room.roomId, true, rooms: [room] + rooms)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hba-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pictures = RoomPictureStore(root: root)
        let png = root.deletingLastPathComponent().appendingPathComponent("hba-pic-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try RoomPictureTests.pngData().write(to: png)
        try pictures.setPicture(room: room.roomId, from: png)

        let model = RoomModel(room: room, api: FakeRoomActions(rooms: [room]))
        model.order = store
        model.pictures = pictures
        defer { model.shutdown() }
        let disbanded = await model.disband()
        XCTAssertTrue(disbanded)
        XCTAssertFalse(store.isPinned(room.roomId))
        XCTAssertFalse(pictures.hasPicture(room: room.roomId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pictures.file(room: room.roomId)!.path))
    }
}
