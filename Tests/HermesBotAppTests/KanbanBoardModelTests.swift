import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// `KanbanBoardModel` against `FakeKanbanService`: polling lifecycle and generation guard, server column
/// order, optimistic actions with rollback, create + warning, comments, plugin-off state. Headless.
@MainActor
final class KanbanBoardModelTests: XCTestCase {
    private static let order = ["triage", "todo", "scheduled", "ready", "running", "blocked", "done", "archived"]

    private func fake() -> FakeKanbanService {
        FakeKanbanService(columns: [
            ("triage", []),
            ("todo", [FakeKanbanService.task("t_1", "Write the spec", status: "todo", priority: 1)]),
            ("scheduled", []),
            ("ready", [FakeKanbanService.task("t_2", "Ship it", status: "ready", priority: 2, assignee: "alice"),
                       FakeKanbanService.task("t_3", "Low one", status: "ready", priority: 0, assignee: "bob")]),
            ("running", []),
            ("blocked", []),
            ("done", []),
            ("archived", []),
        ])
    }

    /// A model whose poll loop waits only 10 ms between fetches.
    private func model(_ api: FakeKanbanService) -> KanbanBoardModel {
        KanbanBoardModel(slug: "main", api: api, sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
    }

    private func loaded(_ api: FakeKanbanService) async -> KanbanBoardModel {
        let m = model(api)
        await m.refresh()
        return m
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func lane(_ m: KanbanBoardModel, _ name: String) -> [String] {
        m.lanes.first { $0.name == name }?.tasks.map(\.id) ?? []
    }

    private static let refused = PluginREST.Failure.http(status: 409, detail: "blocked by parent t_0")

    // MARK: load + order

    func testColumnsKeepServerOrderAndHideAnEmptyArchive() async {
        let m = await loaded(fake())
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.serverLanes.map(\.name), Self.order)
        XCTAssertEqual(m.lanes.map(\.name), Array(Self.order.dropLast()), "empty archived lane hidden")
        XCTAssertEqual(lane(m, "ready"), ["t_2", "t_3"], "task order within a lane kept")
        XCTAssertEqual(KanbanColumns.visible([KanbanLane(name: "archived", tasks: [m.task("t_1")!])]).count, 1,
                       "an archive lane with cards stays")
    }

    func testFirstLoadFailureIsAFailedStateAndLaterFailuresKeepTheBoard() async {
        let api = fake()
        api.with { $0.boardError = PluginREST.Failure.http(status: 500, detail: "db locked") }
        let m = model(api)
        await m.refresh()
        XCTAssertEqual(m.state, .failed("db locked"))
        api.with { $0.boardError = nil }
        await m.refresh()
        XCTAssertEqual(m.state, .ready)
        api.with { $0.boardError = PluginREST.Failure.transport("down") }
        await m.refresh()
        XCTAssertEqual(m.state, .ready, "a shown board stays on screen")
        XCTAssertNotNil(m.syncError)
        XCTAssertEqual(m.failures, 1)
        api.with { $0.boardError = nil }
        await m.refresh()
        XCTAssertNil(m.syncError)
        XCTAssertEqual(m.failures, 0)
    }

    func testErrorBackoffDoublesUpToTheCap() {
        XCTAssertEqual(KanbanBoardModel.backoff(failures: 0), 4)
        XCTAssertEqual(KanbanBoardModel.backoff(failures: 1), 8)
        XCTAssertEqual(KanbanBoardModel.backoff(failures: 2), 16)
        XCTAssertEqual(KanbanBoardModel.backoff(failures: 3), 30)
        XCTAssertEqual(KanbanBoardModel.backoff(failures: 10), 30)
    }

    func testPluginUnavailableIsAnUnavailableStateAndEndsPolling() async throws {
        let api = fake()
        api.with { $0.boardError = PluginREST.Failure.pluginUnavailable(plugin: "kanban") }
        let m = model(api)
        m.start()
        try await waitUntil { m.state == .unavailable }
        try await waitUntil { !m.isPolling }
        let calls = api.count("board")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.count("board"), calls, "no retry loop while the plugin is off")
        XCTAssertEqual(KanbanBoardModel.describe(PluginREST.Failure.pluginUnavailable(plugin: "kanban")), "Kanban is off in Hermes.")
        // Turned back on: Try Again (stop + start) loads the board.
        api.with { $0.boardError = nil }
        m.stop(); m.start()
        try await waitUntil { m.state == .ready }
        m.stop()
    }

    // MARK: polling lifecycle

    func testPollingRepeatsWhileStartedAndStopsOnStop() async throws {
        let api = fake()
        let m = model(api)
        m.start()
        XCTAssertTrue(m.isPolling)
        try await waitUntil { api.count("board") >= 3 }
        XCTAssertEqual(m.state, .ready)
        m.stop()
        XCTAssertFalse(m.isPolling)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = api.count("board")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(api.count("board"), calls, "no fetch after stop")
    }

