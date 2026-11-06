import Foundation
import XCTest
@testable import HermesGatewayKit

/// Bot Chat composer controls in the kit (B7, B8, B9): payload parsing, the exact RPC shapes (scope rules:
/// model switches are `--session`, reasoning carries no scope), the new events, the compaction phase and
/// the transcript's redirect line.
final class ChatControlsTests: XCTestCase {
    private func event(_ type: String, sid: String, _ payload: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": "event", "params": ["type": .string(type), "session_id": .string(sid), "payload": payload]]
    }

    private func params(_ gw: FakeGateway, _ method: String) -> JSONValue? {
        gw.received.last { $0["method"]?.string == method }?["params"]
    }

    // MARK: parsing

    func testContextUsageNeedsAWindowAndClampsItsFigures() {
        XCTAssertNil(ContextUsage(["calls": 0, "input": 0]), "no context figures before the first request")
        XCTAssertNil(ContextUsage(nil))
        let u = ContextUsage(["context_used": 300_000, "context_max": 200_000, "context_percent": 140,
                              "context_estimated": true, "compressions": 2])
        XCTAssertEqual(u, ContextUsage(used: 200_000, max: 200_000, percent: 100, estimated: true, compressions: 2))
        XCTAssertEqual(ContextUsage(["context_used": 50, "context_max": 200])?.percent, 25, "percent derived when absent")
    }

    func testSessionInfoSnapshotReadsModelEffortAndUsage() {
        XCTAssertNil(SessionInfoSnapshot([:]), "an info placeholder has no model")
        let i = SessionInfoSnapshot(["model": "claude-x", "provider": "anthropic", "reasoning_effort": "ultra",
                                     "reasoning_effort_wire": "max", "running": true,
                                     "usage": ["context_used": 10, "context_max": 100, "context_percent": 10]])
        XCTAssertEqual(i, SessionInfoSnapshot(model: "claude-x", provider: "anthropic", reasoningEffort: "ultra",
                                              reasoningEffortWire: "max", usage: ContextUsage(used: 10, max: 100, percent: 10)))
    }

    func testModelCatalogKeepsSelectableRowsAndMatchesCustomProviders() {
        let c = ModelCatalog(["model": "m1", "provider": "custom:local", "providers": [
            ["slug": "anthropic", "name": "Anthropic", "models": ["m1", "m2"],
             "capabilities": ["m1": ["fast": false, "reasoning": true, "can_disable_reasoning": true],
                              "m2": ["fast": false, "reasoning": false]]],
            ["slug": "local", "name": "Local", "models": ["llama"]],
            ["slug": "empty", "name": "Nothing", "models": []],
        ]])
        XCTAssertEqual(c.providers.map(\.slug), ["anthropic", "local"], "a provider with no models is not offered")
        XCTAssertEqual(c.row(for: "custom:local")?.slug, "local")
        XCTAssertEqual(c.row(for: "ANTHROPIC")?.slug, "anthropic")
        XCTAssertEqual(c.capabilities(provider: "anthropic", model: "m1"), .init(reasoning: true, canDisableReasoning: true))
        XCTAssertEqual(c.capabilities(provider: "anthropic", model: "m2")?.reasoning, false)
        XCTAssertNil(c.capabilities(provider: "local", model: "llama"), "unknown → callers assume reasoning")
    }

    func testModelSwitchOutcomeAndBreakdown() {
        let o = ModelSwitchOutcome(["key": "model", "value": "big", "confirm_required": true, "confirm_message": "Costs more"])
        XCTAssertTrue(o.confirmRequired)
        XCTAssertEqual(o.confirmMessage, "Costs more")
        XCTAssertTrue(ModelSwitchOutcome(["value": "m", "deferred": true]).deferred)
        let b = ContextBreakdown(["categories": [["id": "system_prompt", "label": "System prompt", "tokens": 1200, "color": "#f00"],
                                                 ["label": "no id"]],
                                  "context_used": 5000, "context_max": 100_000, "context_percent": 5, "estimated_total": 0,
                                  "context_estimated": false, "context_source": "provider_usage", "model": "m"])
        XCTAssertEqual(b.categories, [.init(id: "system_prompt", label: "System prompt", tokens: 1200)])
        XCTAssertEqual(b.usage?.used, 5000)
    }

