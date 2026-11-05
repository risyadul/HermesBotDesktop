import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Kanban presentation rules (filter, card flags, ages), the sidebar board list (KanbanHub), and the K8
/// dispatcher chip. Headless; the dispatcher model only ever sees a temp home with no LaunchAgent.
@MainActor
final class KanbanPresentationTests: XCTestCase {
    private func task(_ fields: [String: JSONValue]) -> KanbanTask {
        var o: [String: JSONValue] = ["id": "t_9", "title": "Fix the Login page", "status": "todo"]
        for (k, v) in fields { o[k] = v }
        return try! KanbanTask(json: .object(o))
    }

    // MARK: filter

    func testFilterMatchesTitleAssigneeAndIdAndNeedsEveryTerm() {
        let t = task(["assignee": "alice"])
        XCTAssertTrue(KanbanFilter.matches(t, query: ""))
        XCTAssertTrue(KanbanFilter.matches(t, query: "   "))
        XCTAssertTrue(KanbanFilter.matches(t, query: "login"))
        XCTAssertTrue(KanbanFilter.matches(t, query: "LOGIN fix"))
        XCTAssertTrue(KanbanFilter.matches(t, query: "alice"))
        XCTAssertTrue(KanbanFilter.matches(t, query: "@ali"))
        XCTAssertTrue(KanbanFilter.matches(t, query: "t_9"))
        XCTAssertFalse(KanbanFilter.matches(t, query: "login bob"), "every term must match")
        XCTAssertFalse(KanbanFilter.matches(t, query: "@login"), "@ matches the assignee only")
        XCTAssertFalse(KanbanFilter.matches(task([:]), query: "@alice"), "unassigned")
        let lanes = [KanbanLane(name: "todo", tasks: [t, task(["id": "t_8", "title": "Other"])]), KanbanLane(name: "done", tasks: [])]
        let filtered = KanbanFilter.apply(lanes, query: "login")
        XCTAssertEqual(filtered.map(\.name), ["todo", "done"], "lanes stay, only cards are filtered")
        XCTAssertEqual(filtered[0].tasks.map(\.id), ["t_9"])
    }

    // MARK: card flags + age

    func testCardFlagsComeFromTaskFieldsOnly() {
        let now = 1_760_000_300
        XCTAssertEqual(KanbanCardFlags(task(["status": "running", "last_heartbeat_at": .number(Double(now - 30))]), now: now).stale, false)
        let stale = KanbanCardFlags(task(["status": "running", "last_heartbeat_at": .number(Double(now - 500))]), now: now)
        XCTAssertTrue(stale.running && stale.stale)
        let input = KanbanCardFlags(task(["status": "blocked", "block_kind": "needs_input"]), now: now)
        XCTAssertTrue(input.blocked && input.needsInput)
        XCTAssertFalse(KanbanCardFlags(task(["status": "blocked", "block_kind": "dependency"]), now: now).needsInput)
        XCTAssertTrue(KanbanCardFlags(task(["status": "ready"]), now: now).wontRun)
        XCTAssertFalse(KanbanCardFlags(task(["status": "ready", "assignee": "bob"]), now: now).wontRun)
        XCTAssertEqual(KanbanCardFlags(task(["consecutive_failures": 2]), now: now).failures, 2)
    }

    func testAgesAreShortAndUseCompletionForDoneCards() {
        XCTAssertEqual(KanbanAge.short(3), "now")
        XCTAssertEqual(KanbanAge.short(42), "42s")
        XCTAssertEqual(KanbanAge.short(5 * 60), "5m")
        XCTAssertEqual(KanbanAge.short(3 * 3600 + 5), "3h")
        XCTAssertEqual(KanbanAge.short(2 * 86_400), "2d")
        XCTAssertEqual(KanbanAge.short(30 * 86_400), "4w")
        XCTAssertEqual(KanbanAge.short(-5), "now")
        let now = 1_760_100_000
        XCTAssertEqual(KanbanAge.of(task(["created_at": .number(Double(now - 7200))]), now: now), "2h")
        XCTAssertEqual(KanbanAge.of(task(["status": "done", "created_at": .number(Double(now - 7200)),
                                          "completed_at": .number(Double(now - 60))]), now: now), "1m")
        XCTAssertNil(KanbanAge.of(task([:]), now: now))
    }

    func testColumnLabelsForKnownAndCustomLanes() {
        XCTAssertEqual(KanbanColumns.label("ready"), "Ready")
        XCTAssertEqual(KanbanColumns.label("qa-custom"), "Qa Custom")
        XCTAssertNotNil(KanbanColumns.help("blocked"))
        XCTAssertNil(KanbanColumns.help("qa-custom"))
    }

    // MARK: sidebar boards

    func testSidebarRowsHideArchivedBoardsAndCountRunningAndBlocked() throws {
        let list = try KanbanBoardList(json: ["boards": [
            FakeKanbanService.summary("main", counts: ["running": 2, "blocked": 1, "todo": 4, "archived": 9]),
            FakeKanbanService.summary("old", archived: true, counts: ["running": 1]),
            FakeKanbanService.summary("side"),
        ]])
        let rows = KanbanHub.sidebarRows(list.boards)
        XCTAssertEqual(rows.map(\.slug), ["main", "side"], "archived hidden, server order kept")
        XCTAssertEqual(rows[0].running, 2)
        XCTAssertEqual(rows[0].blocked, 1)
        XCTAssertEqual(rows[0].total, 7, "total excludes archived cards")
        XCTAssertEqual(rows[1].running, 0)
        XCTAssertEqual(KanbanBoardRowContent.subtitle(rows[0]), "7 tasks")
        XCTAssertEqual(KanbanBoardRowContent.accessibilityLabel(rows[0]), "Main, 7 tasks, 2 running, 1 blocked")
    }