    func testAnAnswerOfAStoppedLoopIsDropped() async throws {
        let api = fake()
        api.with { $0.boardDelay = 0.2 }
        let m = model(api)
        m.start()
        let gen = m.generation
        try await waitUntil { api.count("board") == 1 }
        m.stop()
        XCTAssertGreaterThan(m.generation, gen)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(m.state, .loading, "the late answer of the stopped loop is not applied")
        XCTAssertTrue(m.serverLanes.isEmpty)
        XCTAssertGreaterThanOrEqual(m.droppedStale, 1)
        // A new loop applies its own answers.
        api.with { $0.boardDelay = 0 }
        m.start()
        try await waitUntil { m.state == .ready }
        m.stop()
    }

    func testAPollThatStartedBeforeAnActionFinishedIsDropped() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.boardDelay = 0.2 }
        let poll = Task { await m.refresh() }
        try await waitUntil { api.count("board") == 2 }
        api.with { $0.boardDelay = 0.3 }  // the action's own follow-up refresh lands later
        let moved = await m.move("t_1", to: "ready")
        XCTAssertTrue(moved)
        let outcome = await poll.value
        XCTAssertEqual(outcome, .stale, "it may predate the move")
        XCTAssertTrue(lane(m, "ready").contains("t_1"), "the move stays on screen")
    }

    // MARK: optimistic actions

    func testMoveShowsAtOnceAndRollsBackWithAnErrorWhenRefused() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.actionDelay = 0.15; $0.actionError = Self.refused }
        let action = Task { await m.move("t_1", to: "ready") }
        try await waitUntil { m.isPending("t_1") }
        XCTAssertTrue(lane(m, "ready").contains("t_1"), "optimistic: in the target lane before the answer")
        XCTAssertFalse(lane(m, "todo").contains("t_1"))
        let ok = await action.value
        XCTAssertFalse(ok)
        XCTAssertFalse(m.isPending("t_1"))
        XCTAssertEqual(lane(m, "todo"), ["t_1"], "rolled back")
        XCTAssertFalse(lane(m, "ready").contains("t_1"))
        XCTAssertEqual(m.error, "Move “Write the spec” to Ready failed: blocked by parent t_0")
    }

    func testMoveSucceedsAndStaysPlacedByPriority() async throws {
        let api = fake()
        let m = await loaded(api)
        let ok = await m.move("t_1", to: "ready")
        XCTAssertTrue(ok)
        XCTAssertNil(m.error)
        XCTAssertEqual(lane(m, "ready"), ["t_2", "t_1", "t_3"], "priority 1 between 2 and 0")
        XCTAssertEqual(m.task("t_1")?.status, "ready")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.count("board"), 1, "not polling (no board view): no follow-up fetch (KanbanLifecycleTests)")
    }

    func testMovesIntoLockedLanesAreRefusedBeforeSending() async {
        let api = fake()
        let m = await loaded(api)
        for lane in ["running", "review", "scheduled", "archived", "todo"] {
            let ok = await m.move("t_1", to: lane)
            XCTAssertFalse(ok, lane)
        }
        XCTAssertEqual(api.count("move"), 0)
        XCTAssertEqual(KanbanColumns.moveTargets(from: "todo", lanes: Self.order), ["triage", "ready", "blocked", "done"])
    }

    func testArchiveRemovesTheCardAndRollsBackOnFailure() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.actionDelay = 0.1; $0.actionError = PluginREST.Failure.transport("down") }
        let action = Task { await m.archive("t_3") }
        try await waitUntil { m.isPending("t_3") }
        XCTAssertNil(m.task("t_3"), "gone at once")
        let failed = await action.value
        XCTAssertFalse(failed)
        XCTAssertEqual(lane(m, "ready"), ["t_2", "t_3"], "back after the failure")
        XCTAssertTrue(m.error?.hasPrefix("Archive “Low one” failed") ?? false)
        api.with { $0.actionDelay = 0; $0.actionError = nil }
        let ok = await m.archive("t_3")
        XCTAssertTrue(ok)
        XCTAssertNil(m.task("t_3"))
        XCTAssertNil(m.error, "a new action clears the old error")
    }

    func testPriorityReordersAtOnceAndRollsBackOnFailure() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.actionDelay = 0.1; $0.actionError = Self.refused }
        let action = Task { await m.setPriority("t_3", 5) }
        try await waitUntil { m.isPending("t_3") }
        XCTAssertEqual(lane(m, "ready"), ["t_3", "t_2"])
        XCTAssertEqual(m.task("t_3")?.priority, 5)
        _ = await action.value
        XCTAssertEqual(lane(m, "ready"), ["t_2", "t_3"])
        XCTAssertEqual(m.task("t_3")?.priority, 0)
        api.with { $0.actionDelay = 0; $0.actionError = nil }
        let ok = await m.setPriority("t_3", 5)
        XCTAssertTrue(ok)
        XCTAssertEqual(lane(m, "ready"), ["t_3", "t_2"])
        let same = await m.setPriority("t_3", 5)
        XCTAssertFalse(same, "no-op for the current priority")
    }

    func testReassignShowsAtOnceAndRollsBackOnFailure() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.actionDelay = 0.1; $0.actionError = Self.refused }
        let action = Task { await m.reassign("t_2", to: "bob") }
        try await waitUntil { m.isPending("t_2") }
        XCTAssertEqual(m.task("t_2")?.assignee, "bob")
        _ = await action.value
        XCTAssertEqual(m.task("t_2")?.assignee, "alice")
        XCTAssertTrue(m.error?.contains("Assign “Ship it” to @bob failed") ?? false)
        api.with { $0.actionDelay = 0; $0.actionError = nil }
        let unassigned = await m.reassign("t_2", to: nil)
        XCTAssertTrue(unassigned)
        XCTAssertNil(m.task("t_2")?.assignee, "kept after success (reassign returns no task)")
        XCTAssertEqual(api.calls.filter { $0 == "reassign" }.count, 2)
    }

    // MARK: create, comments, details

    func testCreateInsertsTheCardAndSurfacesTheServerWarning() async throws {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.createWarning = "No dispatcher is running: this card will wait." }
        let (draft, column) = KanbanNewTaskSheet.request(title: "  New card ", details: "", assignee: "alice", priority: 3, column: "")
        XCTAssertEqual(draft.title, "New card")
        XCTAssertNil(draft.body)
        XCTAssertNil(column)
        let error = await m.create(draft, column: column)
        XCTAssertNil(error)
        XCTAssertEqual(lane(m, "ready").first, "t_new1", "priority 3 leads the lane, before the next poll")
        XCTAssertEqual(m.notice, "No dispatcher is running: this card will wait.")
        m.dismissNotice()
        XCTAssertNil(m.notice)
    }

    func testCreateFailureReturnsTheReason() async {
        let api = fake()
        let m = await loaded(api)
        api.with { $0.createError = PluginREST.Failure.http(status: 400, detail: "title is required") }
        let error = await m.create(KanbanTaskDraft(title: "x"), column: nil)
        XCTAssertEqual(error, "title is required")
        XCTAssertEqual(m.lanes.flatMap(\.tasks).count, 3)
    }

    func testNewTaskSheetMapsTriageToTheDraftFlagAndOtherLanesToAMove() {
        let triage = KanbanNewTaskSheet.request(title: "a", details: " body ", assignee: "", priority: 0, column: "triage")
        XCTAssertTrue(triage.0.triage)
        XCTAssertNil(triage.1)
        XCTAssertEqual(triage.0.body, "body")
        XCTAssertNil(triage.0.assignee)
        let todo = KanbanNewTaskSheet.request(title: "a", details: "", assignee: "bob", priority: 1, column: "todo")
        XCTAssertFalse(todo.0.triage)
        XCTAssertEqual(todo.1, "todo")
        XCTAssertEqual(KanbanColumns.createTargets(Self.order), ["triage", "todo", "ready", "blocked"])
    }

    func testSelectLoadsDetailsAndAddCommentAppendsIt() async throws {
        let api = fake()
        let m = await loaded(api)
        m.select("t_2")
        try await waitUntil { m.detail != nil }
        XCTAssertEqual(m.detail?.task.id, "t_2")
        XCTAssertEqual(m.detail?.parents, ["t_parent"])
        XCTAssertEqual(m.detail?.comments.count, 0)
        let blank = await m.addComment("   ")
        XCTAssertFalse(blank)
        XCTAssertEqual(api.count("comment"), 0)
        let ok = await m.addComment("Looks good")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.detail?.comments.map(\.body), ["Looks good"])
        XCTAssertEqual(m.detail?.comments.first?.author, KanbanAPI.commentAuthor)
        api.with { $0.commentError = PluginREST.Failure.transport("down") }
        let failed = await m.addComment("again")
        XCTAssertFalse(failed)
        XCTAssertEqual(m.detail?.comments.count, 1)
        XCTAssertTrue(m.error?.hasPrefix("Comment failed") ?? false)
        await m.loadLog()
        XCTAssertEqual(m.log?.content, "line one\nline two")
        m.select(nil)
        XCTAssertNil(m.detail)
        XCTAssertNil(m.log)
    }

    func testStartLoadsAssigneesForThePickers() async throws {
        let api = fake()
        let m = model(api)
        m.start()
        try await waitUntil { !m.assignees.isEmpty && m.state == .ready }
        m.stop()
        XCTAssertEqual(m.assigneeNames, ["alice", "bob"])
    }
}
