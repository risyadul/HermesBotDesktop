import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D12 "Summarize since I left": where the user left a room (RoomDigestHub.leftAt), the summary prompt, and
/// the sheet's ask, which goes to a bot's Bot Chat and never into the room. Headless, with fakes.
@MainActor
final class RoomCatchUpTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "hba-catchup-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private let room = RoomFixtures.room()

    private func lines(_ events: [RoomEvent]) -> [RoomLine] {
        var t = RoomTimeline()
        t.apply(RoomLogPage(events: events, cursor: events.last?.seq ?? 0, latestSeq: events.last?.seq ?? 0, hasMore: false))
        return t.lines(room: room)
    }

    // MARK: where the user left

    func testLeftAtIsCapturedOncePerVisitBeforeTheVisitMarksSeen() {
        let hub = RoomDigestHub(defaults: defaults)
        let id = room.roomId
        let early = [RoomFixtures.user(1), RoomFixtures.member(2, "alpha")]
        hub.absorb(roomId: id, room: room, events: early, driver: nil, onScreen: true, cursor: 2, visit: 1)
        XCTAssertEqual(hub.leftAt[id], 0, "first visit: nothing was seen before")
        XCTAssertEqual(hub.seenThrough[id], 2)
        hub.absorb(roomId: id, room: room, events: early + [RoomFixtures.member(3, "beta")], driver: nil, onScreen: true,
                   cursor: 3, visit: 1)
        XCTAssertEqual(hub.leftAt[id], 0, "later polls of the same visit keep the mark")
        // Away: the background watch reads on (not on screen), nothing is marked seen.
        hub.absorb(roomId: id, room: room, events: early + [RoomFixtures.member(3, "beta"), RoomFixtures.member(4, "alpha")],
                   driver: nil, onScreen: false, cursor: 4)
        XCTAssertEqual(hub.leftAt[id], 0)
        XCTAssertEqual(hub.seenThrough[id], 3)
        // Back: a new poll generation.
        hub.absorb(roomId: id, room: room, events: early, driver: nil, onScreen: true, cursor: 4, visit: 2)
        XCTAssertEqual(hub.leftAt[id], 3, "the user left after seq 3")
        XCTAssertEqual(hub.seenThrough[id], 4)
        hub.forget(id)
        XCTAssertNil(hub.leftAt[id])
    }

    // MARK: prompt

    func testPromptQuotesOnlyUnseenMessagesOfEveryThread() throws {
        let all = lines([RoomFixtures.user(1, "old question"), RoomFixtures.member(2, "alpha", "old answer"),
                         RoomFixtures.member(3, "beta", "deploy is @alpha green"),
                         RoomFixtures.member(4, "alpha", "line one\nline two", thread: "hba-t-2"),
                         RoomFixtures.settled(5)])
        XCTAssertEqual(RoomCatchUp.unseen(all, after: 2).map(\.id), [3, 4])
        let p = try XCTUnwrap(RoomCatchUp.prompt(room: room, lines: all, after: 2))
        XCTAssertEqual(p.quoted, 2)
        XCTAssertEqual(p.total, 2)
        XCTAssertTrue(p.text.hasPrefix("Summarize what happened in the group chat \"Ops\" since I last read it (2 new messages, quoted below"))
        XCTAssertTrue(p.text.hasSuffix("> beta: deploy is alpha green\n> [thread] Alpha: line one line two"), p.text)
        XCTAssertFalse(p.text.contains("old answer"))
        XCTAssertNil(RoomCatchUp.prompt(room: room, lines: all, after: 4), "nothing unseen: nothing to ask")
    }

    func testPromptKeepsTheNewestMessagesWithinItsLimits() throws {
        let many = lines((1...(RoomCatchUp.messageLimit + 20)).map { RoomFixtures.member($0, "alpha", "message \($0)") })
        let p = try XCTUnwrap(RoomCatchUp.prompt(room: room, lines: many, after: 0))
        XCTAssertEqual(p.quoted, RoomCatchUp.messageLimit)
        XCTAssertEqual(p.total, RoomCatchUp.messageLimit + 20)
        XCTAssertTrue(p.text.contains("the latest \(RoomCatchUp.messageLimit) quoted below"))
        XCTAssertTrue(p.text.hasSuffix("message \(RoomCatchUp.messageLimit + 20)"))

        let long = lines((1...40).map { RoomFixtures.member($0, "alpha", String(repeating: "w ", count: 400)) })
        let capped = try XCTUnwrap(RoomCatchUp.prompt(room: room, lines: long, after: 0))
        XCTAssertLessThanOrEqual(capped.text.count, RoomCatchUp.charLimit)
        XCTAssertLessThan(capped.quoted, 40)
    }

    func testDefaultBotIsARoomMember() {
        let bots = [Bot(["name": "zeta"])!, Bot(["name": "beta"])!]
        XCTAssertEqual(RoomCatchUp.defaultBot(room: room, bots: bots), "beta", "Alpha is not a bot any more; Beta is")
        XCTAssertEqual(RoomCatchUp.defaultBot(room: room, bots: [Bot(["name": "zeta"])!]), "zeta")
        XCTAssertNil(RoomCatchUp.defaultBot(room: room, bots: []))
    }

    // MARK: asking

    func testAskGoesToTheBotChatAndNeverToTheRoom() async throws {
        let f = QuickSendFixture()
        let events = [RoomFixtures.user(1), RoomFixtures.member(2, "alpha", "shipped"), RoomFixtures.member(3, "beta", "nice")]
        let model = RoomCatchUpModel(room: room, lines: lines(events), after: 1, sender: { f.sender })
        XCTAssertEqual(model.bot, "alpha", "the room's first member that is a bot")
        XCTAssertTrue(model.canAsk)
        await model.ask()
        let turn = try XCTUnwrap(model.turn)
        XCTAssertFalse(model.canAsk, "one ask per sheet")
        await eventually { f.sent("alpha").count == 1 }
        XCTAssertTrue(f.sent("alpha")[0].contains("> Alpha: shipped\n> beta: nice"))
        XCTAssertTrue(f.rooms.sends.isEmpty, "nothing is posted in the room")
        f.reply("alpha", "Alpha shipped; Beta liked it.")
        await eventually { QuickReply.state(lines: turn.chat.lines, after: turn.userLine, busy: turn.chat.busy) == .done("Alpha shipped; Beta liked it.") }
    }

    func testNothingUnseenCannotAsk() async {
        let f = QuickSendFixture()
        let model = RoomCatchUpModel(room: room, lines: lines([RoomFixtures.user(1)]), after: 1, sender: { f.sender })
        XCTAssertNil(model.prompt)
        XCTAssertFalse(model.canAsk)
        await model.ask()
        XCTAssertTrue(f.sent("alpha").isEmpty)
    }
}