    func testReasoningLevelsAndLabels() {
        XCTAssertEqual(ReasoningEffort.options(canDisable: false).first, "minimal")
        XCTAssertEqual(ReasoningEffort.options(canDisable: true).first, "none")
        XCTAssertEqual(ReasoningEffort.label(""), "Medium", "unset is the provider default")
        XCTAssertEqual(ReasoningEffort.label("none"), "Off")
        XCTAssertFalse(ReasoningEffort.isLevel("show"), "display words are never sent as an effort")
    }

    // MARK: compaction

    func testCompactionPhaseFollowsStatusAndTurnEvents() {
        var on = CompactionPhase.next(false, after: .status(kind: "compacting", text: "…"))
        XCTAssertTrue(on)
        on = CompactionPhase.next(on, after: .status(kind: "process", text: "x"))
        XCTAssertTrue(on, "unrelated status keeps it")
        on = CompactionPhase.next(on, after: .toolCompleted(ToolCompletion(payload: ["tool_id": "t"])))
        XCTAssertTrue(on)
        XCTAssertFalse(CompactionPhase.next(on, after: .delta("resumed")), "first output after it ends it")
        XCTAssertFalse(CompactionPhase.next(on, after: .status(kind: "compacted", text: "")))
        XCTAssertFalse(CompactionPhase.next(on, after: .status(kind: "ready", text: "")))
        XCTAssertFalse(CompactionPhase.next(on, after: .idle))
        XCTAssertFalse(CompactionPhase.next(on, after: .error("boom")))
        XCTAssertTrue(CompactionPhase.next(false, after: .status(kind: "compressing", text: "")), "manual /compress")
    }

    // MARK: transcript redirect

    func testRedirectSealsWhatStreamedAndPutsTheCorrectionBelowIt() {
        var t = ChatTranscript()
        XCTAssertNil(t.redirect("not now"), "no turn to redirect")
        _ = t.beginTurn("q")
        t.apply(.delta("half an ans"))
        let id = t.redirect("  actually, shorter  ")
        XCTAssertNotNil(id)
        XCTAssertTrue(t.busy, "the turn keeps running")
        XCTAssertEqual(t.lines.map(\.role), [.user, .bot, .user])
        XCTAssertEqual(t.lines[1].streaming, false)
        XCTAssertEqual(t.lines[2].text, "actually, shorter")
        t.apply(.delta("Short."))
        t.apply(.completed(ChatCompletion(text: "Short.")))
        XCTAssertEqual(t.lines.map(\.text), ["q", "half an ans", "actually, shorter", "Short."])
        XCTAssertFalse(t.busy)
    }

    func testRetractTakesTheRefusedCorrectionBack() {
        var t = ChatTranscript()
        _ = t.beginTurn("q")
        t.apply(.delta("going"))
        let id = t.redirect("stop that")!
        t.retract(id)
        XCTAssertEqual(t.lines.map(\.role), [.user, .bot])
        XCTAssertEqual(t.lines.last?.streaming, true, "the sealed bubble is live again")
        t.apply(.delta(" on"))
        t.apply(.completed(ChatCompletion(text: "going on")))
        XCTAssertEqual(t.lines.map(\.text), ["q", "going on"], "one bubble, nothing shown twice")

        // Output that arrived after the correction keeps the split.
        _ = t.beginTurn("q2")
        t.apply(.delta("a"))
        let id2 = t.redirect("b")!
        t.apply(.delta("c"))
        t.retract(id2)
        t.apply(.completed(ChatCompletion(text: "ac")))
        XCTAssertEqual(Array(t.lines.map(\.text).suffix(2)), ["a", "c"])
    }

    // MARK: wire

    private func openSession(_ gw: FakeGateway) async throws -> (Backend, BotChatSession, Collector<ChatEvent>) {
        let backend = try await Parity.backend(gw)
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        let events = Collector<ChatEvent>()
        s.onEvent { events.add($0) }
        return (backend, s, events)
    }

