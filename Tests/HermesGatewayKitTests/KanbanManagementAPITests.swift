import Foundation
import XCTest
@testable import HermesGatewayKit

/// K6 (AI actions, model override) and K7 (boards CRUD, transfer, orchestration) request shapes and decoding,
/// against the in-process stub server (never the user's backend). Fixtures follow
/// `plugins/kanban/dashboard/plugin_api.py`; every title and name is a placeholder.
final class KanbanManagementAPITests: XCTestCase {
    private func api(_ table: [String: StubURLProtocol.Reply]) -> (KanbanAPI, Int) {
        let port = PluginStub.routes(table)
        return (KanbanAPI(rest: PluginStub.rest(port: port, plugin: "kanban")), port)
    }

    // MARK: - K6 AI actions

    func testEstimateTaskPostsEmptyBodyOnTheBoardAndDecodes() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/tasks/t/1/estimate": .init(json:
            #"{"ok":true,"est_tokens":123456,"complexity":"m","rationale":"Two files","model":"aux-model"}"#)])
        let e = try await api.estimate(taskId: "t/1", board: "b")
        XCTAssertTrue(e.ok)
        XCTAssertEqual(e.estTokens, 123_456)
        XCTAssertEqual(e.complexity, "M", "complexity is normalised to S/M/L")
        XCTAssertEqual(e.rationale, "Two files")
        XCTAssertEqual(e.model, "aux-model")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["POST"])
        XCTAssertEqual(seen[0].body, [:])
        XCTAssertEqual(PluginStub.query(seen[0]), ["board": "b"])
    }

    func testEstimateRefusalIsOkFalseWithReasonNotAnError() async throws {
        let (api, _) = api(["POST /api/plugins/kanban/tasks/t_1/estimate": .init(json:
            #"{"ok":false,"reason":"auxiliary client unavailable"}"#)])
        let e = try await api.estimate(taskId: "t_1", board: nil)
        XCTAssertFalse(e.ok)
        XCTAssertEqual(e.reason, "auxiliary client unavailable")
        XCTAssertNil(e.complexity)
        XCTAssertEqual(e.estTokens, 0)
    }

    func testEstimateTextIsNotBoardScopedAndOmitsAnEmptyBody() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/estimate": .init(json: #"{"ok":true,"est_tokens":10,"complexity":"X"}"#)])
        let e = try await api.estimate(title: "T", body: "")
        XCTAssertNil(e.complexity, "anything but S/M/L is dropped")
        _ = try await api.estimate(title: "T", body: "B")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.body), [["title": "T"], ["title": "T", "body": "B"]])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0).isEmpty })
    }

    func testDecomposeAndSpecifySendTheAuthorAndDecode() async throws {
        let (api, port) = api([
            "POST /api/plugins/kanban/tasks/t_1/decompose": .init(json:
                #"{"ok":true,"task_id":"t_1","reason":"decomposed into 2 children","fanout":true,"child_ids":["t_2","t_3",""],"new_title":null}"#),
            "POST /api/plugins/kanban/tasks/t_1/specify": .init(json:
                #"{"ok":false,"task_id":"t_1","reason":"task is not in triage (status='todo')","new_title":null}"#),
        ])
        let d = try await api.decompose(taskId: "t_1", board: "b", author: "hermes-bot-app")
        XCTAssertTrue(d.ok)
        XCTAssertTrue(d.fanout)
        XCTAssertEqual(d.childIds, ["t_2", "t_3"])
        XCTAssertNil(d.newTitle)
        let s = try await api.specify(taskId: "t_1", board: "b", author: nil)
        XCTAssertFalse(s.ok)
        XCTAssertEqual(s.reason, "task is not in triage (status='todo')")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.body), [["author": "hermes-bot-app"], [:]])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0) == ["board": "b"] })
    }

    func testAIRequestsWaitLongerThanTheDefaultTimeout() {
        XCTAssertGreaterThan(KanbanAPI.estimateTimeout, 60, "the estimator's own LLM timeout is 60 s")
        XCTAssertGreaterThan(KanbanAPI.specifyTimeout, 120)
        XCTAssertGreaterThan(KanbanAPI.decomposeTimeout, 180)
    }

    func testModelOptionsDecodeLeniently() async throws {
        let (api, _) = api(["GET /api/plugins/kanban/model-options": .init(json: #"""
            {"providers":[{"slug":"prov","label":"Provider","models":["model-a",{"id":"model-b"},{"x":1},""]},
                          {"slug":"empty","label":"Empty","models":[]},{"label":"no slug","models":["m"]},
                          {"slug":"bare","models":["m"]}]}
            """#)])
        let list = try await api.modelOptions()
        XCTAssertEqual(list.map(\.slug), ["prov", "bare"], "providers without models or slug are dropped")
        XCTAssertEqual(list[0].models, ["model-a", "model-b"])
        XCTAssertEqual(list[1].label, "bare")
    }

    func testModelOverridePatchSetsAndClearsExplicitly() async throws {
        let (api, port) = api(["PATCH /api/plugins/kanban/tasks/t_1": .init(json:
            #"{"task":{"id":"t_1","status":"todo","model_override":"model-a","provider_override":"prov","reasoning_effort":"high"}}"#)])
        let t = try await api.setModelOverride("t_1", KanbanModelOverride(model: "model-a", provider: "prov", effort: "high"), board: "b")
        XCTAssertEqual(t?.modelOverride, KanbanModelOverride(model: "model-a", provider: "prov", effort: "high"))
        try await api.setModelOverride("t_1", .inherit, board: "b")
        try await api.setModelOverride("t_1", KanbanModelOverride(model: " ", provider: "prov", effort: "none"), board: "b")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.body), [
            ["model_override": "model-a", "provider_override": "prov", "reasoning_effort": "high"],
            ["clear_model_override": true, "clear_reasoning_effort": true],
            ["clear_model_override": true, "reasoning_effort": "none"],
        ])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0) == ["board": "b"] })
    }

    func testOverrideHelpers() throws {
        XCTAssertTrue(KanbanModelOverride.inherit.isInherited)
        XCTAssertFalse(KanbanModelOverride(effort: "low").isInherited)
        XCTAssertEqual(KanbanModelOverride.efforts.first, "none")
        let plain = try KanbanTask(json: ["id": "t_1"])
        XCTAssertEqual(plain.modelOverride, .inherit)
    }

    // MARK: - K7 boards

    func testBoardSlugFollowsDesktop() {
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: "  Q3 Launch Plan! "), "q3-launch-plan")
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: "--Ops__Board--"), "ops-board")
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: "Café crème"), "caf-cr-me")
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: "!!!"), "")
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: String(repeating: "a", count: 70)).count, 64)
        XCTAssertEqual(KanbanAPI.boardSlug(fromName: String(repeating: "a", count: 63) + " b"), String(repeating: "a", count: 63),
                       "no trailing dash after the cut")
    }

    func testBoardCrudShapes() async throws {
        let (api, port) = api([
            "POST /api/plugins/kanban/boards": .init(json: #"{"board":{"slug":"q3","name":"Q3"},"current":"default"}"#),
            "PATCH /api/plugins/kanban/boards/q3": .init(json: #"{"board":{"slug":"q3","name":"Q3 renamed"}}"#),
            "DELETE /api/plugins/kanban/boards/q3": .init(json:
                #"{"result":{"slug":"q3","action":"archived","new_path":"/x/_archived/q3-1"},"current":"default"}"#),
        ])
        let made = try await api.createBoard(slug: "q3", name: "Q3")
        XCTAssertEqual(made?.slug, "q3")
        let renamed = try await api.renameBoard("q3", name: "Q3 renamed")
        XCTAssertEqual(renamed?.name, "Q3 renamed")
        let removed = try await api.archiveBoard("q3")
        XCTAssertEqual(removed, KanbanBoardRemoval(json: ["result": ["action": "archived", "new_path": "/x/_archived/q3-1"], "current": "default"]))
        XCTAssertEqual(removed.newPath, "/x/_archived/q3-1")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["POST", "PATCH", "DELETE"])
        XCTAssertEqual(seen[0].body, ["slug": "q3", "name": "Q3"], "never `switch`: the server's current board stays")
        XCTAssertEqual(seen[1].body, ["name": "Q3 renamed"])
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0).isEmpty }, "archive, not `delete=true`; no board param")
    }

    func testDefaultBoardRefusalSurfacesTheServerDetail() async {
        let (api, _) = api(["DELETE /api/plugins/kanban/boards/default": .init(status: 400, json:
            #"{"detail":"the 'default' board cannot be removed"}"#)])
        do { _ = try await api.archiveBoard("default"); XCTFail("expected 400") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 400, detail: "the 'default' board cannot be removed"))
        }
    }

    func testExportAndImportPassPaths() async throws {
        let (api, port) = api([
            "POST /api/plugins/kanban/boards/q 3/export": .init(json:
                #"{"board":"q 3","archive":"/tmp/q3.tar.gz","size":4096,"counts":{"tasks":3}}"#),
            "POST /api/plugins/kanban/boards/import": .init(json:
                #"{"board":"q3-2","requested_board":"q3","renamed":true,"name":"Q3","path":"/x","warnings":["1 task parked"],"current":"default"}"#),
        ])
        let out = try await api.exportBoard("q 3", to: "/tmp/q3.tar.gz")
        XCTAssertEqual(out.archive, "/tmp/q3.tar.gz")
        XCTAssertEqual(out.size, 4096)
        let imported = try await api.importBoard(archive: "/tmp/q3.tar.gz")
        XCTAssertEqual(imported.board, "q3-2")
        XCTAssertTrue(imported.renamed)
        XCTAssertEqual(imported.requestedBoard, "q3")
        XCTAssertEqual(imported.warnings, ["1 task parked"])
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.body), [["output": "/tmp/q3.tar.gz"], ["archive": "/tmp/q3.tar.gz"]])
        XCTAssertGreaterThanOrEqual(KanbanAPI.transferTimeout, 60)
    }

    func testOrchestrationGetPutAndProfiles() async throws {
        let settings = #"""
            {"orchestrator_profile":"","default_assignee":"bob","auto_decompose":false,"auto_promote_children":true,
             "resolved_orchestrator_profile":"alice","resolved_default_assignee":"bob","active_profile":"alice"}
            """#
        let (api, port) = api([
            "GET /api/plugins/kanban/orchestration": .init(json: settings),
            "PUT /api/plugins/kanban/orchestration": .init(json: settings),
            "GET /api/plugins/kanban/profiles": .init(json:
                #"{"profiles":[{"name":"alice","is_default":true,"description":"Plans"},{"name":"bob"},{"description":"no name"}]}"#),
        ])
        let s = try await api.orchestration()
        XCTAssertEqual(s.orchestratorProfile, "")
        XCTAssertEqual(s.resolvedOrchestratorProfile, "alice")
        XCTAssertEqual(s.defaultAssignee, "bob")
        XCTAssertFalse(s.autoDecompose)
        XCTAssertTrue(s.autoPromoteChildren)
        _ = try await api.setOrchestration(KanbanOrchestrationPatch(orchestratorProfile: ""))
        _ = try await api.setOrchestration(KanbanOrchestrationPatch(defaultAssignee: "bob", autoDecompose: true))
        let profiles = try await api.profiles()
        XCTAssertEqual(profiles.map(\.name), ["alice", "bob"])
        XCTAssertTrue(profiles[0].isDefault)
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["GET", "PUT", "PUT", "GET"])
        XCTAssertEqual(seen[1].body, ["orchestrator_profile": ""], "only the fields set; empty clears")
        XCTAssertEqual(seen[2].body, ["default_assignee": "bob", "auto_decompose": true])
    }

    func testOrchestrationDefaultsWhenFieldsAreMissing() {
        let s = KanbanOrchestration(json: [:])
        XCTAssertTrue(s.autoDecompose)
        XCTAssertTrue(s.autoPromoteChildren)
        XCTAssertEqual(s.activeProfile, "default")
        XCTAssertEqual(s.resolvedDefaultAssignee, "default")
    }
}
