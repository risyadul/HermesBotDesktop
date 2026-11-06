import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// C1.8: the local room picture (a temp folder here, never Application Support) and "N of M available".
@MainActor
final class RoomPictureTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("hba-room-pictures-\(UUID().uuidString)")
        scratch = base.appendingPathComponent("hba-room-picture-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A 40 × 20 PNG.
    static func pngData(width: Int = 40, height: Int = 20) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func source(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testChosenPictureIsSavedAsAPrivateSquarePNG() throws {
        let store = RoomPictureStore(root: root)
        XCTAssertFalse(store.hasPicture(room: "hba-1"))
        try store.setPicture(room: "hba-1", from: try source("wide.png", try Self.pngData()))
        let file = try XCTUnwrap(store.file(room: "hba-1"))
        XCTAssertEqual(file.lastPathComponent, "hba-1.png")
        let image = try XCTUnwrap(NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(image.width, ProfileAvatar.edge)
        XCTAssertEqual(image.height, ProfileAvatar.edge, "centred square, like a bot avatar")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(store.hasPicture(room: "hba-1"))
        XCTAssertTrue(RoomPictureStore(root: root).hasPicture(room: "hba-1"), "read back from disk")
    }

    func testRemovePictureDeletesTheFile() throws {
        let store = RoomPictureStore(root: root)
        try store.setPicture(room: "hba-1", from: try source("a.png", try Self.pngData()))
        store.removePicture(room: "hba-1")
        XCTAssertFalse(store.hasPicture(room: "hba-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(room: "hba-1")!.path))
        store.removePicture(room: "hba-1")  // nothing there: no error
    }

    func testANonImageIsRefusedAndKeepsThePreviousPicture() throws {
        let store = RoomPictureStore(root: root)
        try store.setPicture(room: "hba-1", from: try source("a.png", try Self.pngData()))
        let before = try Data(contentsOf: store.file(room: "hba-1")!)
        XCTAssertThrowsError(try store.setPicture(room: "hba-1", from: try source("fake.png", Data("not an image".utf8)))) {
            XCTAssertEqual($0 as? ProfileAvatar.Failure, .notAnImage)
        }
        XCTAssertEqual(try Data(contentsOf: store.file(room: "hba-1")!), before)
    }

    func testOddRoomIdsNeverBecomeFileNames() throws {
        let store = RoomPictureStore(root: root)
        let png = try source("a.png", try Self.pngData())
        for bad in ["", "..", "../x", "a/b", "a b"] {
            XCTAssertNil(store.file(room: bad), bad)
            XCTAssertThrowsError(try store.setPicture(room: bad, from: png), bad)
            XCTAssertFalse(store.hasPicture(room: bad))
        }
    }

    // MARK: availability

    func testEveryMemberAvailable() {
        let a = RoomAvailability(room: RoomFixtures.room(), bots: ["alpha", "beta", "gamma"], states: ["alpha": .replied, "beta": .waiting])
        XCTAssertEqual(a.summary, "2 of 2 available")
        XCTAssertEqual(a.detail, "Every bot in this room is available.")
    }

    func testMissingBotAndFailingTurnAreUnavailable() {
        let gone = RoomAvailability(room: RoomFixtures.room(), bots: ["alpha"], states: [:])
        XCTAssertEqual(gone.summary, "1 of 2 available")
        XCTAssertEqual(gone.unavailable.map(\.reason), [.botMissing])
        XCTAssertTrue(gone.detail.contains("beta (@beta): its bot no longer exists"))

        for state in [RoomPresentation.MemberState.failed, .deferred] {
            let failing = RoomAvailability(room: RoomFixtures.room(), bots: ["alpha", "beta"], states: ["alpha": state])
            XCTAssertEqual(failing.summary, "1 of 2 available", state.rawValue)
            XCTAssertEqual(failing.unavailable.map(\.member.memberId), ["alpha"])
            XCTAssertEqual(failing.unavailable.map(\.reason), [.failing])
        }
        let approval = RoomAvailability(room: RoomFixtures.room(), bots: ["alpha", "beta"], states: ["alpha": .needsApproval])
        XCTAssertEqual(approval.summary, "2 of 2 available", "waiting on the user is not unavailable")
    }

    func testBotsNotLoadedYetAreNotJudged() {
        XCTAssertEqual(RoomAvailability(room: RoomFixtures.room(), bots: nil, states: [:]).summary, "2 of 2 available")
        XCTAssertEqual(RoomAvailability(room: RoomFixtures.room(), bots: [], states: [:]).summary, "2 of 2 available")
    }

    func testAvailabilityFollowsGroupsStateApprovalsAndTheLog() {
        // A failed turn in the log for the latest message makes that member unavailable.
        var timeline = RoomTimeline()
        _ = timeline.apply(RoomLogPage(events: [
            RoomFixtures.user(1),
            RoomEvent(seq: 2, eventId: "t2", kind: "turn.failed", actor: ["kind": "gateway", "id": "x"],
                      payload: ["member_id": "beta", "discussion_event_id": "user:1", "thread_id": "main", "task_id": "k2"]),
        ], cursor: 2, latestSeq: 2, hasMore: false))
        let states = RoomPresentation.memberStates(room: RoomFixtures.room(), timeline: timeline, driver: nil)
        let a = RoomAvailability(room: RoomFixtures.room(), bots: ["alpha", "beta"], states: states)
        XCTAssertEqual(a.summary, "1 of 2 available")
        XCTAssertEqual(a.unavailable.map(\.member.memberId), ["beta"])
    }
}