    func testSidebarPlaceholderPerState() {
        typealias S = KanbanHub
        XCTAssertEqual(S.sidebarPlaceholder(connected: false, availability: .unknown, rows: 0), "Not loaded yet")
        XCTAssertEqual(S.sidebarPlaceholder(connected: true, availability: .unknown, rows: 0), "Not loaded yet")
        XCTAssertEqual(S.sidebarPlaceholder(connected: true, availability: .available, rows: 0), "No boards")
        XCTAssertEqual(S.sidebarPlaceholder(connected: true, availability: .off, rows: 0), "Kanban is off in Hermes")
        XCTAssertEqual(S.sidebarPlaceholder(connected: true, availability: .failed("x"), rows: 0), "Boards not loaded")
        XCTAssertNil(S.sidebarPlaceholder(connected: true, availability: .available, rows: 2))
    }

    func testHubLoadsBoardsOnConnectAndGoesQuietWhenThePluginIsOff() async throws {
        let api = FakeKanbanService()
        api.with { $0.boards = [FakeKanbanService.summary("main"), FakeKanbanService.summary("gone", archived: true)] }
        let hub = KanbanHub(sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        hub.connect(api: api)
        try await waitUntil { hub.availability == .available }
        XCTAssertEqual(hub.rows.map(\.slug), ["main"])
        XCTAssertNotNil(hub.model(for: "main"))
        XCTAssertTrue(hub.model(for: "main") === hub.model(for: "main"), "one model per board")

        api.with { $0.boardsError = PluginREST.Failure.pluginUnavailable(plugin: "kanban") }
        await hub.refreshBoards()
        XCTAssertEqual(hub.availability, .off)
        XCTAssertTrue(hub.rows.isEmpty)

        api.with { $0.boardsError = nil }
        await hub.refreshBoards()
        XCTAssertEqual(hub.availability, .available)
        api.with { $0.boardsError = PluginREST.Failure.transport("down") }
        await hub.refreshBoards()
        XCTAssertEqual(hub.rows.map(\.slug), ["main"], "a transient failure keeps the rows")
        if case .failed = hub.availability {} else { XCTFail("expected .failed, got \(hub.availability)") }

        let board = hub.model(for: "main")!
        board.start()
        XCTAssertTrue(board.isPolling)
        hub.disconnect()
        XCTAssertFalse(board.isPolling, "disconnect stops every board")
        XCTAssertTrue(hub.rows.isEmpty)
        XCTAssertEqual(hub.availability, .unknown)
        XCTAssertNil(hub.model(for: "main"), "no models without a connection")
    }

    func testHubWithoutRESTAccessSaysSo() async throws {
        let hub = KanbanHub()
        hub.connect(api: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(hub.availability, .noAccess)
        XCTAssertFalse(hub.isPolling)
        XCTAssertNil(hub.model(for: "main"))
        XCTAssertEqual(KanbanHub.sidebarPlaceholder(connected: true, availability: .noAccess, rows: 0),
                       "Boards unavailable on this connection")
        XCTAssertTrue(KanbanHub.sidebarPlaceholderHelp(.noAccess).contains("REST access"))
        hub.disconnect()
        XCTAssertEqual(hub.availability, .unknown)
    }

    // MARK: dispatcher chip (K8)

    func testDispatcherChipStateMapping() {
        XCTAssertEqual(DispatcherChip.kind(state: nil, starting: false), .checking)
        XCTAssertEqual(DispatcherChip.kind(state: .running(pid: 42), starting: false), .running)
        XCTAssertEqual(DispatcherChip.kind(state: .installedNotRunning, starting: false), .stopped)
        XCTAssertEqual(DispatcherChip.kind(state: .notInstalled, starting: false), .notInstalled)
        XCTAssertEqual(DispatcherChip.kind(state: .unknown("corrupt"), starting: false), .unknown("corrupt"))
        XCTAssertEqual(DispatcherChip.kind(state: .installedNotRunning, starting: true), .starting, "starting wins")
        XCTAssertEqual(DispatcherChip.label(.running), "Dispatcher running")
        XCTAssertEqual(DispatcherChip.label(.stopped), "Dispatcher stopped")
        XCTAssertEqual(DispatcherChip.label(.notInstalled), "Dispatcher not installed")
        XCTAssertTrue(DispatcherChip.needsAttention(.stopped))
        XCTAssertTrue(DispatcherChip.needsAttention(.notInstalled))
        XCTAssertFalse(DispatcherChip.needsAttention(.running))
        XCTAssertFalse(DispatcherChip.needsAttention(.unknown("x")))
        XCTAssertTrue(DispatcherChip.explanation.contains("hermes gateway"))
    }

    func testDispatcherModelReportsNotInstalledAndNeverStartsIt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hba-kanban-\(UUID().uuidString)")
        let locks = home.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let model = DispatcherStatusModel(control: GatewayStatus(lockDir: locks, home: home, environment: [:]))
        await model.refresh()
        XCTAssertEqual(model.state, .notInstalled)
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertNil(model.startResult, "not installed: Start does nothing (the UI shows the install command)")
        XCTAssertFalse(model.starting)
        model.reset()
        XCTAssertEqual(model.state, .notInstalled)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
