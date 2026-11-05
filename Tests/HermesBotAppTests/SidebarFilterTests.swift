import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A1 / A2 / A3: sidebar filter, the Bots section's pinned / hidden derivation, the row menu, and the
/// optimistic Pin / Hide model with its rollback. Headless; saves go to a fake, never to a real profile.
@MainActor
final class SidebarFilterTests: XCTestCase {
    private func bot(_ name: String, title: String? = nil, description: String? = nil, model: String? = nil) -> Bot {
        var row: [String: JSONValue] = ["name": .string(name)]
        if let title { row["display_name"] = .string(title) }
        if let description { row["description"] = .string(description) }
        if let model { row["model"] = .string(model) }
        return Bot(.object(row))!
    }

    private func room(_ id: String, name: String, members: [(String, String?)]) -> RoomSummary {
        RoomSummary(["room_id": .string(id), "name": .string(name),
                     "members": .array(members.map { m in
                         var o: [String: JSONValue] = ["member_id": .string(m.0), "profile": .string(m.0), "handle": .string(m.0)]
                         if let t = m.1 { o["display_name"] = .string(t) }
                         return .object(o)
                     })])!
    }

    // MARK: A3 filter

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SidebarFilter.matches(bot("alpha"), query: ""))
        XCTAssertTrue(SidebarFilter.matches(bot("alpha"), query: "   "))
        XCTAssertTrue(SidebarFilter.matches(bot("alpha"), query: "@"))
        XCTAssertFalse(SidebarFilter.isActive(" @ "))
    }

    func testBotMatchesTitleHandleDescriptionAndModelCaseInsensitivelyWithOptionalAt() {
        let b = bot("research-buddy", title: "Research Buddy", description: "Digs into papers", model: "claude-sonnet")
        XCTAssertTrue(SidebarFilter.matches(b, query: "BUDDY"))
        XCTAssertTrue(SidebarFilter.matches(b, query: "@research-b"))
        XCTAssertTrue(SidebarFilter.matches(b, query: "papers"))
        XCTAssertTrue(SidebarFilter.matches(b, query: "sonnet"))
        XCTAssertTrue(SidebarFilter.matches(b, query: "research papers"), "every term must match some field")
        XCTAssertFalse(SidebarFilter.matches(b, query: "research gpt"))
        XCTAssertFalse(SidebarFilter.matches(b, query: "planner"))
    }

    func testRoomMatchesNameAndMembers() {
        let r = room("hba-1", name: "Launch plan", members: [("alpha", "Alpha One"), ("beta", nil)])
        XCTAssertTrue(SidebarFilter.matches(r, query: "launch"))
        XCTAssertTrue(SidebarFilter.matches(r, query: "@beta"))
        XCTAssertTrue(SidebarFilter.matches(r, query: "alpha one"))
        XCTAssertFalse(SidebarFilter.matches(r, query: "gamma"))
    }

    func testBoardMatchesNameAndSlug() {
        let b = KanbanSidebarRow(slug: "ops-board", name: "Operations", running: 0, blocked: 0, total: 3)
        XCTAssertTrue(SidebarFilter.matches(b, query: "operat"))
        XCTAssertTrue(SidebarFilter.matches(b, query: "ops-"))
        XCTAssertFalse(SidebarFilter.matches(b, query: "design"))
    }

    // MARK: A2 roster

    func testPinnedFirstInServerOrderHiddenCollapsedAtBottom() {
        let bots = ["a", "b", "c", "d", "e"].map { bot($0) }
        let meta: [String: BotUIMeta] = ["c": .init(pinned: true), "e": .init(pinned: true), "b": .init(hidden: true),
                                         "d": .init(pinned: true, hidden: true)]
        let r = BotRoster(bots: bots, meta: meta, query: "", hiddenExpanded: false)
        XCTAssertEqual(r.visible.map(\.name), ["c", "e", "a"])
        // Hidden rows keep the roster order too (Desktop sorts before it splits): the pinned hidden bot first.
        XCTAssertEqual(r.hidden.map(\.name), ["d", "b"])
        XCTAssertEqual(r.hiddenTotal, 2)
        XCTAssertTrue(r.showHiddenSection)
        XCTAssertFalse(r.showHiddenRows)
        XCTAssertEqual(r.rows.map(\.name), ["c", "e", "a"], "collapsed hidden rows are not walked by the arrow keys")
        let open = BotRoster(bots: bots, meta: meta, query: "", hiddenExpanded: true)
        XCTAssertEqual(open.rows.map(\.name), ["c", "e", "a", "d", "b"])
    }

    func testNoHiddenSectionWithoutHiddenBots() {
        let r = BotRoster(bots: [bot("a")], meta: [:], query: "", hiddenExpanded: true)
        XCTAssertFalse(r.showHiddenSection)
        XCTAssertFalse(r.showHiddenRows)
    }

    func testFilterRevealsMatchingHiddenBotsAndHidesSectionWhenNoneMatch() {
        let bots = [bot("alpha"), bot("beta"), bot("alpine")]
        let meta: [String: BotUIMeta] = ["alpine": .init(hidden: true)]
        let r = BotRoster(bots: bots, meta: meta, query: "alp", hiddenExpanded: false)
        XCTAssertEqual(r.visible.map(\.name), ["alpha"])
        XCTAssertEqual(r.hidden.map(\.name), ["alpine"])
        XCTAssertTrue(r.showHiddenRows, "a filter shows matching hidden bots without expanding")
        XCTAssertEqual(r.hiddenTotal, 1)
        let none = BotRoster(bots: bots, meta: meta, query: "beta", hiddenExpanded: true)
        XCTAssertFalse(none.showHiddenSection)
        XCTAssertEqual(none.rows.map(\.name), ["beta"])
    }

    // MARK: A1 menu

    func testMenuItemsFollowState() {
        XCTAssertEqual(BotRowMenu.items(BotUIMeta()), [.open, .openRecent, .pin, .hide, .moveToSection, .copyHandle])
        XCTAssertEqual(BotRowMenu.items(BotUIMeta(pinned: true, hidden: true)),
                       [.open, .openRecent, .unpin, .unhide, .moveToSection, .copyHandle])
        XCTAssertEqual(BotRowMenu.handle(bot("research-buddy", title: "Research")), "@research-buddy")
        XCTAssertEqual(BotRowMenu.title(.pin), "Pin to Top")
        XCTAssertEqual(BotRowMenu.title(.unhide), "Unhide Bot")
    }

    // MARK: A2 model

    private final class Saves: @unchecked Sendable {
        let lock = NSLock()
        var patches: [(String, [String: JSONValue])] = []
        var outcome: BotMetaSync.Outcome = .persisted(BotUIMeta(pinned: true))
        var error: Error?
    }

    private func model(_ saves: Saves, bots: [Bot]) -> BotMetaModel {
        let m = BotMetaModel()
        m.log = { _ in }
        m.load(bots)
        m.saver = { name, patch in
            try saves.lock.withLock {
                saves.patches.append((name, patch))
                if let e = saves.error { throw e }
                return saves.outcome
            }
        }
        return m
    }

    private func settle(_ m: BotMetaModel, _ name: String) async throws {
        let end = Date().addingTimeInterval(5)
        while m.isSaving(name) {
            if Date() > end { return XCTFail("save did not finish") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testLoadSeedsFromRosterUiMeta() {
        let pinned = Bot(["name": "p", "ui_meta": ["hermes-bots": ["pinned": true]]])!
        let m = model(Saves(), bots: [pinned, bot("q")])
        XCTAssertTrue(m["p"].pinned)
        XCTAssertFalse(m["q"].pinned)
    }

    func testPinIsOptimisticThenKeepsTheSavedValue() async throws {
        let saves = Saves()
        let m = model(saves, bots: [bot("p")])
        m.setPinned("p", true)
        XCTAssertTrue(m["p"].pinned, "the row moves at once")
        XCTAssertTrue(m.isSaving("p"))
        try await settle(m, "p")
        XCTAssertTrue(m["p"].pinned)
        XCTAssertNil(m.lastError)
        XCTAssertEqual(saves.patches.map(\.0), ["p"])
        XCTAssertEqual(saves.patches.first?.1, ["pinned": true])
    }

    func testFailedOrUnsupportedSaveRollsBackWithAReason() async throws {
        for outcome in [BotMetaSync.Outcome.failed, .unsupported, .notFound] {
            let saves = Saves()
            saves.outcome = outcome
            let m = model(saves, bots: [bot("p")])
            m.setHidden("p", true)
            XCTAssertTrue(m["p"].hidden)
            try await settle(m, "p")
            XCTAssertFalse(m["p"].hidden, "\(outcome) rolls back")
            XCTAssertNotNil(m.lastError)
        }
        let saves = Saves()
        saves.error = GatewayClient.ClientError.notConnected
        let m = model(saves, bots: [bot("p")])
        m.setHidden("p", true)
        try await settle(m, "p")
        XCTAssertFalse(m["p"].hidden)
        XCTAssertNotNil(m.lastError)
    }

    func testNoSaveForUnknownBotNoOpChangeOrWhileOneIsInFlight() async throws {
        let saves = Saves()
        let m = model(saves, bots: [bot("p")])
        m.setPinned("ghost", true)
        m.setPinned("p", false)  // already unpinned
        m.setPinned("p", true)
        m.setHidden("p", true)  // refused: a save for p is in flight
        try await settle(m, "p")
        XCTAssertEqual(saves.patches.count, 1)
        XCTAssertFalse(m["p"].hidden)
    }

    func testNoSaverMeansNoChange() {
        let m = BotMetaModel()
        m.log = { _ in }
        m.load([bot("p")])
        m.setPinned("p", true)
        XCTAssertFalse(m["p"].pinned)
    }

    func testAReloadDropsTheAnswerOfAnOldConnection() async throws {
        let saves = Saves()
        saves.outcome = .failed
        let m = model(saves, bots: [bot("p")])
        m.setPinned("p", true)
        m.load([Bot(["name": "p", "ui_meta": ["hermes-bots": ["pinned": true]]])!])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(m["p"].pinned, "the new roster's value stands")
        XCTAssertNil(m.lastError)
    }
}
