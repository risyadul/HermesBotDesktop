import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Sidebar room rows (C1.5 "needs you", C1.7 last-message preview) through `RoomDigestHub`, headless.
@MainActor
final class RoomDigestHubTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "hba-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private let asks: [RoomEvent] = [RoomFixtures.user(1), RoomFixtures.member(2, "alpha", "@user pick A or B?"), RoomFixtures.settled(3)]

    func testMentionBadgesUntilTheRoomIsSeen() {
        let hub = RoomDigestHub(defaults: defaults)
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: asks, driver: nil, onScreen: false, cursor: 3)
        XCTAssertEqual(hub.needsYou("hba-test-0", onScreen: false), .mention)
        XCTAssertNil(hub.needsYou("hba-test-0", onScreen: true), "never on the room that is on screen")
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: asks, driver: nil, onScreen: true, cursor: 3)
        XCTAssertNil(hub.needsYou("hba-test-0", onScreen: false), "opening the room clears it")
        XCTAssertEqual(hub.seenThrough["hba-test-0"], 3)
    }

    func testMentionClearedByTheUsersReply() {
        let hub = RoomDigestHub(defaults: defaults)
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: asks + [RoomFixtures.user(4, "B")], driver: nil,
                   onScreen: false, cursor: 4)
        XCTAssertNil(hub.needsYou("hba-test-0", onScreen: false))
    }

    func testSeenPersistsAcrossLaunches() {
        let first = RoomDigestHub(defaults: defaults)
        first.markSeen("hba-test-0", through: 3)
        first.markSeen("hba-test-0", through: 1)
        XCTAssertEqual(first.seenThrough["hba-test-0"], 3, "monotonic")
        let relaunched = RoomDigestHub(defaults: defaults)
        relaunched.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: asks, driver: nil, onScreen: false, cursor: 3)
        XCTAssertNil(relaunched.needsYou("hba-test-0", onScreen: false), "an @user already read does not badge again")
        relaunched.forget("hba-test-0")
        XCTAssertNil(RoomDigestHub(defaults: defaults).seenThrough["hba-test-0"], "a disbanded room's state goes")
    }

    func testPendingApprovalBadges() {
        let hub = RoomDigestHub(defaults: defaults)
        let working = [RoomFixtures.user(1)]
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: working, driver: RoomFixtures.approval, onScreen: false, cursor: 1)
        XCTAssertEqual(hub.needsYou("hba-test-0", onScreen: false), .approval)
        XCTAssertNil(hub.needsYou("hba-test-0", onScreen: true))
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: working, driver: RoomDriverStatus(working: true),
                   onScreen: false, cursor: 1)
        XCTAssertNil(hub.needsYou("hba-test-0", onScreen: false), "answered: the badge goes")
    }

    func testPreviewFollowsTheOpenRoom() {
        let hub = RoomDigestHub(defaults: defaults)
        hub.absorb(roomId: "hba-test-0", room: RoomFixtures.room(), events: asks, driver: nil, onScreen: true, cursor: 3)
        XCTAssertEqual(hub.digests["hba-test-0"]?.preview?.author, "Alpha")
        XCTAssertEqual(RoomRowContent.subtitle(room: RoomFixtures.room(), digest: hub.digests["hba-test-0"]), "Alpha: @user pick A or B?")
        XCTAssertEqual(RoomRowContent.subtitle(room: RoomFixtures.room(), digest: nil), "2 bots · @alpha @beta",
                       "no message yet: the members, as before")
    }

    func testRefreshReadsTailsOnlyForRoomsThatMoved() async {
        let api = FakeRoomActions(rooms: [RoomFixtures.room("hba-a", latestSeq: 3), RoomFixtures.room("hba-b", latestSeq: 0)])
        api.setEvents("hba-a", asks)
        let hub = RoomDigestHub(defaults: defaults)
        hub.start(directory: api)
        await eventually { hub.digests["hba-a"] != nil && hub.digests["hba-b"] != nil }
        hub.stop()
        XCTAssertEqual(hub.digests["hba-a"]?.preview?.text, "@user pick A or B?")
        XCTAssertEqual(hub.needsYou("hba-a", onScreen: false), .mention)
        XCTAssertNil(hub.digests["hba-b"]?.preview, "an empty room has no preview")

        // Nothing moved: the next pass lists rooms and reads no log.
        let logsBefore = api.logRequests.count
        await hubRefresh(hub, api)
        XCTAssertEqual(api.logRequests.count, logsBefore)

        // Room a moved: only its new events are read (since its last seq).
        api.setEvents("hba-a", asks + [RoomFixtures.user(4, "B")])
        api.setRooms([RoomFixtures.room("hba-a", latestSeq: 4), RoomFixtures.room("hba-b", latestSeq: 0)])
        await hubRefresh(hub, api)
        XCTAssertEqual(api.logRequests.last.map { "\($0.room):\($0.since)" }, "hba-a:3")
        XCTAssertEqual(hub.digests["hba-a"]?.preview?.text, "B")
        XCTAssertEqual(hub.digests["hba-a"]?.preview?.author, "You")
        XCTAssertNil(hub.needsYou("hba-a", onScreen: false), "the user's reply cleared it")
    }

    func testRefreshAsksStateOnlyForUnsettledRooms() async {
        let api = FakeRoomActions(rooms: [RoomFixtures.room("hba-a", latestSeq: 1), RoomFixtures.room("hba-b", latestSeq: 3)])
        api.setEvents("hba-a", [RoomFixtures.user(1)])  // unsettled: a bot may be waiting on an approval
        api.setEvents("hba-b", asks)                     // settled
        api.setDriver("hba-a", RoomFixtures.approval)
        let hub = RoomDigestHub(defaults: defaults)
        await hubRefresh(hub, api)
        XCTAssertEqual(hub.needsYou("hba-a", onScreen: false), .approval)
        XCTAssertTrue(api.calls.contains("state:hba-a"))
        XCTAssertFalse(api.calls.contains("state:hba-b"), "a settled room cannot have a pending approval")
    }

    func testRoomsGoneFromTheListLoseTheirDigest() async {
        let api = FakeRoomActions(rooms: [RoomFixtures.room("hba-a", latestSeq: 3)])
        api.setEvents("hba-a", asks)
        let hub = RoomDigestHub(defaults: defaults)
        await hubRefresh(hub, api)
        XCTAssertNotNil(hub.digests["hba-a"])
        api.setRooms([])
        await hubRefresh(hub, api)
        XCTAssertNil(hub.digests["hba-a"])
    }

    func testFirstPassUsesTheRoomsJustListed() async {
        let rooms = [RoomFixtures.room("hba-a", latestSeq: 3)]
        let api = FakeRoomActions(rooms: rooms)
        api.setEvents("hba-a", asks)
        let hub = RoomDigestHub(defaults: defaults)
        hub.start(directory: api, listed: rooms)
        await eventually { hub.digests["hba-a"] != nil }
        hub.stop()
        XCTAssertFalse(api.calls.contains("list"), "connect already listed the rooms")
    }

    func testStoppedLoopNeverPolls() async {
        let api = FakeRoomActions(rooms: [RoomFixtures.room("hba-a", latestSeq: 3)])
        api.setEvents("hba-a", asks)
        let hub = RoomDigestHub(defaults: defaults)
        hub.start(directory: api)
        hub.stop()  // e.g. the backend was lost right after connect
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(hub.digests["hba-a"])
    }

    func testBadgeLabels() {
        XCTAssertEqual(NeedsYouBadge.label(.approval), "A bot in this group chat needs your approval")
        XCTAssertEqual(NeedsYouBadge.label(.mention), "A bot in this group chat needs your input")
    }

    /// One pass with `api` as the directory, without a loop.
    private func hubRefresh(_ hub: RoomDigestHub, _ api: FakeRoomActions) async {
        await hub.refresh(with: api)
    }
}
