import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K6: Estimate / Decompose / Specify and the per-card model override through `KanbanCardAIModel`, against
/// `FakeKanbanService` (never a live backend). Headless.
@MainActor
final class KanbanAIActionsTests: XCTestCase {
    private func fake() -> FakeKanbanService {
        FakeKanbanService(columns: [
            ("triage", [FakeKanbanService.task("t_tri", "Rough idea", status: "triage")]),
            ("todo", [FakeKanbanService.task("t_1", "Write the spec", status: "todo", assignee: "alice")]),
            ("ready", []),
            ("done", []),
        ])
    }

    private func model(_ api: FakeKanbanService) async -> KanbanBoardModel {
        let m = KanbanBoardModel(slug: "main", api: api, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        await m.refresh()
        return m
    }

    // MARK: rules + words

    func testDecomposeAndSpecifyOnlyOnTriageCards() {
        XCTAssertTrue(KanbanAIRules.isAvailable(.estimate, status: "running"))
        XCTAssertTrue(KanbanAIRules.isAvailable(.decompose, status: "triage"))
        XCTAssertFalse(KanbanAIRules.isAvailable(.decompose, status: "todo"))
        XCTAssertFalse(KanbanAIRules.isAvailable(.specify, status: "ready"))
        XCTAssertEqual(KanbanAIRules.help(.specify, status: "todo"), "Only triage cards can be specified.")
        XCTAssertTrue(KanbanAIRules.confirmMessage(.specify).contains("replaced"))
        XCTAssertTrue(KanbanAIRules.confirmMessage(.decompose).contains("subtasks"))
    }

    func testEstimateWords() {
        XCTAssertEqual(KanbanAIRules.compact(950), "950")
        XCTAssertEqual(KanbanAIRules.compact(1_200), "1.2k")
        XCTAssertEqual(KanbanAIRules.compact(1_000), "1k")
        XCTAssertEqual(KanbanAIRules.compact(120_400), "120k")
        XCTAssertEqual(KanbanAIRules.compact(1_500_000), "1.5M")
        XCTAssertEqual(KanbanAIRules.estimateText(KanbanEstimate(json: ["ok": true, "est_tokens": 120_000, "complexity": "M"])),
                       "~120k tokens · Medium")
        XCTAssertEqual(KanbanAIRules.estimateText(KanbanEstimate(json: ["ok": true, "est_tokens": 800])), "~800 tokens")
    }

    func testOverrideWords() {
        XCTAssertEqual(KanbanAIRules.overrideLabel(.inherit), "Profile default")
        XCTAssertEqual(KanbanAIRules.overrideLabel(KanbanModelOverride(model: "model-a", provider: "prov", effort: "xhigh")),
                       "prov: model-a · Extra high")
        XCTAssertEqual(KanbanAIRules.overrideLabel(KanbanModelOverride(model: "model-a")), "model-a")
        XCTAssertEqual(KanbanAIRules.overrideLabel(KanbanModelOverride(effort: "none")), "Profile default · Thinking off")
        XCTAssertEqual(KanbanAIRules.effortLabel("low"), "Low")
        XCTAssertNil(KanbanAIRules.typedOverride("  ", keeping: .inherit))
        XCTAssertEqual(KanbanAIRules.typedOverride(" vendor/model-x ", keeping: KanbanModelOverride(model: "m", provider: "p", effort: "high")),
                       KanbanModelOverride(model: "vendor/model-x", provider: "", effort: "high"))
    }

    // MARK: estimate

    func testEstimateKeepsTheAnswerPerCard() async {
        let api = fake()
        let m = await model(api)
        await m.ai.run(.estimate, taskId: "t_1")
        XCTAssertEqual(api.count("estimate"), 1)
        XCTAssertEqual(m.ai.estimates["t_1"]?.estTokens, 120_000)
        XCTAssertNil(m.ai.estimates["t_tri"])
        XCTAssertNil(m.ai.outcomes["t_1"])
        XCTAssertFalse(m.ai.isRunning("t_1"))
    }

    func testEstimateRefusalIsShownInline() async {
        let api = fake()
        api.with { $0.estimateReply = ["ok": false, "reason": "auxiliary client unavailable"] }
        let m = await model(api)
        await m.ai.run(.estimate, taskId: "t_1")
        XCTAssertNil(m.ai.estimates["t_1"])
        XCTAssertEqual(m.ai.outcomes["t_1"], .init(action: .estimate, ok: false, text: "Couldn't estimate: auxiliary client unavailable"))
    }

    func testOneActionPerCardAtATime() async {
        let api = fake()
        api.with { $0.actionDelay = 0.2 }
        let m = await model(api)
        let first = Task { await m.ai.run(.estimate, taskId: "t_1") }
        while !m.ai.isRunning("t_1") { await Task.yield() }
        XCTAssertEqual(m.ai.running["t_1"], .estimate)
        await m.ai.run(.estimate, taskId: "t_1")
        await first.value
        XCTAssertEqual(api.count("estimate"), 1, "a second press while one runs sends nothing")
    }

    // MARK: decompose / specify

    func testDecomposeAsksFirstThenShowsTheSubtasks() async {
        let api = fake()
        let m = await model(api)
        m.ai.request(.decompose, taskId: "t_tri")
        XCTAssertEqual(m.ai.confirmation, .init(taskId: "t_tri", card: "Rough idea", action: .decompose))
        XCTAssertEqual(api.count("decompose"), 0, "nothing is sent before the user confirms")
        await m.ai.run(.decompose, taskId: "t_tri")
        XCTAssertEqual(api.count("decompose"), 1)
        XCTAssertEqual(api.with { $0.aiAuthors }, [KanbanAPI.commentAuthor])
        let o = m.ai.outcomes["t_tri"]
        XCTAssertEqual(o?.ok, true)
        XCTAssertEqual(o?.text, "Created 2 subtasks:")
        XCTAssertEqual(o?.childIds.count, 2)
        for id in o?.childIds ?? [] { XCTAssertNotNil(m.task(id), "the board was refreshed: \(id) is on it") }
        XCTAssertEqual(m.task("t_tri")?.status, "todo")
    }

    func testConfirmRunsTheConfirmedAction() async {
        let api = fake()
        let m = await model(api)
        m.ai.request(.specify, taskId: "t_tri")
        m.ai.confirm()
        XCTAssertNil(m.ai.confirmation)
        let end = Date().addingTimeInterval(5)
        while m.ai.outcomes["t_tri"] == nil, Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(api.count("specify"), 1)
        XCTAssertEqual(m.ai.outcomes["t_tri"]?.text, "Specified as “Specified placeholder” and moved to Todo.")
        XCTAssertEqual(m.task("t_tri")?.status, "todo")
        XCTAssertEqual(m.task("t_tri")?.title, "Specified placeholder")
    }

    func testDecomposeAndSpecifyRefusedBeforeSendingOnANonTriageCard() async {
        let api = fake()
        let m = await model(api)
        m.ai.request(.decompose, taskId: "t_1")
        XCTAssertNil(m.ai.confirmation)
        XCTAssertEqual(m.ai.outcomes["t_1"]?.text, "Only triage cards can be decomposed.")
        await m.ai.run(.specify, taskId: "t_1")
        XCTAssertEqual(api.count("decompose") + api.count("specify"), 0)
    }

    func testServerRefusalAndErrorsAreShown() async {
        let api = fake()
        api.with { $0.decomposeReply = ["ok": false, "reason": "LLM returned malformed JSON"] }
        let m = await model(api)
        await m.ai.run(.decompose, taskId: "t_tri")
        XCTAssertEqual(m.ai.outcomes["t_tri"], .init(action: .decompose, ok: false, text: "Couldn't decompose: LLM returned malformed JSON"))
        api.with { $0.aiError = PluginREST.Failure.http(status: 500, detail: "aux crashed") }
        await m.ai.run(.specify, taskId: "t_tri")
        XCTAssertEqual(m.ai.outcomes["t_tri"], .init(action: .specify, ok: false, text: "Specify failed: aux crashed"))
        XCTAssertEqual(m.task("t_tri")?.status, "triage", "nothing changed")
    }

    func testDecomposeWithoutFanoutSaysSo() {
        let one = KanbanCardAIModel.outcome(KanbanDecomposeResult(json: ["ok": true, "fanout": false, "new_title": "One task"]))
        XCTAssertEqual(one.text, "Kept as one task: “One task”.")
        XCTAssertTrue(one.childIds.isEmpty)
        let single = KanbanCardAIModel.outcome(KanbanDecomposeResult(json: ["ok": true, "fanout": true, "child_ids": ["t_9"]]))
        XCTAssertEqual(single.text, "Created 1 subtask:")
    }

    func testAGoneBoardRefusesAIActions() async {
        let api = fake()
        let m = await model(api)
        api.with { $0.boardError = PluginREST.Failure.http(status: 404, detail: "board 'main' does not exist") }
        await m.refresh()
        XCTAssertEqual(m.state, .gone)
        await m.ai.run(.estimate, taskId: "t_1")
        XCTAssertEqual(api.count("estimate"), 0)
        XCTAssertEqual(m.ai.outcomes["t_1"]?.ok, false)
    }

    // MARK: model override

    func testModelOverrideIsSavedAndShownAtOnce() async {
        let api = fake()
        let m = await model(api)
        await m.ai.loadModelOptions()
        XCTAssertEqual(m.ai.modelOptions.map(\.slug), ["prov"])
        await m.ai.loadModelOptions()
        XCTAssertEqual(api.count("modelOptions"), 1, "loaded once per board")
        let o = KanbanModelOverride(model: "model-b", provider: "prov", effort: "high")
        let ok = await m.ai.setModelOverride("t_1", o)
        XCTAssertTrue(ok)
        XCTAssertEqual(api.with { $0.overrides.map(\.override) }, [o])
        XCTAssertEqual(m.task("t_1")?.modelOverride, o)
        _ = await m.ai.setModelOverride("t_1", .inherit)
        XCTAssertEqual(m.task("t_1")?.modelOverride, .inherit)
    }

    func testModelOverrideFailureKeepsTheCardAndSaysWhy() async {
        let api = fake()
        api.with { $0.overrideError = PluginREST.Failure.http(status: 400, detail: "reasoning_effort must be one of …") }
        let m = await model(api)
        let ok = await m.ai.setModelOverride("t_1", KanbanModelOverride(effort: "high"))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.ai.modelErrors["t_1"], "Model not changed: reasoning_effort must be one of …")
        XCTAssertEqual(m.task("t_1")?.modelOverride, .inherit)
        XCTAssertFalse(m.ai.modelSaving.contains("t_1"))
    }

    func testReassignUsesTheReassignRouteWithReclaim() async {
        let api = fake()
        let m = await model(api)
        let ok = await m.reassign("t_1", to: "bob")
        XCTAssertTrue(ok)
        XCTAssertEqual(api.count("reassign"), 1)
        XCTAssertEqual(m.task("t_1")?.assignee, "bob")
    }
}
