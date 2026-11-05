import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K9: Create Task from Message seeds and the compose request, watched cards (persistence, the watcher's
/// baseline / done / blocked rules, its polling loop), the card notification and its route, and Open Bot Chat.
/// FakeKanbanService and a recording poster only; never a live backend or the system notification centre.
@MainActor
final class KanbanIntegrationTests: XCTestCase {
    private static let hour: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "hba-kanban-watch-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func board(_ tasks: [JSONValue]) throws -> KanbanBoard {
        let lanes = ["triage", "todo", "ready", "running", "blocked", "done"]
        return try KanbanBoard(json: ["columns": .array(lanes.map { lane in
            ["name": .string(lane), "tasks": .array(tasks.filter { $0["status"]?.string == lane })]
        })])
    }

    // MARK: seeds

    func testSeedTitleIsTheFirstLineCleaned() {
        let seed = KanbanTaskSeed(text: "\n\n## Ship the **beta** build\nDetails follow", suggestedAssignee: nil, source: "")
        XCTAssertEqual(seed.title, "Ship the **beta** build")
        XCTAssertEqual(KanbanTaskSeed(text: "- item one", suggestedAssignee: nil, source: "").title, "item one")
        let long = KanbanTaskSeed(text: String(repeating: "word ", count: 40), suggestedAssignee: nil, source: "")
        XCTAssertEqual(long.title.count, KanbanTaskSeed.titleLimit)
        XCTAssertTrue(long.title.hasSuffix("…"))
        XCTAssertEqual(KanbanTaskSeed(text: "   ", suggestedAssignee: nil, source: "").title, "")
    }

    func testBotChatAndRoomSeeds() {
        let reply = KanbanTaskSeed.botChat(text: " Plan: do X \n", fromUser: false, bot: "alice", botTitle: "Alice")
        XCTAssertEqual(reply, KanbanTaskSeed(text: "Plan: do X", suggestedAssignee: "alice", source: "From Alice in Bot Chat"))
        let mine = KanbanTaskSeed.botChat(text: "Do X", fromUser: true, bot: "alice", botTitle: "Alice")
        XCTAssertEqual(mine.suggestedAssignee, "alice", "the user's own message suggests the chat's bot")
        XCTAssertEqual(mine.source, "From your message to Alice")
        let member = RoomMember(memberId: "m1", profile: "bob", handle: "bobby", displayName: "Bob")
        let fromBob = KanbanTaskSeed.room(text: "Fix it", member: member, roomName: "Launch")
        XCTAssertEqual(fromBob, KanbanTaskSeed(text: "Fix it", suggestedAssignee: "bob", source: "From Bob in Launch"))
        let fromUser = KanbanTaskSeed.room(text: "Fix it", member: nil, roomName: "Launch")
        XCTAssertNil(fromUser.suggestedAssignee)
        XCTAssertEqual(fromUser.source, "From your message in Launch")
    }

    func testComposeStartsOnTheLastBoardElseTheCurrentElseTheFirst() throws {
        let boards = [try KanbanBoardSummary(json: ["slug": "a"]), try KanbanBoardSummary(json: ["slug": "b", "is_current": true]),
                      try KanbanBoardSummary(json: ["slug": "gone", "archived": true])]
        let rows = KanbanHub.sidebarRows(boards)
        XCTAssertEqual(KanbanHub.composeBoard(rows: rows, boards: boards, last: "a"), "a")
        XCTAssertEqual(KanbanHub.composeBoard(rows: rows, boards: boards, last: "gone"), "b")
        XCTAssertEqual(KanbanHub.composeBoard(rows: rows, boards: boards, last: nil), "b")
        let noCurrent = [try KanbanBoardSummary(json: ["slug": "a"]), try KanbanBoardSummary(json: ["slug": "c"])]
        XCTAssertEqual(KanbanHub.composeBoard(rows: KanbanHub.sidebarRows(noCurrent), boards: noCurrent, last: nil), "a")
        XCTAssertNil(KanbanHub.composeBoard(rows: [], boards: [], last: "a"))
    }

    func testComposeTaskFromAMessageOpensTheSheetRequest() async {
        let api = FakeKanbanService()
        api.with { $0.boards = [FakeKanbanService.summary("main"), FakeKanbanService.summary("side")] }
        let hub = KanbanHub(sleep: Self.hour)
        hub.connect(api: api)
        await hub.refreshBoards()
        _ = hub.model(for: "side")
        let seed = KanbanTaskSeed.botChat(text: "Do X", fromUser: false, bot: "alice", botTitle: "Alice")
        hub.composeTask(from: seed)
        XCTAssertEqual(hub.compose?.seed, seed)
        XCTAssertEqual(hub.compose?.board, "side")
        hub.disconnect()
        XCTAssertNil(hub.compose)
    }

    func testAppModelComposeAndOpenBotChat() {
        let app = AppModel()
        app.composeTask(from: KanbanTaskSeed(text: "x", suggestedAssignee: nil, source: ""))
        XCTAssertNotNil(app.kanban.compose)
        app.bots = [Bot(["name": "alice", "display_name": "Alice"])!]
        XCTAssertTrue(app.canOpenBotChat("alice"))
        XCTAssertFalse(app.canOpenBotChat("ghost"))
        app.openBotChat("ghost")
        XCTAssertNil(app.selection)
        app.openBotChat("alice")
        XCTAssertEqual(app.selection, .bot("alice"))
    }

    // MARK: watch list

    func testWatchListPersistsAndCaps() {
        let list = KanbanWatchList(defaults: defaults)
        XCTAssertTrue(list.isEmpty)
        list.watch("main", "t_1")
        list.watch("main", "t_1")
        list.watch("side", "t_2")
        XCTAssertEqual(list.cards["main"], ["t_1"])
        let again = KanbanWatchList(defaults: defaults)
        XCTAssertTrue(again.contains("main", "t_1"))
        XCTAssertTrue(again.contains("side", "t_2"))
        again.set("main", "t_1", watching: false)
        XCTAssertNil(again.cards["main"])
        again.forget(board: "side")
        XCTAssertTrue(KanbanWatchList(defaults: defaults).isEmpty)
        let many = KanbanWatchList(defaults: nil)
        for i in 0..<(KanbanWatchList.maxPerBoard + 5) { many.watch("b", "t_\(i)") }
        XCTAssertEqual(many.cards["b"]?.count, KanbanWatchList.maxPerBoard)
        XCTAssertFalse(many.contains("b", "t_0"), "the oldest go first")
    }

    // MARK: watcher rules

    func testFirstSightingIsABaselineThenDoneAndBlockedNotify() throws {
        let list = KanbanWatchList(defaults: nil)
        let w = KanbanCardWatcher(watches: list, sleep: Self.hour)
        w.boardName = { $0 == "main" ? "Main board" : $0 }
        list.watch("main", "t_1")
        list.watch("main", "t_2")
        let already = try board([FakeKanbanService.task("t_1", "One", status: "done"), FakeKanbanService.task("t_2", "Two", status: "running")])
        XCTAssertEqual(w.observe("main", board: already), [], "the first sighting never notifies, even of a done card")
        let blocked = try board([FakeKanbanService.task("t_1", "One", status: "done"),
                                 FakeKanbanService.task("t_2", "Two", status: "blocked", extra: ["block_kind": "needs_input"])])
        let events = w.observe("main", board: blocked)
        XCTAssertEqual(events.map(\.change), [.blocked])
        XCTAssertEqual(events.first?.boardName, "Main board")
        XCTAssertTrue(list.contains("main", "t_2"), "a blocked card stays watched")
        XCTAssertEqual(w.observe("main", board: blocked), [], "no repeat while the status holds")
        let done = try board([FakeKanbanService.task("t_1", "One", status: "done"), FakeKanbanService.task("t_2", "Two", status: "done")])
        XCTAssertEqual(w.observe("main", board: done).map { $0.task.id }, ["t_2"])
        XCTAssertFalse(list.contains("main", "t_2"), "a finished card stops being watched")
    }

    func testACreatedCardIsWatchedFromItsCreatedStatus() throws {
        let list = KanbanWatchList(defaults: nil)
        let w = KanbanCardWatcher(watches: list, sleep: Self.hour)
        w.watch("main", try KanbanTask(json: FakeKanbanService.task("t_1", "One", status: "ready")))
        let done = try board([FakeKanbanService.task("t_1", "One", status: "done")])
        XCTAssertEqual(w.observe("main", board: done).map(\.change), [.finished], "an early finish is not missed")
    }

    func testACardThatLeftTheBoardIsForgotten() throws {
        let list = KanbanWatchList(defaults: nil)
        let w = KanbanCardWatcher(watches: list, sleep: Self.hour)
        list.watch("main", "t_gone")
        XCTAssertEqual(w.observe("main", board: try board([])), [])
        XCTAssertTrue(list.isEmpty)
    }

    func testCardsCreatedThroughTheHubAreWatchedAndThePollReportsThem() async throws {
        let api = FakeKanbanService(columns: [("todo", []), ("ready", []), ("blocked", []), ("done", [])])
        api.with { $0.boards = [FakeKanbanService.summary("main")] }
        let hub = KanbanHub(sleep: Self.hour)
        var events: [KanbanCardEvent] = []
        hub.onCardEvent = { events.append($0) }
        hub.connect(api: api)
        await hub.refreshBoards()
        XCTAssertTrue(hub.cardWatcher.isRunning)
        let m = try XCTUnwrap(hub.model(for: "main"))
        await m.refresh()
        let created = await m.create(KanbanTaskDraft(title: "Watched", assignee: "alice"), column: nil)
        XCTAssertNil(created)
        let id = try XCTUnwrap(m.lanes.flatMap(\.tasks).first?.id)
        XCTAssertTrue(hub.watches.contains("main", id))
        await hub.cardWatcher.pollOnce()
        XCTAssertTrue(events.isEmpty)
        _ = try await api.move(id, to: "done", board: "main")
        await hub.cardWatcher.pollOnce()
        XCTAssertEqual(events.map(\.change), [.finished])
        XCTAssertEqual(events.first?.boardName, "Main")
        XCTAssertFalse(hub.watches.contains("main", id))
        hub.disconnect()
        XCTAssertFalse(hub.cardWatcher.isRunning)
    }

    func testAGoneBoardDropsItsWatches() async {
        let api = FakeKanbanService()
        api.with { $0.boardError = PluginREST.Failure.http(status: 404, detail: "board 'old' is archived") }
        let list = KanbanWatchList(defaults: nil)
        list.watch("old", "t_1")
        let w = KanbanCardWatcher(watches: list, sleep: Self.hour)
        w.start(api: api)
        await w.pollOnce()
        XCTAssertTrue(list.isEmpty)
        w.stop()
    }

    func testOtherPollErrorsKeepTheWatches() async {
        let api = FakeKanbanService()
        api.with { $0.boardError = PluginREST.Failure.transport("offline") }
        let list = KanbanWatchList(defaults: nil)
        list.watch("main", "t_1")
        let w = KanbanCardWatcher(watches: list, sleep: Self.hour)
        w.start(api: api)
        await w.pollOnce()
        XCTAssertTrue(list.contains("main", "t_1"))
        w.stop()
    }

    // MARK: notification

    func testNoticeContentAndRoute() throws {
        let t = try KanbanTask(json: FakeKanbanService.task("t_1", "Ship it", status: "done", assignee: "alice",
                                                             extra: ["latest_summary": "All green"]))
        let c = KanbanCardNotice.content(KanbanCardEvent(board: "main", boardName: "Main", task: t, change: .finished))
        XCTAssertEqual(c.id, "kanban.main.t_1.finished")
        XCTAssertEqual(c.title, "Done: Ship it")
        XCTAssertEqual(c.body, "Main · @alice: All green")
        XCTAssertNil(c.category)
        XCTAssertEqual(NotificationRoute.parse(action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: c.userInfo),
                       .openCard(board: "main", task: "t_1"))
        let b = try KanbanTask(json: FakeKanbanService.task("t_2", "Stuck", status: "blocked", extra: ["block_kind": "needs_input"]))
        let blocked = KanbanCardNotice.content(KanbanCardEvent(board: "main", boardName: "Main", task: b, change: .blocked))
        XCTAssertEqual(blocked.title, "Needs your input: Stuck")
        XCTAssertEqual(blocked.body, "Main")
        XCTAssertNil(KanbanCardNotice.route([NotificationRoute.targetKey: "bot:alice"]))
        XCTAssertEqual(NotificationRoute.parse(action: "x", userInfo: [NotificationRoute.targetKey: "bot:alice"]), .open(.bot("alice")),
                       "other notifications route as before")
    }

    func testCoordinatorPostsCardNoticesOnlyInTheBackgroundAndWhenEnabled() {
        let poster = NotificationCoordinatorTests.RecordingPoster()
        let c = NotificationCoordinator(poster: poster)
        var active = true, enabled = true
        c.appActive = { active }
        c.enabled = { enabled }
        let content = NotificationContent(id: "kanban.main.t_1.finished", title: "Done", body: "", category: nil, userInfo: [:])
        c.kanbanCard(content)
        XCTAssertTrue(poster.posted.isEmpty, "the app is frontmost")
        active = false
        c.kanbanCard(content)
        XCTAssertEqual(poster.posted, [content])
        enabled = false
        c.kanbanCard(content)
        XCTAssertEqual(poster.posted.count, 1)
    }

    func testOpenCardSelectsTheBoardAndTheCard() async throws {
        let app = AppModel()
        let api = FakeKanbanService(columns: [("todo", [FakeKanbanService.task("t_1", "One", status: "todo")])])
        api.with { $0.boards = [FakeKanbanService.summary("main")] }
        app.kanban.connect(api: api)
        await app.kanban.refreshBoards()
        app.openCard(board: "ghost", task: "t_1")
        XCTAssertNil(app.selection)
        app.openCard(board: "main", task: "t_1")
        XCTAssertEqual(app.selection, .board("main"))
        XCTAssertEqual(app.kanban.model(for: "main")?.selectedTaskId, "t_1")
        app.kanban.disconnect()
    }
}
