import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K5 `KanbanWorkersModel` against `FakeKanbanService`: the active list, row status from the server clock,
/// Inspect (all parts, and the parts that failed), Terminate and Reclaim (sent once, list and board refreshed,
/// failures in words), polling lifecycle. Headless; no real kanban write is ever made.
@MainActor
final class KanbanWorkersModelTests: XCTestCase {
    private func fake() -> FakeKanbanService {
        let api = FakeKanbanService(columns: [("running", [FakeKanbanService.task("t_1", "Busy card", status: "running", assignee: "alice")])])
        api.with {
            $0.workers = [FakeKanbanService.worker(run: 5, task: "t_1", title: "Busy card", profile: "alice"),
                          FakeKanbanService.worker(run: 6, task: "t_2", title: "Quiet card", profile: nil, heartbeat: 1_760_000_100)]
        }
        return api
    }

    private func worker(_ m: KanbanWorkersModel, _ run: Int) -> KanbanActiveWorker { m.workers.first { $0.runId == run }! }

    func testLoadsTheActiveWorkers() async {
        let m = KanbanWorkersModel(slug: "main", api: fake())
        XCTAssertEqual(m.state, .loading)
        await m.refresh()
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.workers.map(\.runId), [5, 6])
        XCTAssertEqual(m.checkedAt, 1_760_000_300)
    }

    func testRowStatusUsesTheServerClock() {
        let w = KanbanActiveWorker(json: FakeKanbanService.worker(run: 1, task: "t", title: "T", profile: "a",
                                                                  started: 1_000, heartbeat: 1_295))!
        let fresh = KanbanWorkerStatus(w, now: 1_300)
        XCTAssertEqual(fresh.elapsed, "5m")
        XCTAssertEqual(fresh.heartbeat, "just now")
        XCTAssertFalse(fresh.stale)
        let old = KanbanWorkerStatus(w, now: 1_295 + 121)
        XCTAssertEqual(old.heartbeat, "2m ago")
        XCTAssertTrue(old.stale, "no heartbeat for 2+ minutes")
        let never = KanbanWorkerStatus(KanbanActiveWorker(json: FakeKanbanService.worker(run: 2, task: "t", title: "T",
                                                                                          profile: nil, heartbeat: nil))!, now: 2_000_000_000)
        XCTAssertEqual(never.heartbeat, "none yet")
        XCTAssertFalse(never.stale)
    }

    func testFirstLoadFailureIsFailedLaterFailuresKeepTheList() async {
        let api = fake()
        api.with { $0.workersError = PluginREST.Failure.http(status: 500, detail: "db locked") }
        let m = KanbanWorkersModel(slug: "main", api: api)
        await m.refresh()
        XCTAssertEqual(m.state, .failed("db locked"))
        api.with { $0.workersError = nil }
        await m.refresh()
        XCTAssertEqual(m.state, .ready)
        api.with { $0.workersError = PluginREST.Failure.transport("down") }
        await m.refresh()
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(m.workers.count, 2, "the shown list stays")
        XCTAssertNotNil(m.syncError)
    }

    func testPluginOffIsUnavailable() async {
        let api = fake()
        api.with { $0.workersError = PluginREST.Failure.pluginUnavailable(plugin: "kanban") }
        let m = KanbanWorkersModel(slug: "main", api: api)
        await m.refresh()
        XCTAssertEqual(m.state, .unavailable)
    }

    func testInspectLoadsRunProcessAndLog() async {
        let api = fake()
        let m = KanbanWorkersModel(slug: "main", api: api)
        await m.refresh()
        await m.inspect(worker(m, 5))
        let i = m.inspection
        XCTAssertEqual(i?.worker.runId, 5)
        XCTAssertEqual(i?.run?.summary, "Halfway there")
        XCTAssertEqual(i?.process?.pid, 4242)
        XCTAssertEqual(i?.log?.content, "line one\nline two")
        XCTAssertEqual(i?.problems, [])
        XCTAssertNil(m.inspecting)
        let rows = KanbanRunInspectionView.rows(i!)
        XCTAssertEqual(rows.map(\.label), ["Status", "Profile", "Summary", "Process"])
        XCTAssertEqual(rows.first { $0.label == "Profile" }?.value, "@alice")
        XCTAssertTrue(rows.last!.value.hasPrefix("pid 4242 · running · CPU "), rows.last!.value)
        m.closeInspection()
        XCTAssertNil(m.inspection)
    }

    func testInspectShowsThePartsThatLoadedAndNamesTheOthers() async {
        let api = fake()
        api.with {
            $0.runError = PluginREST.Failure.http(status: 404, detail: "run 5 not found")
            $0.inspectError = PluginREST.Failure.transport("down")
        }
        let m = KanbanWorkersModel(slug: "main", api: api)
        await m.refresh()
        await m.inspect(worker(m, 5))
        XCTAssertNil(m.inspection?.run)
        XCTAssertNil(m.inspection?.process)
        XCTAssertNotNil(m.inspection?.log)
        XCTAssertEqual(m.inspection?.problems.count, 2)
        XCTAssertEqual(m.inspection?.problems.first, "Run not loaded: run 5 not found")
    }

    func testDeadProcessReadsNotRunningWithItsReason() {
        let w = KanbanActiveWorker(json: FakeKanbanService.worker(run: 1, task: "t", title: "T", profile: "a"))!
        let i = KanbanWorkersModel.Inspection(worker: w, run: nil,
                                              process: KanbanRunProcess(json: ["alive": false, "reason": "process not found"]))
        XCTAssertEqual(KanbanRunInspectionView.rows(i).last, .init(label: "Process", value: "not running (process not found)"))
    }

    func testTerminateSendsOnceWithAReasonRefreshesAndTellsTheBoard() async {
        let api = fake()
        let m = KanbanWorkersModel(slug: "main", api: api)
        var changed = 0
        m.onChanged = { changed += 1 }
        await m.refresh()
        await m.inspect(worker(m, 5))
        let ok = await m.terminate(worker(m, 5))
        XCTAssertTrue(ok)
        XCTAssertEqual(api.count("terminate"), 1)
        XCTAssertEqual(api.with { $0.terminated.map(\.runId) }, [5])
        XCTAssertEqual(api.with { $0.terminated.first?.reason }, KanbanWorkersModel.terminateReason)
        XCTAssertEqual(m.workers.map(\.runId), [6], "the list is fetched again")
        XCTAssertEqual(changed, 1)
        XCTAssertNil(m.inspection, "the inspected run is gone")
        XCTAssertEqual(m.notice, "Terminated the run of “Busy card”.")
        XCTAssertTrue(m.busy.isEmpty)
    }

    func testTerminateFailureIsShownAndNothingChanges() async {
        let api = fake()
        api.with { $0.terminateError = PluginREST.Failure.http(status: 409, detail: "run 5 already ended") }
        let m = KanbanWorkersModel(slug: "main", api: api)
        var changed = 0
        m.onChanged = { changed += 1 }
        await m.refresh()
        let ok = await m.terminate(worker(m, 5))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "Terminate “Busy card” failed: run 5 already ended")
        XCTAssertEqual(changed, 0)
        XCTAssertNil(m.notice)
    }

    func testReclaimUsesTheTaskId() async {
        let api = fake()
        let m = KanbanWorkersModel(slug: "main", api: api)
        await m.refresh()
        let ok = await m.reclaim(worker(m, 5))
        XCTAssertTrue(ok)
        XCTAssertEqual(api.count("reclaim"), 1)
        XCTAssertEqual(api.count("terminate"), 0)
        XCTAssertEqual(m.workers.map(\.runId), [6])
        XCTAssertEqual(api.with { s in s.columns.first { $0.name == "running" }?.tasks.count }, 0, "the card left Running")
    }

    func testPollingStartsAndStopsAndDropsAnswersAfterStop() async throws {
        let api = fake()
        let m = KanbanWorkersModel(slug: "main", api: api, sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
        m.start()
        XCTAssertTrue(m.isPolling)
        let end = Date().addingTimeInterval(5)
        while api.count("workers") < 3, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(api.count("workers"), 3, "it polls")
        m.stop()
        XCTAssertFalse(m.isPolling)
        let after = api.count("workers")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertLessThanOrEqual(api.count("workers"), after + 1, "no loop after stop (at most the in-flight call)")
    }
}
