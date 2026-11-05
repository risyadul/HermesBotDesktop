import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D1 / D2 wiring with a recording poster (never the system notification centre) and a fake room source:
/// room attention folding, the room watcher fed by the sidebar digest passes, Bot Chat requests and replies,
/// withdrawals and the Dock badge.
@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    final class RecordingPoster: NotificationPosting {
        var posted: [NotificationContent] = []
        var removed: [String] = []
        func post(_ content: NotificationContent) { posted.append(content) }
        func remove(ids: [String]) { removed += ids }
    }

    private let room = RoomSummary(["room_id": "hba-1", "name": "Launch",
                                    "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Alpha"]]])!

    private func user(_ seq: Int, _ id: String) -> RoomEvent {
        RoomEvent(seq: seq, eventId: id, kind: "message.user", payload: ["text": "go", "thread_id": "main"])
    }

    private func member(_ seq: Int, _ discussion: String, _ text: String) -> RoomEvent {
        RoomEvent(seq: seq, eventId: "m\(seq)", kind: "message.member", actor: ["kind": "member", "id": "alpha"],
                  payload: ["text": .string(text), "member_id": "alpha", "discussion_event_id": .string(discussion)])
    }

    private func settled(_ seq: Int, _ discussion: String, status: String = "settled") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "a\(seq)", kind: "room.activity",
                  payload: ["status": .string(status), "discussion_event_id": .string(discussion)])
    }

    private func driver(_ approvals: [RoomApproval]) -> RoomDriverStatus {
        RoomDriverStatus(working: true, blocked: true, pendingActions: approvals.map { .approval($0) })
    }

    private func approval(_ id: String) -> RoomApproval {
        RoomApproval(memberId: "alpha", taskId: "t", executionGeneration: 1, requestId: id, choices: ["once", "deny"],
                     command: "ls", description: nil)
    }

    private func coordinator(active: Bool = false, enabled: Bool = true) -> (NotificationCoordinator, RecordingPoster, () -> [String?]) {
        let poster = RecordingPoster()
        let c = NotificationCoordinator(poster: poster)
        c.appActive = { active }
        c.enabled = { enabled }
        var badges: [String?] = []
        c.setBadge = { badges.append($0) }
        return (c, poster, { badges })
    }

    // MARK: RoomAttention

    func testBaselineNeverSignalsButRemembersAnOpenMention() {
        var a = RoomAttention()
        let first = a.apply(events: [user(1, "u1"), member(2, "d1", "@user done?"), settled(3, "d1"),
                                     user(4, "u2"), member(5, "d2", "@user pick one")], room: room)
        XCTAssertTrue(first.isEmpty, "history is never announced")
        XCTAssertEqual(a.cursor, 5)
        let later = a.apply(events: [settled(6, "d2")], room: room)
        XCTAssertEqual(later, [RoomAttention.Mention(discussion: "d2", author: "Alpha", text: "@user pick one")])
        XCTAssertTrue(a.apply(events: [settled(6, "d2"), settled(7, "d2")], room: room).isEmpty, "once per discussion; duplicates skipped")
    }

    func testOnlySettledOrBoundedDiscussionsWithUserMentionSignal() {
        var a = RoomAttention()
        a.baseline(through: 0)
        XCTAssertTrue(a.apply(events: [member(1, "d1", "all done"), settled(2, "d1")], room: room).isEmpty)
        XCTAssertTrue(a.apply(events: [member(3, "d2", "@user ok?"),
                                       RoomEvent(seq: 4, eventId: "x", kind: "room.activity",
                                                 payload: ["status": "working", "discussion_event_id": "d2"])], room: room).isEmpty)
        XCTAssertEqual(a.apply(events: [settled(5, "d2", status: "bounded")], room: room).map(\.discussion), ["d2"])
    }

    func testApprovalsDiffNewAndGone() {
        var a = RoomAttention()
        var d = a.apply(driver: driver([approval("r1")]))
        XCTAssertEqual(d.new.map(\.requestId), ["r1"])
        d = a.apply(driver: driver([approval("r1"), approval("r2")]))
        XCTAssertEqual(d.new.map(\.requestId), ["r2"])
        XCTAssertTrue(d.gone.isEmpty)
        d = a.apply(driver: nil)
        XCTAssertEqual(d.gone.map(\.requestId), ["r1", "r2"])
        XCTAssertTrue(a.approvals.isEmpty)
    }

    // MARK: coordinator + rooms

    func testRoomApprovalNotifiesBadgesAndWithdrawsWhenAnswered() {
        let (c, poster, badges) = coordinator()
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [user(1, "u1")], driver: driver([approval("r1")]), latestSeq: 1)
        XCTAssertEqual(poster.posted.map(\.id), [NotificationContent.roomApprovalId(room: "hba-1", approval: approval("r1"))])
        XCTAssertEqual(poster.posted.first?.category, .approval)
        XCTAssertEqual(c.badgeCount, 1)
        XCTAssertEqual(badges(), ["1"])
        c.rooms.ingest(room: room, events: [], driver: driver([approval("r1")]))
        XCTAssertEqual(poster.posted.count, 1, "the same approval is announced once")
        c.rooms.ingest(room: room, events: [], driver: RoomDriverStatus(working: false))
        XCTAssertEqual(poster.removed, [NotificationContent.roomApprovalId(room: "hba-1", approval: approval("r1"))])
        XCTAssertEqual(badges(), ["1", nil])
        XCTAssertNil(c.rooms.approval(room: "hba-1", member: "alpha", request: "r1"))
    }

    func testRoomMentionNotifiesOnSettle() {
        let (c, poster, _) = coordinator()
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [user(1, "u1")], driver: nil, latestSeq: 1)
        c.rooms.ingest(room: room, events: [member(2, "d1", "Blocked — @user which account?")], driver: nil)
        XCTAssertTrue(poster.posted.isEmpty, "not until the round settles")
        c.rooms.ingest(room: room, events: [settled(3, "d1")], driver: nil)
        XCTAssertEqual(poster.posted.map(\.title), ["Alpha needs you in Launch"])
    }

    func testForegroundOrDisabledPostsNothingButStillBadges() {
        for (active, enabled) in [(true, true), (false, false)] {
            let (c, poster, badges) = coordinator(active: active, enabled: enabled)
            c.rooms.setRooms([room])
            c.rooms.ingest(room: room, events: [], driver: driver([approval("r1")]), latestSeq: 0)
            XCTAssertTrue(poster.posted.isEmpty)
            XCTAssertEqual(badges(), ["1"])
        }
    }

    func testUnlistedRoomIsIgnoredAndDroppedRoomClearsItsApprovals() {
        let (c, poster, badges) = coordinator()
        c.rooms.ingest(room: room, events: [], driver: driver([approval("r1")]), latestSeq: 0)
        XCTAssertTrue(poster.posted.isEmpty)
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [], driver: driver([approval("r1")]), latestSeq: 0)
        XCTAssertEqual(c.badgeCount, 1)
        c.rooms.setRooms([])
        XCTAssertEqual(c.badgeCount, 0)
        XCTAssertEqual(badges(), ["1", nil])
        XCTAssertEqual(poster.removed.count, 1)
    }

    /// One background poller (live UI test 2026-11-06, round 2): the sidebar's `RoomDigestHub` passes feed the
    /// watcher, which no longer reads `groups.state` / `groups.log` itself. Same semantics as its own poll had:
    /// the baseline reads a recent window only and never signals, then the cursor is followed, approvals and
    /// settled `@user` discussions notify, and nothing is read while `latest_seq` has not moved.
    func testDigestPassesFeedTheWatcherFromARecentWindowThenTheCursor() async {
        let (c, poster, _) = coordinator()
        let suite = "hba-attention-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = RoomDigestHub(defaults: defaults)
        hub.attention = c.rooms
        func listed(_ latest: Int) -> RoomSummary {
            RoomSummary(["room_id": "hba-1", "name": "Launch", "latest_seq": .number(Double(latest)),
                         "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Alpha"]]])!
        }
        var events = (1...250).map { user($0, "u\($0)") }
        events.append(member(251, "d9", "@user approve the plan?"))
        let api = FakeRoomActions(rooms: [listed(251)])
        api.setEvents("hba-1", events)
        c.rooms.setRooms([room])

        await hub.refresh(with: api)
        XCTAssertEqual(api.logRequests.first?.since, 251 - RoomAttentionWatcher.baselineWindow, "baseline reads a recent window only")
        XCTAssertEqual(c.rooms.states["hba-1"]?.cursor, 251)
        XCTAssertTrue(poster.posted.isEmpty, "history is never announced")

        // The discussion is still running: the pass checks the room's approvals without reading its log.
        api.setDriver("hba-1", driver([approval("r7")]))
        let reads = api.logRequests.count
        await hub.refresh(with: api)
        XCTAssertEqual(api.logRequests.count, reads, "no log read while latest_seq has not moved")
        XCTAssertEqual(poster.posted.map(\.title), ["Alpha needs your approval"])
        XCTAssertEqual(c.badgeCount, 1)

        api.setEvents("hba-1", events + [settled(252, "d9")])
        api.setRooms([listed(252)])
        await hub.refresh(with: api)
        XCTAssertEqual(api.logRequests.last?.since, 251, "follows the cursor")
        XCTAssertEqual(poster.posted.map(\.title), ["Alpha needs your approval", "Alpha needs you in Launch"])
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("state:") }.count, 3, "groups.state once per pass for the unsettled room")
    }

    func testApprovalsWithdrawWhenTheRoomSettlesAndStayWhenUnchecked() async {
        let (c, poster, _) = coordinator()
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [user(1, "u1")], driver: driver([approval("r1")]), latestSeq: 1)
        XCTAssertEqual(c.badgeCount, 1)
        c.rooms.ingest(room: room, events: [], driver: nil, approvalsKnown: false)
        XCTAssertEqual(c.badgeCount, 1, "a pass that did not read groups.state leaves the approval")
        XCTAssertTrue(poster.removed.isEmpty)

        // A settled room (no unsettled discussion): the hub reports no approvals, the notification goes.
        let suite = "hba-attention-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = RoomDigestHub(defaults: defaults)
        hub.attention = c.rooms
        let api = FakeRoomActions(rooms: [RoomSummary(["room_id": "hba-1", "name": "Launch", "latest_seq": 2,
                                                       "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha"]]])!])
        api.setEvents("hba-1", [user(1, "u1"), settled(2, "u1")])
        await hub.refresh(with: api)
        XCTAssertFalse(api.calls.contains("state:hba-1"), "a settled room is not asked")
        XCTAssertEqual(c.badgeCount, 0)
        XCTAssertEqual(poster.removed, [NotificationContent.roomApprovalId(room: "hba-1", approval: approval("r1"))])
    }

    func testTheAppHasOneRoomPoller() {
        let app = AppModel()
        app.notifications.setBadge = { _ in }
        XCTAssertTrue(app.roomDigests.attention === app.notifications.rooms, "the digest passes feed the notification watcher")
    }

    // MARK: coordinator + Bot Chat

    private func chat(_ name: String = "alpha", title: String = "Alpha") -> ChatModel {
        let bot = Bot(["name": .string(name), "display_name": .string(title)])!
        let m = ChatModel(bot: bot, opener: { _ in throw GatewayClient.ClientError.notConnected })
        m.log = { _ in }
        return m
    }

    func testChatRequestNotifiesOnceBadgesAndIsWithdrawnWhenAnswered() {
        let (c, poster, badges) = coordinator()
        let m = chat()
        c.track(m)
        let r = NotificationPolicyTests.approvalRequest()
        m.receive(r)
        m.receive(r)
        XCTAssertEqual(poster.posted.map(\.id), [NotificationContent.requestId(bot: "alpha", request: r.id)])
        XCTAssertEqual(c.badgeCount, 1)
        m.dropRequests { _ in true }
        XCTAssertEqual(poster.removed, [NotificationContent.requestId(bot: "alpha", request: r.id)])
        XCTAssertEqual(badges(), ["1", nil])
    }

    func testBadgeSumsChatsAndRooms() {
        let (c, _, badges) = coordinator(active: true)
        let a = chat("a"), b = chat("b")
        c.track(a); c.track(b)
        a.receive(NotificationPolicyTests.approvalRequest(id: "1"))
        b.receive(ServerRequest(wireId: "2", method: "clarify", params: ["questions": [["qid": "q", "question": "?"]]]))
        c.rooms.setRooms([room])
        c.rooms.ingest(room: room, events: [], driver: driver([approval("r1")]), latestSeq: 0)
        XCTAssertEqual(c.badgeCount, 3)
        XCTAssertEqual(badges().last, "3")
        c.reset()
        XCTAssertEqual(c.badgeCount, 0)
        XCTAssertEqual(badges().last, .some(nil))
    }

    func testFinishedReplyNotifiesUnlessTheBotIsHidden() {
        let (c, poster, _) = coordinator()
        let m = chat()
        m.transcript.seed(history: [ChatHistoryMessage(role: .user, text: "hi"), ChatHistoryMessage(role: .assistant, text: "All done.")])
        c.turnEvent("message.delta", m)
        XCTAssertTrue(poster.posted.isEmpty)
        c.turnEvent("message.complete", m)
        XCTAssertEqual(poster.posted.map(\.body), ["All done."])
        c.botHidden = { _ in true }
        c.turnEvent("message.complete", m)
        XCTAssertEqual(poster.posted.count, 1)
    }

    func testAppModelWithoutBundleHasNoPosterAndAnswersNothing() {
        let app = AppModel()
        app.notifications.setBadge = { _ in }
        app.handleNotification(.answerChat(bot: "ghost", requestId: "x", approve: true))
        app.handleNotification(.answerRoom(roomId: "ghost", memberId: "", requestId: "x", approve: false))
        XCTAssertNil(app.selection)
    }
}
