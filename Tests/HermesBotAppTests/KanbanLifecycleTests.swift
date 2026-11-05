import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Board lifecycle edges: a board deleted or archived while open (`.gone`), pruning of unlisted boards and the
/// selection, polling paused while no window is on screen, follow-up fetches only while polling. Headless,
/// against `FakeKanbanService`.
@MainActor
final class KanbanLifecycleTests: XCTestCase {
    private static let hour: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    private static let fast: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 10_000_000) }

    private func fake() -> FakeKanbanService {
        let api = FakeKanbanService(columns: [
            ("todo", [FakeKanbanService.task("t_1", "Write the spec", status: "todo", priority: 1)]),
            ("ready", []),
            ("done", []),
        ])
        api.with { $0.boards = [FakeKanbanService.summary("main"), FakeKanbanService.summary("side")] }
        return api
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: board gone (M1)

    func testGoneDetailIsRecognised() {
        XCTAssertTrue(KanbanBoardModel.isBoardGone(PluginREST.Failure.http(status: 404, detail: "board 'old' does not exist")))
        XCTAssertTrue(KanbanBoardModel.isBoardGone(PluginREST.Failure.http(status: 404, detail: "board 'old' is archived")))
        XCTAssertFalse(KanbanBoardModel.isBoardGone(PluginREST.Failure.http(status: 404, detail: "task t_9 not found")))
        XCTAssertFalse(KanbanBoardModel.isBoardGone(PluginREST.Failure.http(status: 400, detail: "board 'x' does not exist")))
        XCTAssertFalse(KanbanBoardModel.isBoardGone(PluginREST.Failure.pluginUnavailable(plugin: "kanban")))
        XCTAssertEqual(KanbanBoardModel.describe(PluginREST.Failure.http(status: 404, detail: "board 'old' is archived")),
                       KanbanBoardModel.goneMessage)
    }

    func testBoardDeletedWhileOpenStopsPollingAndRefusesActions() async throws {
        let api = fake()
        let m = KanbanBoardModel(slug: "main", api: api, sleep: Self.fast)
        m.start()
        try await waitUntil { m.state == .ready }
        api.with { $0.boardError = PluginREST.Failure.http(status: 404, detail: "board 'main' does not exist") }
        try await waitUntil { m.state == .gone }
        XCTAssertFalse(m.isPolling, "no retry loop against a deleted board")
        let polls = api.count("board")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(api.count("board"), polls, "polling really stopped")

        let moved = await m.move("t_1", to: "ready")
        XCTAssertFalse(moved)
        XCTAssertEqual(m.error, "Move “Write the spec” to Ready failed: \(KanbanBoardModel.goneMessage)")
        XCTAssertEqual(api.count("move"), 0, "nothing sent")
        let created = await m.create(KanbanTaskDraft(title: "x"), column: nil)
        XCTAssertEqual(created, KanbanBoardModel.goneMessage)

        m.stop()
        m.start()  // the view reappearing (or a resume) does not revive it
        XCTAssertFalse(m.isPolling)
        XCTAssertEqual(m.state, .gone)
    }

    func testAnActionAnsweringBoardArchivedMarksItGone() async {
        let api = fake()
        let m = KanbanBoardModel(slug: "main", api: api, sleep: Self.hour)
        await m.refresh()
        api.with { $0.actionError = PluginREST.Failure.http(status: 404, detail: "board 'main' is archived") }
        let ok = await m.move("t_1", to: "ready")
        XCTAssertFalse(ok)
        XCTAssertEqual(m.state, .gone)
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testGoToAnotherBoardPicksAListedOne() {
        let rows = KanbanHub.sidebarRows([])
        XCTAssertNil(KanbanBoardView.otherBoard(rows, current: "main"))
        let two = [KanbanSidebarRow(slug: "main", name: "Main", running: 0, blocked: 0, total: 0),
                   KanbanSidebarRow(slug: "side", name: "Side", running: 0, blocked: 0, total: 0)]
        XCTAssertEqual(KanbanBoardView.otherBoard(two, current: "main"), "side")
        XCTAssertNil(KanbanBoardView.otherBoard(Array(two.prefix(1)), current: "main"))
    }

    func testRefreshBoardsPrunesUnlistedModelsAndReportsTheList() async throws {
        let api = fake()
        let hub = KanbanHub(sleep: Self.hour)
        var reported: [Set<String>] = []
        hub.onBoardsListed = { reported.append($0) }
        hub.connect(api: api)
        try await waitUntil { hub.availability == .available }
        let side = try XCTUnwrap(hub.model(for: "side"))
        side.start()
        XCTAssertTrue(side.isPolling)

        api.with { $0.boards = [FakeKanbanService.summary("main"), FakeKanbanService.summary("side", archived: true)] }
        await hub.refreshBoards()
        XCTAssertEqual(reported.last, ["main"])
        XCTAssertFalse(side.isPolling, "the pruned model stopped")
        XCTAssertFalse(hub.model(for: "side") === side, "and left the cache")

        api.with { $0.boardsError = PluginREST.Failure.transport("down") }
        let before = reported.count
        await hub.refreshBoards()
        XCTAssertEqual(reported.count, before, "a failed list prunes nothing")
        hub.disconnect()
    }

    func testAppModelClearsASelectionWhoseBoardIsGone() {
        let app = AppModel()
        app.selection = .board("old")
        app.boardsListed(["main"])
        XCTAssertNil(app.selection)
        app.selection = .board("main")
        app.boardsListed(["main"])
        XCTAssertEqual(app.selection, .board("main"))
        app.selection = .bot("alice")
        app.boardsListed([])
        XCTAssertEqual(app.selection, .bot("alice"), "only a board selection is touched")
    }

    // MARK: follow-up fetch only while polling (L4)

    func testActionsRefreshOnlyWhilePolling() async throws {
        let api = fake()
        let m = KanbanBoardModel(slug: "main", api: api, sleep: Self.hour)
        m.start()
        try await waitUntil { api.count("board") == 1 }
        _ = await m.move("t_1", to: "ready")
        try await waitUntil { api.count("board") == 2 }  // the follow-up fetch
        m.stop()
        _ = await m.move("t_1", to: "todo")
        _ = await m.create(KanbanTaskDraft(title: "Another"), column: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.count("board"), 2, "stopped: no Task fetches the board after an action")
    }

    // MARK: pause while hidden (M5)

    func testOnScreenRule() {
        XCTAssertTrue(KanbanHub.onScreen(appHidden: false, windows: [(true, true, false, true)]))
        XCTAssertFalse(KanbanHub.onScreen(appHidden: true, windows: [(true, true, false, true)]), "app hidden")
        XCTAssertFalse(KanbanHub.onScreen(appHidden: false, windows: [(true, true, true, false)]), "minimised")
        XCTAssertFalse(KanbanHub.onScreen(appHidden: false, windows: [(true, true, false, false)]), "fully covered")
        XCTAssertFalse(KanbanHub.onScreen(appHidden: false, windows: [(true, false, false, true)]), "closed")
        XCTAssertFalse(KanbanHub.onScreen(appHidden: false, windows: []))
        XCTAssertTrue(KanbanHub.onScreen(appHidden: false, windows: [(true, true, true, false), (true, true, false, true)]))
        XCTAssertFalse(KanbanHub.onScreen(appHidden: false, windows: [(true, true, true, false), (false, true, false, true)]),
                       "only Settings on screen (the main window minimised): paused")
    }

    func testInactiveHubPausesTheListBoardsAndDispatcherAndResumes() async throws {
        let api = fake()
        let hub = KanbanHub(sleep: Self.fast)
        hub.connect(api: api)
        try await waitUntil { hub.availability == .available }
        let board = try XCTUnwrap(hub.model(for: "main"))
        board.start()
        hub.watchDispatcher(true)
        XCTAssertTrue(hub.isPolling && board.isPolling && hub.isWatchingDispatcher)

        hub.setActive(false)
        XCTAssertFalse(hub.isPolling, "board list paused")
        XCTAssertFalse(board.isPolling, "board paused")
        XCTAssertTrue(board.wantsPolling, "but still wanted")
        XCTAssertFalse(hub.isWatchingDispatcher, "dispatcher paused")
        try await Task.sleep(nanoseconds: 40_000_000)  // let in-flight fetches land
        let (lists, polls) = (api.count("boards"), api.count("board"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(api.count("boards"), lists, "no board list fetch while hidden")
        XCTAssertEqual(api.count("board"), polls, "no board fetch while hidden")

        let created = try XCTUnwrap(hub.model(for: "side"))
        created.start()
        XCTAssertFalse(created.isPolling, "a board opened while hidden waits too")

        hub.setActive(true)
        XCTAssertTrue(hub.isPolling && board.isPolling && created.isPolling && hub.isWatchingDispatcher)
        try await waitUntil { api.count("boards") > lists && api.count("board") > polls }

        board.stop()
        hub.setActive(false)
        hub.setActive(true)
        XCTAssertFalse(board.isPolling, "a board the view stopped does not come back on resume")
        hub.watchDispatcher(false)
        XCTAssertFalse(hub.isWatchingDispatcher, "no board on screen: no dispatcher polling")
        hub.disconnect()
    }

    func testDispatcherPollingFollowsBoardViews() async throws {
        let hub = KanbanHub(sleep: Self.hour)
        XCTAssertFalse(hub.isWatchingDispatcher)
        hub.watchDispatcher(true)
        hub.watchDispatcher(true)
        hub.watchDispatcher(false)
        XCTAssertTrue(hub.isWatchingDispatcher, "one board view still on screen")
        hub.watchDispatcher(false)
        hub.watchDispatcher(false)  // unbalanced extra: stays at zero
        XCTAssertFalse(hub.isWatchingDispatcher)
        hub.watchDispatcher(true)
        XCTAssertTrue(hub.isWatchingDispatcher)
        hub.watchDispatcher(false)
    }
}
