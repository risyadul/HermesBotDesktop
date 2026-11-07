import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A4 / A6 / A16 / A17 in the app: roster order, unread dot, needs-attention badge, the row menu's recent
/// session and the read-only session sheet's model. Headless; every backend is a fake and `UserDefaults` is a
/// throwaway suite.
@MainActor
final class BotRosterTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let name = "hba-test-roster-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func bot(_ name: String) -> Bot { Bot(.object(["name": .string(name)]))! }

    private func activity(_ last: Double, canonical: String = "c", recent: String? = nil) -> BotRosterActivity {
        BotRosterActivity(canonical: BotSessionSummary(id: canonical, lastActive: last),
                          last: recent.map { BotSessionSummary(id: $0, title: "Run", lastActive: last - 1) })
    }

    private func hub(_ d: UserDefaults) -> BotActivityHub {
        let h = BotActivityHub(defaults: d)
        h.log = { _ in }
        return h
    }

    // MARK: A4 order

    func testPinnedFirstThenNewestActivityThenServerOrder() {
        let bots = ["a", "b", "c", "d", "e"].map(bot)
        let meta: [String: BotUIMeta] = ["e": .init(pinned: true), "d": .init(created: 30_000)]
        let r = BotRoster(bots: bots, meta: meta, query: "", hiddenExpanded: false,
                          lastActive: ["b": 10, "c": 20, "e": 1])
        XCTAssertEqual(r.visible.map(\.name), ["e", "d", "c", "b", "a"],
                       "pinned, then d (created 30 s) over c (20 s) over b (10 s), a without activity last")
        let none = BotRoster(bots: bots, meta: [:], query: "", hiddenExpanded: false)
        XCTAssertEqual(none.visible.map(\.name), ["a", "b", "c", "d", "e"], "before activity is known: server order")
    }

    // MARK: A4 unread

    func testFirstSightSeedsSoOldHistoryIsNotUnread() {
        let h = hub(defaults())
        h.apply(["a": activity(100)])
        XCTAssertFalse(h.isUnread("a", onScreen: false))
        XCTAssertEqual(h.readThrough["a"], 100)
    }

    func testNewActivityIsUnreadUntilOpened() {
        let d = defaults()
        let h = hub(d)
        h.apply(["a": activity(100)])
        h.apply(["a": activity(150)])
        XCTAssertTrue(h.isUnread("a", onScreen: false))
        XCTAssertFalse(h.isUnread("a", onScreen: true), "never on the bot on screen")
        h.markRead("a")
        XCTAssertFalse(h.isUnread("a", onScreen: false))
        XCTAssertEqual((d.dictionary(forKey: BotActivityHub.readKey) as? [String: Double])?["a"], 150, "persisted")
        h.markRead("a")
        XCTAssertEqual(h.readThrough["a"], 150, "monotonic")
    }

    /// A bot created in Hermes Desktop: the activity pass lists it before the app's roster has it, and the
    /// app reloads the roster (once per differing set), so the new bot appears without reconnecting.
    func testAPassListingOtherBotsAsksForARosterRefreshOnce() {
        let h = hub(defaults())
        var roster: Set<String> = ["a"]
        var asked = 0
        h.rosterNames = { roster }
        h.onRosterChanged = { asked += 1 }
        h.apply(["a": activity(100)])
        XCTAssertEqual(asked, 0, "same names: nothing to do")
        h.apply(["a": activity(100), "new": activity(120)])
        XCTAssertEqual(asked, 1, "a bot the roster lacks")
        h.apply(["a": activity(110), "new": activity(130)])
        XCTAssertEqual(asked, 1, "still differing the same way: the refresh is already asked for")
        roster = ["a", "new"]
        h.apply(["a": activity(110), "new": activity(130)])
        h.apply(["new": activity(130)])
        XCTAssertEqual(asked, 2, "a bot deleted elsewhere refreshes too")
        h.apply([:])
        XCTAssertEqual(asked, 2, "an empty pass (no answer yet) is not a roster")
    }

    func testOnScreenBotIsMarkedReadOnEveryPass() {
        let h = hub(defaults())
        h.onScreen = { ["a"] }
        h.apply(["a": activity(100), "b": activity(100)])
        h.apply(["a": activity(200), "b": activity(200)])
        XCTAssertFalse(h.isUnread("a", onScreen: false))
        XCTAssertTrue(h.isUnread("b", onScreen: false))
    }

    func testSeenMarksSurviveRelaunchAndDeletedBotsArePruned() {
        let d = defaults()
        let h = hub(d)
        h.apply(["a": activity(100), "gone": activity(100)])
        h.apply(["a": activity(100)])
        let relaunched = hub(d)
        XCTAssertEqual(relaunched.readThrough, ["a": 100])
        relaunched.apply(["a": activity(130)])
        XCTAssertTrue(relaunched.isUnread("a", onScreen: false), "activity while the app was closed is unread")
    }

    func testRefreshAppliesAFakeFetchAndKeepsRowsOnFailure() async {
        let h = hub(defaults())
        await h.refresh({ ["a": BotRosterActivity(last: BotSessionSummary(id: "s", lastActive: 5))] })
        XCTAssertEqual(h.lastActive("a"), 5)
        await h.refresh({ throw GatewayClient.ClientError.notConnected })
        XCTAssertEqual(h.lastActive("a"), 5)
        h.stop()
        XCTAssertTrue(h.activity.isEmpty)
    }

    func testChatBadgePrefersRequestsThenReplyingThenUnread() {
        XCTAssertEqual(BotChatBadge.kind(requests: 2, busy: true, unread: true), .waiting(2))
        XCTAssertEqual(BotChatBadge.kind(requests: 0, busy: true, unread: true), .replying)
        XCTAssertEqual(BotChatBadge.kind(requests: 0, busy: false, unread: true), .unread)
        XCTAssertEqual(BotChatBadge.kind(requests: 0, busy: false), .none)
        XCTAssertEqual(BotRowText.preview(BotPreview(text: "hi", fromBot: "scout")), "@scout: hi")
        XCTAssertEqual(BotRowText.preview(BotPreview(text: "hi")), "hi")
    }

    // MARK: A6 attention

    func testBotChatTurnsSetAndClearTheBadge() {
        let h = hub(defaults())
        let failed = [ChatLine(role: .user, text: "hi"), ChatLine(role: .error, text: "HTTP 401 Unauthorized")]
        h.turnEvent("turn.failed", bot: "a", lines: failed)
        XCTAssertEqual(h.attention["a"]?.reason, .providerAuth)
        h.turnEvent("turn.failed", bot: "a", lines: [ChatLine(role: .error, text: "rate limit exceeded")])
        XCTAssertEqual(h.attention["a"]?.reason, .providerAuth, "a transient failure leaves the badge as it was")
        h.turnEvent("message.complete", bot: "a", lines: failed + [ChatLine(role: .bot, text: "ok")])
        XCTAssertNil(h.attention["a"], "a good turn clears it")
        h.turnEvent("message.complete", bot: "a", lines: [ChatLine(role: .error, text: "insufficient credits")])
        XCTAssertEqual(h.attention["a"]?.reason, .quota)
        h.turnEvent("message.delta", bot: "a", lines: [])
        XCTAssertEqual(h.attention["a"]?.reason, .quota)
    }

    func testGroupChatMemberFailuresUseTheReasonCode() {
        let h = hub(defaults())
        let room = RoomSummary(["room_id": "r", "name": "R", "members": [["member_id": "m1", "profile": "alpha", "handle": "alpha"]]])!
        h.ingest(room: room, events: [
            RoomEvent(seq: 1, eventId: "e1", kind: "turn.failed", payload: ["member_id": "m1", "error": "boom", "reason_code": "missing_config"]),
            RoomEvent(seq: 2, eventId: "e2", kind: "turn.failed", payload: ["member_id": "ghost", "error": "401"]),
        ])
        XCTAssertEqual(h.attention["alpha"]?.reason, .missingConfig)
        XCTAssertEqual(h.attention.count, 1, "an unknown member badges nobody")
        h.ingest(room: room, events: [RoomEvent(seq: 3, eventId: "e3", kind: "turn.settled", payload: ["member_id": "m1"])])
        XCTAssertNil(h.attention["alpha"])
    }

    func testAttentionIsDroppedForBotsNoLongerListed() {
        let h = hub(defaults())
        h.noteFailure("a", message: "403 forbidden")
        h.apply(["b": activity(1)])
        XCTAssertNil(h.attention["a"])
    }

    // MARK: A17

    func testRecentSessionMenuItemOnlyWithANonBotChatSession() {
        XCTAssertNotNil(activity(10, recent: "s1").recentSession)
        XCTAssertNil(activity(10).recentSession)
        XCTAssertEqual(BotRowMenu.title(.openRecent), "Open Recent Session")
    }

    func testRecentSessionModelLoadsReadOnlyHistory() async {
        let session = BotSessionSummary(id: "s1", title: "", lastActive: 10)
        let asked = Asked()
        let m = RecentSessionModel(bot: bot("alpha"), session: session) { id, profile in
            asked.set(id, profile)
            return [ChatHistoryMessage(role: .user, text: "run it"), ChatHistoryMessage(role: .assistant, text: "done", reasoning: "think")]
        }
        XCTAssertEqual(m.phase, .loading)
        await m.load()
        XCTAssertEqual(asked.value?.0, "s1")
        XCTAssertEqual(asked.value?.1, "alpha")
        guard case .loaded(let lines) = m.phase else { return XCTFail("not loaded") }
        XCTAssertEqual(lines.map(\.role), [.user, .thought, .bot])
        XCTAssertEqual(RecentSessionModel.title(session), "Untitled session")
        XCTAssertEqual(RecentSessionModel.title(BotSessionSummary(id: "x", title: " Daily ")), "Daily")
    }

    func testRecentSessionModelSaysWhyItFailed() async {
        let m = RecentSessionModel(bot: bot("alpha"), session: BotSessionSummary(id: "s1")) { _, _ in
            throw SessionTranscriptREST.Failure.notFound
        }
        await m.load()
        XCTAssertEqual(m.phase, .failed("Hermes no longer has this session."))
    }

    // MARK: A16

    func testEmptyBotChatHintAndLargeFace() {
        XCTAssertEqual(BotChatView.emptyHint, "Say something to get started.")
        XCTAssertEqual(DS.Size.avatarChatEmpty, 96)
        XCTAssertLessThanOrEqual(DS.Size.recentSessionSheet.height, DS.Size.windowMinHeight - DS.Space.s6,
                                 "the read-only session sheet fits the minimum window")
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (String, String)?
    func set(_ a: String, _ b: String) { lock.withLock { stored = (a, b) } }
    var value: (String, String)? { lock.withLock { stored } }
}