    func testControlRPCsUseDesktopShapesAndSessionScope() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, p in
            switch m {
            case "session.redirect": return ["status": "redirected", "text": p["text"] ?? .null]
            case "model.options": return ["model": "m1", "provider": "anthropic",
                                          "providers": [["slug": "anthropic", "name": "Anthropic", "models": ["m1"]]]]
            case "config.set":
                return p["key"]?.string == "model"
                    ? ["key": "model", "value": "m2", "deferred": true, "scope": "session"]
                    : ["key": "reasoning", "value": p["value"] ?? .null]
            case "session.usage": return ["calls": 1, "context_used": 10, "context_max": 100, "context_percent": 10]
            case "session.context_breakdown": return ["categories": [], "context_used": 10, "context_max": 100,
                                                      "context_percent": 10, "estimated_total": 0,
                                                      "context_estimated": false, "context_source": "x", "model": "m1"]
            default: return Parity.defaults(m)
            }
        }
        let (backend, s, _) = try await openSession(gw)
        defer { backend.client.close() }

        let status = try await s.redirect("change course")
        XCTAssertEqual(status, "redirected")
        XCTAssertEqual(params(gw, "session.redirect"), ["session_id": "rt-1", "text": "change course"])

        let catalog = try await s.modelOptions()
        XCTAssertEqual(catalog.providers.map(\.slug), ["anthropic"])
        XCTAssertEqual(params(gw, "model.options"), ["session_id": "rt-1", "profile": "fake", "explicit_only": true])

        let o = try await s.switchModel(model: "m2", provider: "openrouter", confirmExpensive: false)
        XCTAssertTrue(o.deferred)
        XCTAssertEqual(params(gw, "config.set"), ["session_id": "rt-1", "key": "model", "value": "m2 --provider openrouter --session"],
                       "a pick changes this chat only: --session never persists to config.yaml")
        _ = try await s.switchModel(model: "m2", provider: "openrouter", confirmExpensive: true)
        XCTAssertEqual(params(gw, "config.set")?["confirm_expensive_model"], true)

        let applied = try await s.setReasoning("high")
        XCTAssertEqual(applied, "high")
        XCTAssertEqual(params(gw, "config.set"), ["session_id": "rt-1", "key": "reasoning", "value": "high"],
                       "no scope: session-scoped, like Desktop's effort menu")

        let before = gw.received.count
        do { _ = try await s.setReasoning("show"); XCTFail("display words are refused") } catch {}
        XCTAssertEqual(gw.received.count, before, "nothing is sent for a word that is not a level")

        let usage = try await s.usage()
        XCTAssertEqual(usage?.percent, 10)
        XCTAssertEqual(params(gw, "session.usage"), ["session_id": "rt-1"])
        let b = try await s.contextBreakdown()
        XCTAssertEqual(b.usage?.max, 100)
        XCTAssertFalse(Parity.methods(gw).contains("config.get"), "nothing reads or writes profile config directly")
    }

    func testRedirectMapsSessionNotOwned() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            m == "session.redirect" ? ["__error": ["code": 4090, "message": "not owned"]] : Parity.defaults(m)
        }
        let (backend, s, _) = try await openSession(gw)
        defer { backend.client.close() }
        do {
            _ = try await s.redirect("x")
            XCTFail("expected an error")
        } catch let e as BotChatError {
            XCTAssertEqual(e.description, BotChatError.sessionNotOwned(bot: "Fake").description)
        }
    }

    func testInfoUsageAndCompletionUsageReachTheConsumer() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, s, events) = try await openSession(gw)
        defer { backend.client.close(); withExtendedLifetime(s) {} }
        gw.push(event("session.info", sid: "rt-1", ["model": "m1", "provider": "p", "reasoning_effort": "low", "running": false,
                                                    "usage": ["context_used": 5, "context_max": 50, "context_percent": 10]]))
        gw.push(event("session.usage", sid: "rt-1", ["usage": ["context_used": 6, "context_max": 50, "context_percent": 12]]))
        gw.push(event("message.complete", sid: "rt-1", ["text": "done", "status": "complete",
                                                        "usage": ["context_used": 7, "context_max": 50, "context_percent": 14]]))
        try await Parity.waitUntil { events.all.contains { if case .completed = $0 { return true }; return false } }
        let all = events.all
        let infoAt = all.firstIndex { if case .info = $0 { return true }; return false }
        let idleAt = all.firstIndex(of: .idle)
        guard let infoAt, let idleAt else { return XCTFail("info and idle expected: \(all)") }
        XCTAssertLessThan(infoAt, idleAt, "the info comes before the idle of the same frame")
        if case .info(let i) = all[infoAt] {
            XCTAssertEqual(i.reasoningEffort, "low")
            XCTAssertEqual(i.usage?.used, 5)
        }
        XCTAssertTrue(all.contains(.usage(ContextUsage(used: 6, max: 50, percent: 12))))
        let completion = all.compactMap { e -> ChatCompletion? in if case .completed(let c) = e { return c }; return nil }.first
        XCTAssertEqual(completion?.usage?.used, 7)
    }
}
