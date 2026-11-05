import Foundation
import XCTest
@testable import HermesGatewayKit

/// K5 `KanbanAPI` worker calls against a stub server: decoding of `/workers/active`, `/runs/{id}`,
/// `/runs/{id}/inspect` (fixtures follow `plugin_api.py` "Worker visibility"), and the terminate request shape.
/// Nothing reaches a real Hermes; every title and name is a placeholder.
final class KanbanWorkersAPITests: XCTestCase {
    private func api(_ table: [String: StubURLProtocol.Reply]) -> (KanbanAPI, Int) {
        let port = PluginStub.routes(table)
        return (KanbanAPI(rest: PluginStub.rest(port: port, plugin: "kanban")), port)
    }

    static let workersJSON = #"""
    {"workers":[
      {"run_id":5,"task_id":"t_1","task_title":"Placeholder A","task_status":"running","task_assignee":"alice",
       "profile":"alice","worker_pid":4242,"started_at":1760000000,"claim_lock":"l","claim_expires":1760000900,
       "last_heartbeat_at":1760000250,"max_runtime_seconds":null},
      {"run_id":6,"task_id":"t_2","task_title":"Placeholder B","task_status":"running","task_assignee":"bob",
       "profile":null,"worker_pid":4343,"started_at":1760000100,"last_heartbeat_at":null},
      {"task_id":"no run id: dropped"}
    ],"count":3,"checked_at":1760000300}
    """#

    func testActiveWorkersDecodeAndBoardQuery() async throws {
        let (api, port) = api(["GET /api/plugins/kanban/workers/active": .init(json: Self.workersJSON)])
        let list = try await api.activeWorkers(board: "side")
        XCTAssertEqual(list.checkedAt, 1_760_000_300)
        XCTAssertEqual(list.workers.map(\.runId), [5, 6], "a row without run_id is dropped")
        let a = list.workers[0]
        XCTAssertEqual(a.taskId, "t_1")
        XCTAssertEqual(a.taskTitle, "Placeholder A")
        XCTAssertEqual(a.bot, "alice")
        XCTAssertEqual(a.workerPid, 4242)
        XCTAssertEqual(a.lastHeartbeatAt, 1_760_000_250)
        XCTAssertEqual(a.claimExpires, 1_760_000_900)
        XCTAssertNil(a.maxRuntimeSeconds)
        XCTAssertEqual(list.workers[1].bot, "bob", "no run profile: the task's assignee")
        XCTAssertNil(list.workers[1].lastHeartbeatAt)
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), ["board": "side"])
    }

    func testRunAndInspectDecode() async throws {
        let (api, port) = api([
            "GET /api/plugins/kanban/runs/5": .init(json: #"{"run":{"id":5,"task_id":"t_1","profile":"alice","status":"running","summary":"Half","started_at":1760000000,"ended_at":null}}"#),
            "GET /api/plugins/kanban/runs/5/inspect": .init(json: #"{"run_id":5,"alive":true,"pid":4242,"cpu_percent":3.5,"memory_rss_bytes":2048,"memory_vms_bytes":4096,"num_threads":7,"num_fds":9,"status":"sleeping","create_time":1.0,"cmdline":["python","-m","worker"]}"#),
            "GET /api/plugins/kanban/runs/6/inspect": .init(json: #"{"run_id":6,"alive":false,"pid":4343,"reason":"process not found"}"#),
        ])
        let run = try await api.run(5, board: nil)
        XCTAssertEqual(run.id, 5)
        XCTAssertEqual(run.profile, "alice")
        XCTAssertEqual(run.summary, "Half")
        XCTAssertNil(run.endedAt)
        let live = try await api.inspectRun(5, board: "b")
        XCTAssertTrue(live.alive)
        XCTAssertEqual(live.pid, 4242)
        XCTAssertEqual(live.cpuPercent, 3.5)
        XCTAssertEqual(live.memoryRSSBytes, 2048)
        XCTAssertEqual(live.threads, 7)
        XCTAssertEqual(live.status, "sleeping")
        let dead = try await api.inspectRun(6, board: nil)
        XCTAssertFalse(dead.alive)
        XCTAssertEqual(dead.reason, "process not found")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(PluginStub.query(seen[0]), [:], "board nil = no board param")
        XCTAssertEqual(PluginStub.query(seen[1]), ["board": "b"])
    }

    func testRunWithoutRecordIsAnError() async {
        let (api, _) = api(["GET /api/plugins/kanban/runs/9": .init(json: #"{"nope":true}"#)])
        do { _ = try await api.run(9, board: nil); XCTFail("expected a decode error") } catch {
            XCTAssertTrue(Redaction.describe(error).contains("run"))
        }
    }

    func testTerminateSendsReasonOnlyWhenGiven() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/runs/5/terminate": .init(json: #"{"ok":true,"run_id":5,"task_id":"t_1"}"#)])
        try await api.terminateRun(5, board: "b", reason: "Stop it")
        try await api.terminateRun(5, board: "b", reason: nil)
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["POST", "POST"])
        XCTAssertEqual(seen.map(\.body), [["reason": "Stop it"], [:]])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0) == ["board": "b"] })
    }

    func testTerminateOfAnEndedRunIsConflict() async {
        let (api, _) = api(["POST /api/plugins/kanban/runs/5/terminate": .init(status: 409, json: #"{"detail":"run 5 already ended"}"#)])
        do { try await api.terminateRun(5, board: nil, reason: nil); XCTFail("expected 409") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 409, detail: "run 5 already ended"))
        }
    }
}
