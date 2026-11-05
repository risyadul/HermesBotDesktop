import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D13 room templates and D15 per-bot / per-room mutes, on a private UserDefaults suite. Notifications go to a
/// recording poster; nothing reaches the system notification centre.
@MainActor
final class RoomTemplateMuteTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "RoomTemplateMuteTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func bot(_ name: String, title: String? = nil) -> Bot {
        var v: [String: JSONValue] = ["name": .string(name)]
        if let title { v["display_name"] = .string(title) }
        return Bot(.object(v))!
    }

    // MARK: D13 templates

    func testSaveValidatesAndPersists() {
        let store = RoomTemplateStore(defaults: defaults)
        XCTAssertEqual(store.save(name: "  ", members: ["a", "b"], prompt: ""), .failure(.name))
        XCTAssertEqual(store.save(name: "Solo", members: ["a", "a"], prompt: ""), .failure(.members), "duplicates count once")
        XCTAssertEqual(store.save(name: "Crowd", members: (1...7).map { "b\($0)" }, prompt: ""), .failure(.members))
        XCTAssertEqual(store.save(name: "Long", members: ["a", "b"], prompt: String(repeating: "x", count: RoomComposer.maxTextBytes + 1)),
                       .failure(.promptTooLong))
        guard case .success(let t) = store.save(name: " Release crew ", members: ["alpha", "beta"], prompt: "  Plan the release.\n") else {
            return XCTFail("a valid template saves")
        }
        XCTAssertEqual(t.name, "Release crew")
        XCTAssertEqual(t.prompt, "Plan the release.")
        let reloaded = RoomTemplateStore(defaults: defaults)
        XCTAssertEqual(reloaded.templates, [t], "kept across launches")
    }

    func testSameNameReplacesAndListIsSortedAndRemovable() {
        let store = RoomTemplateStore(defaults: defaults)
        store.save(name: "Zeta", members: ["a", "b"], prompt: "1")
        store.save(name: "alpha", members: ["a", "b"], prompt: "1")
        store.save(name: "ZETA", members: ["a", "c"], prompt: "2")
        XCTAssertEqual(store.templates.map(\.name), ["alpha", "ZETA"])
        XCTAssertEqual(store.templates.last?.members, ["a", "c"])
        store.remove(store.templates[0].id)
        XCTAssertEqual(RoomTemplateStore(defaults: defaults).templates.map(\.name), ["ZETA"])
    }

    func testPrefillKeepsOnlyBotsStillHereAndCarriesThePrompt() {
        let t = RoomTemplate(id: UUID(), name: "Crew", members: ["alpha", "gone", "beta"], prompt: "Kick off")
        let prefill = RoomTemplateStore.prefill(t, bots: [bot("alpha"), bot("beta")])
        XCTAssertEqual(prefill, CreateRoomPrefill(name: "Crew", members: ["alpha", "beta"], draft: "Kick off"))
        XCTAssertEqual(RoomTemplateStore.memberSummary(t, bots: [bot("alpha", title: "Alpha")]), "Alpha, @gone and 1 more")
        let two = RoomTemplate(id: UUID(), name: "Pair", members: ["alpha", "beta"], prompt: "")
        XCTAssertEqual(RoomTemplateStore.memberSummary(two, bots: []), "@alpha and @beta")
    }

    func testNewRoomFromTemplateNeedsAConnectionAndSaveNeedsAListedRoom() {
        let app = AppModel()
        app.bots = [bot("alpha"), bot("beta")]
        let t = RoomTemplate(id: UUID(), name: "Crew", members: ["alpha", "beta"], prompt: "Go")
        app.newRoom(from: t)
        XCTAssertFalse(app.showCreateRoom, "nothing opens without a backend")
        XCTAssertNil(app.createRoomPrefill)
        app.saveTemplate(from: "hba-missing")
        XCTAssertNil(app.templateSource)
        let room = RoomFixtures.room("hba-1")
        app.rooms = [room]
        app.selection = .room("hba-1")
        XCTAssertEqual(app.selectedRoom?.roomId, "hba-1")
        app.saveTemplate(from: "hba-1")
        XCTAssertEqual(app.templateSource?.roomId, "hba-1")
    }

    func testCreatingFromTheSheetPutsThePromptInTheComposerNotSent() async {
        // The created room's composer gets the template prompt through the same path as the Desktop archive
        // carry-over (`createRoomFromSheet`); without a backend nothing is created and nothing is sent.
        let app = AppModel()
        app.createRoomPrefill = RoomTemplateStore.prefill(RoomTemplate(id: UUID(), name: "Crew", members: [], prompt: "Go"), bots: [])
        let error = await app.createRoomFromSheet(name: "Crew", members: [])
        XCTAssertEqual(error, "not connected")
        XCTAssertEqual(app.createRoomPrefill?.draft, "Go")
    }

    // MARK: D15 mutes

    func testMutesPersistPerBotAndRoomOnly() {
        let mutes = NotificationMutes(defaults: defaults)
        mutes.setMuted(.bot("alpha"), true)
        mutes.setMuted(.room("hba-1"), true)
        mutes.setMuted(.board("default"), true)
        XCTAssertTrue(mutes.isMuted(.bot("alpha")))
        XCTAssertFalse(mutes.isMuted(.board("default")), "boards do not notify")
        let reloaded = NotificationMutes(defaults: defaults)
        XCTAssertEqual(reloaded.muted, ["bot:alpha", "room:hba-1"])
        reloaded.setMuted(.bot("alpha"), false)
        XCTAssertEqual(NotificationMutes(defaults: defaults).muted, ["room:hba-1"])
        XCTAssertEqual(NotificationMutes.menuTitle(muted: true), "Unmute Notifications")
        XCTAssertEqual(NotificationMutes.menuTitle(muted: false), "Mute Notifications")
    }

    func testEveryEventHasItsBotOrRoom() {
        let r = RoomFixtures.approval.pendingActions.compactMap { a -> RoomApproval? in if case .approval(let x) = a { return x }; return nil }[0]
        XCTAssertEqual(NotificationMutes.target(of: .botReplied(bot: "a", title: "A", text: "x")), .bot("a"))
        XCTAssertEqual(NotificationMutes.target(of: .roomApproval(roomId: "r", roomName: "R", member: "m", approval: r)), .room("r"))
        XCTAssertEqual(NotificationMutes.target(of: .roomMention(roomId: "r", roomName: "R", discussion: "d", author: "a", text: "t")), .room("r"))
    }

    func testPolicyNeverPostsForMuted() {
        let e = AttentionEvent.botReplied(bot: "a", title: "A", text: "done")
        XCTAssertTrue(NotificationPolicy.shouldPost(e, appActive: false, enabled: true, botHidden: false))
        XCTAssertFalse(NotificationPolicy.shouldPost(e, appActive: false, enabled: true, botHidden: false, muted: true))
    }

    func testMutedRoomStillCountsInTheBadgeButPostsNothing() {
        final class Poster: NotificationPosting {
            var posted: [NotificationContent] = []
            func post(_ content: NotificationContent) { posted.append(content) }
            func remove(ids: [String]) {}
        }
        let poster = Poster()
        let c = NotificationCoordinator(poster: poster)
        c.appActive = { false }
        c.enabled = { true }
        c.setBadge = { _ in }
        let mutes = NotificationMutes(defaults: defaults)
        c.muted = { mutes.isMuted($0) }
        let room = RoomFixtures.room("hba-1")
        mutes.setMuted(.room("hba-1"), true)
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [], driver: RoomFixtures.approval, latestSeq: 0)
        XCTAssertTrue(poster.posted.isEmpty, "muted: no banner, even for an approval")
        XCTAssertEqual(c.badgeCount, 1, "the Dock badge still counts what waits on the user")
        mutes.setMuted(.room("hba-1"), false)
        let other = RoomFixtures.room("hba-2")
        c.rooms.setRooms([room, other])
        c.rooms.ingest(room: other, events: [], driver: RoomFixtures.approval, latestSeq: 0)
        XCTAssertEqual(poster.posted.count, 1, "an unmuted room still notifies")
    }
}
