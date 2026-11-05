import Foundation
import XCTest
@testable import HermesGatewayKit

/// `KanbanAPI` decoding and request shapes. Fixtures follow `plugins/kanban/dashboard/plugin_api.py` and the
/// key sets of a live read-only probe (`GET /boards`, `/board`, `/tasks/{id}`, `/log`, `/assignees`); every
/// title, body and name is a placeholder.
final class KanbanAPITests: XCTestCase {
    static let boardsJSON = #"""
    {"boards":[
      {"slug":"default","name":"Default","description":"","icon":"","color":"","default_workdir":null,"project_id":null,
       "created_at":null,"archived":false,"db_path":"/x/kanban.db","is_current":true,"counts":{"todo":2,"done":1,"archived":4},
       "total":3,"default_workspace_kind":"scratch","project_name":null},
      {"slug":"side","name":"Side board","archived":false,"is_current":false,"counts":{},"total":0,"extra_future_key":{"a":1}},
      {"name":"no slug: dropped"}
    ],"current":"default"}
    """#

    static let task1 = #"""
    {"id":"t_1","title":"Placeholder A","body":"Body A","assignee":"alice","status":"running","priority":2,
     "created_by":"dashboard","created_at":1760000000,"started_at":1760000100,"completed_at":null,"workspace_kind":"scratch",
     "workspace_path":"/tmp/w","claim_lock":null,"claim_expires":null,"tenant":null,"branch_name":null,"result":null,
     "consecutive_failures":1,"worker_pid":4242,"last_failure_error":"","last_heartbeat_at":1760000200,"block_kind":"",
     "block_recurrences":0,"skills":null,"goal_mode":false,"age":{"created_age_seconds":5},"latest_summary":"Summary A",
     "current_run_started_at":1760000150,"link_counts":{"parents":1,"children":0},"comment_count":3,"progress":null,
     "diagnostics":[{"kind":"stuck","severity":"warning"}],"warnings":{"count":1,"kinds":{"stuck":1},"highest_severity":"warning"},
     "brand_new_field":[1,2,3]}
    """#

    static let boardJSON = #"""
    {"columns":[
      {"name":"triage","tasks":[]},
      {"name":"todo","tasks":[{"id":"t_2","title":"Placeholder B","status":"todo","priority":"high"},{"title":"no id: dropped"}]},
      {"name":"running","tasks":[\#(task1)]},
      {"name":"review","tasks":[]},
      {"name":"qa-custom","tasks":[]},
      {"name":"done","tasks":[{"id":"t_3","title":"Placeholder C","status":"done","progress":{"done":1,"total":2}}]}
    ],"tenants":["acme"],"assignees":["alice","bob"],"latest_event_id":99,"now":1760000300}
    """#

    static let detailJSON = #"""
    {"task":\#(task1),
     "comments":[{"id":7,"task_id":"t_1","author":"desktop","body":"Comment body","created_at":1760000250}],
     "events":[{"id":11,"task_id":"t_1","kind":"claimed","payload":{"lock":"x"},"created_at":1760000100,"run_id":5},
               {"id":12,"task_id":"t_1","kind":"edited","payload":null,"created_at":1760000101,"run_id":null}],
     "attachments":[],
     "links":{"parents":["t_0"],"children":[]},
     "link_tasks":[{"id":"t_0","title":"Parent placeholder","status":"done"}],
     "child_results":[],
     "runs":[{"id":5,"task_id":"t_1","profile":"alice","step_key":null,"status":"running","claim_lock":"l","claim_expires":null,
              "worker_pid":4242,"max_runtime_seconds":null,"last_heartbeat_at":1760000200,"started_at":1760000150,"ended_at":null,
              "outcome":null,"summary":null,"metadata":null,"error":null}]}
    """#

    private func api(_ table: [String: StubURLProtocol.Reply]) -> (KanbanAPI, Int) {
        let port = PluginStub.routes(table)
        return (KanbanAPI(rest: PluginStub.rest(port: port, plugin: "kanban")), port)
    }

    // MARK: - decoding

    func testBoardsDecode() async throws {
        let (api, port) = api(["GET /api/plugins/kanban/boards": .init(json: Self.boardsJSON)])
        let list = try await api.boards()
        XCTAssertEqual(list.current, "default")
        XCTAssertEqual(list.boards.map(\.slug), ["default", "side"])
        let d = list.boards[0]
        XCTAssertTrue(d.isCurrent)
        XCTAssertEqual(d.total, 3)
        XCTAssertEqual(d.counts["archived"], 4)
        XCTAssertNil(d.defaultWorkdir)
        XCTAssertEqual(list.boards[1].name, "Side board")
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), [:])
    }

    func testBoardDecodePreservesColumnOrderAndIsLenient() async throws {
        let (api, port) = api(["GET /api/plugins/kanban/board": .init(json: Self.boardJSON)])
        let board = try await api.board("side", includeArchived: true)
        XCTAssertEqual(board.columns.map(\.name), ["triage", "todo", "running", "review", "qa-custom", "done"])
        XCTAssertEqual(board.columns[1].tasks.map(\.id), ["t_2"], "a task without id is dropped, not fatal")
        XCTAssertEqual(board.columns[1].tasks[0].priority, 0, "wrong-typed priority falls back")
        XCTAssertEqual(board.latestEventId, 99)
        XCTAssertEqual(board.assignees, ["alice", "bob"])
        XCTAssertEqual(board.task(id: "t_3")?.progress, .init(done: 1, total: 2))
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), ["board": "side", "include_archived": "true"])

        let t = try XCTUnwrap(board.task(id: "t_1"))
        XCTAssertEqual(t.title, "Placeholder A")
        XCTAssertEqual(t.status, "running")
        XCTAssertEqual(t.assignee, "alice")
        XCTAssertEqual(t.priority, 2)
        XCTAssertEqual(t.workerPid, 4242)
        XCTAssertEqual(t.currentRunStartedAt, 1760000150)
        XCTAssertEqual(t.latestSummary, "Summary A")
        XCTAssertEqual(t.commentCount, 3)
        XCTAssertEqual(t.linkCounts, .init(parents: 1, children: 0))
        XCTAssertNil(t.progress)
        XCTAssertEqual(t.warnings, .init(count: 1, highestSeverity: "warning"))
        XCTAssertNil(t.lastFailureError, "empty string reads as unset")
        XCTAssertNil(t.blockKind)
        XCTAssertEqual(t.raw["brand_new_field"], [1, 2, 3], "unknown fields stay reachable through raw")
    }

    func testMinimalTaskDecodes() throws {
        let t = try JSONDecoder().decode(KanbanTask.self, from: Data(#"{"id":"t_9"}"#.utf8))
        XCTAssertEqual(t.title, "")
        XCTAssertEqual(t.status, "todo")
        XCTAssertEqual(t.linkCounts, .init(parents: 0, children: 0))
        XCTAssertThrowsError(try JSONDecoder().decode(KanbanTask.self, from: Data(#"{"title":"x"}"#.utf8)))
    }

    func testTaskDetailDecode() async throws {
        let (api, port) = api(["GET /api/plugins/kanban/tasks/t_1": .init(json: Self.detailJSON)])
        let d = try await api.task("t_1", board: nil)
        XCTAssertEqual(d.task.id, "t_1")
        XCTAssertEqual(d.comments, [KanbanComment(json: ["id": 7, "author": "desktop", "body": "Comment body", "created_at": 1760000250])!])
        XCTAssertEqual(d.events.map(\.kind), ["claimed", "edited"])
        XCTAssertEqual(d.events[0].runId, 5)
        XCTAssertNil(d.events[1].payload)
        XCTAssertEqual(d.parents, ["t_0"])
        XCTAssertEqual(d.linkTasks.first?.title, "Parent placeholder")
        XCTAssertEqual(d.runs.first?.profile, "alice")
        XCTAssertEqual(d.runs.first?.status, "running")
        XCTAssertNil(d.runs.first?.endedAt)
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), [:], "board nil = no board param")
    }

    func testLogAndAssignees() async throws {
        let (api, port) = api([
            "GET /api/plugins/kanban/tasks/t_1/log": .init(json: #"{"task_id":"t_1","path":"/p","exists":true,"size_bytes":20,"content":"line\n","truncated":true}"#),
            "GET /api/plugins/kanban/assignees": .init(json: #"{"assignees":[{"name":"alice","on_disk":true,"counts":{"running":1}},{"on_disk":false}]}"#),
        ])
        let log = try await api.log(taskId: "t_1", board: "b")
        XCTAssertEqual(log, try JSONDecoder().decode(KanbanWorkerLog.self, from: Data(#"{"exists":true,"size_bytes":20,"content":"line\n","truncated":true}"#.utf8)))
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), ["board": "b", "tail": "16384"])
        let people = try await api.assignees(board: nil)
        XCTAssertEqual(people.map(\.name), ["alice"])
        XCTAssertEqual(people[0].counts, ["running": 1])
    }

    // MARK: - writes (request shapes match Desktop's api.ts)

    func testCreateSendsOnlySetFieldsAndMovesToColumn() async throws {
        let (api, port) = api([
            "POST /api/plugins/kanban/tasks": .init(json: #"{"task":{"id":"t_5","title":"New","status":"ready"},"warning":"no dispatcher"}"#),
            "PATCH /api/plugins/kanban/tasks/t_5": .init(json: #"{"task":{"id":"t_5","title":"New","status":"todo"}}"#),
        ])
        let r = try await api.createTask(KanbanTaskDraft(title: "New", assignee: "alice", priority: 1), board: "b", column: "todo")
        XCTAssertEqual(r.task?.status, "todo")
        XCTAssertEqual(r.warning, "no dispatcher")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["POST", "PATCH"])
        XCTAssertEqual(seen[0].body, ["title": "New", "assignee": "alice", "priority": 1, "triage": false])
        XCTAssertEqual(seen[1].body, ["status": "todo"])
        XCTAssertEqual(PluginStub.query(seen[0]), ["board": "b"])
    }

    func testCreateWithoutColumnSendsOneRequest() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/tasks": .init(json: #"{"task":{"id":"t_6","status":"triage"}}"#)])
        let r = try await api.createTask(KanbanTaskDraft(title: "T", body: "B", triage: true, parents: ["t_1"]), board: nil, column: "triage")
        XCTAssertEqual(r.task?.id, "t_6")
        XCTAssertNil(r.warning)
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].body, ["title": "T", "body": "B", "priority": 0, "triage": true, "parents": ["t_1"]])
    }

    func testPatchMoveArchivePriorityReassignComment() async throws {
        let ok = StubURLProtocol.Reply(json: #"{"task":{"id":"t/1","status":"archived"}}"#)
        let (api, port) = api([
            "PATCH /api/plugins/kanban/tasks/t/1": ok,
            "POST /api/plugins/kanban/tasks/t/1/reassign": .init(json: #"{"ok":true}"#),
            "POST /api/plugins/kanban/tasks/t/1/comments": .init(json: #"{"ok":true}"#),
        ])
        try await api.move("t/1", to: "blocked", board: "b")
        try await api.archive("t/1", board: "b")
        try await api.setPriority("t/1", 3, board: "b")
        try await api.updateTask("t/1", board: "b", KanbanTaskPatch(assignee: ""))
        try await api.reassign("t/1", to: "bob", board: "b")
        try await api.reassign("t/1", to: nil, board: "b", reclaimFirst: false)
        try await api.addComment(taskId: "t/1", body: "Hello", board: "b")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertTrue(seen.allSatisfy { $0.url.absoluteString.contains("/tasks/t%2F1") }, "task id is one encoded segment")
        XCTAssertEqual(seen.map(\.body), [
            ["status": "blocked"], ["status": "archived"], ["priority": 3], ["assignee": ""],
            ["profile": "bob", "reclaim_first": true], ["profile": "", "reclaim_first": false],
            ["author": "hermes-bot-app", "body": "Hello"],
        ])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0) == ["board": "b"] })
    }

    func testRefusedTransitionIsConflictWithDetail() async {
        let (api, _) = api(["PATCH /api/plugins/kanban/tasks/t_1": .init(status: 409, json: #"{"detail":"Cannot move to 'ready': blocked by parent(s)"}"#)])
        do { try await api.move("t_1", to: "ready", board: nil); XCTFail("expected 409") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 409, detail: "Cannot move to 'ready': blocked by parent(s)"))
        }
    }

    func testUnknownBoardIsHTTP404NotPluginUnavailable() async {
        let (api, _) = api(["GET /api/plugins/kanban/board": .init(status: 404, json: #"{"detail":"board 'gone' does not exist"}"#)])
        do { _ = try await api.board("gone"); XCTFail("expected 404") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 404, detail: "board 'gone' does not exist"))
        }
    }

    func testMissingPluginIsPluginUnavailable() async {
        let port = StubURLProtocol.serve { _ in .init(status: 404, json: #"{"detail":"Plugin not found"}"#) }
        do { _ = try await KanbanAPI(rest: PluginStub.rest(port: port, plugin: "kanban")).boards(); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .pluginUnavailable(plugin: "kanban"))
        }
    }
}
