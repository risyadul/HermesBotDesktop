import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B7 model + reasoning effort per chat, B9 context gauge + compaction, B2 copy text. Headless, against
/// `FakeChatLink` (no gateway, no real config).
@MainActor
final class ChatModelControlsTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake", "model": "profile-default", "provider": "anthropic"])!

    private static let catalog = ModelCatalog(providers: [
        .init(slug: "anthropic", name: "Anthropic", models: ["m1", "m2"],
              capabilities: ["m1": .init(reasoning: true, canDisableReasoning: true), "m2": .init(reasoning: false, canDisableReasoning: false)]),
        .init(slug: "openrouter", name: "OpenRouter", models: ["big"]),
    ], model: "m1", provider: "anthropic")

    private func ready(_ link: FakeChatLink) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link })
        m.log = { _ in }
        m.open()
        try await waitUntil { m.isReady }
        return m
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func link(effort: String = "medium") -> FakeChatLink {
        let l = FakeChatLink()
        l.openInfo = SessionInfoSnapshot(model: "m1", provider: "anthropic", reasoningEffort: effort,
                                         usage: ContextUsage(used: 20_000, max: 200_000, percent: 10))
        l.catalog = Self.catalog
        return l
    }

    // MARK: B7 model

    func testOpenShowsTheChatsModelEffortAndCatalog() async throws {
        let l = link(effort: "high")
        let m = try await ready(l)
        XCTAssertEqual(m.currentModel, "m1")
        XCTAssertEqual(m.reasoningEffort, "high")
        XCTAssertEqual(m.contextUsage?.percent, 10)
        try await waitUntil { m.modelCatalog != nil }
        XCTAssertTrue(l.reads.contains("options"))
        XCTAssertTrue(m.showsReasoning)
        XCTAssertEqual(m.reasoningOptions.first, "none", "m1 can turn thinking off")
        XCTAssertFalse(l.reads.contains("usage"), "usage came with the open info")
    }

    func testWithoutInfoTheProfileModelIsShownAndUsageFetched() async throws {
        let l = FakeChatLink()
        l.usageResult = ContextUsage(used: 1, max: 10, percent: 10)
        let m = try await ready(l)
        XCTAssertEqual(m.currentModel, "profile-default")
        try await waitUntil { m.contextUsage != nil }
        XCTAssertTrue(m.showsReasoning, "unknown capabilities: assume reasoning, like Desktop")
    }

    /// Live UI test 2026-11-06 (round 2): the gauge stayed absent until a turn reported usage, because a resumed
    /// chat's `session.usage` carries no context figures until a turn runs in that backend. The open now falls
    /// back to the read-only `session.context_breakdown` estimate, as Desktop's status bar does.
    private func opening(_ l: FakeChatLink, retries: [Double] = [0.05, 0.05],
                         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in l })
        m.log = { _ in }
        m.usageRetryDelays = retries
        m.usageSleep = sleep
        m.open()
        try await waitUntil { m.isReady }
        return m
    }

    func testOpenFillsTheGaugeFromTheBreakdownWhenUsageHasNoFigures() async throws {
        let l = FakeChatLink()
        l.breakdownResult = ContextBreakdown(categories: [.init(id: "conversation", label: "Conversation", tokens: 30_000)],
                                             usage: ContextUsage(used: 34_000, max: 200_000, percent: 17, estimated: true))
        let m = try await opening(l)
        try await waitUntil { m.contextUsage != nil }
        XCTAssertEqual(m.contextUsage, ContextUsage(used: 34_000, max: 200_000, percent: 17, estimated: true))
        XCTAssertEqual(l.reads.filter { $0 == "usage" || $0 == "breakdown" }, ["usage", "breakdown"], "read-only, usage first")
        XCTAssertEqual(m.contextBreakdown?.categories.first?.tokens, 30_000)
        XCTAssertTrue(l.calls.allSatisfy { $0 == "catalog" }, "nothing written (the open's slash catalog aside): \(l.calls)")
    }

    func testOpenRetriesAZeroedBreakdownThenGivesUp() async throws {
        let l = FakeChatLink()  // no agent yet: the breakdown has no context_max
        let clock = ManualSleep()
        let m = try await opening(l, sleep: clock.sleep)
        try await waitUntil { clock.pending == 1 }  // first read done, waiting for the first retry
        clock.advance()
        try await waitUntil { clock.pending == 1 }  // second read done, waiting for the next one
        XCTAssertEqual(l.reads.filter { $0 == "breakdown" }.count, 2)
        l.breakdownResult = ContextBreakdown(categories: [], usage: ContextUsage(used: 10, max: 100, percent: 10, estimated: true))
        clock.advance()
        await m.usageTask?.value
        XCTAssertEqual(m.contextUsage?.percent, 10, "the agent was built meanwhile: the next retry fills the gauge")

        let quiet = FakeChatLink()
        let waits = ManualSleep()
        let n = try await opening(quiet, retries: [1, 4], sleep: waits.sleep)
        for _ in 0..<2 {
            try await waitUntil { waits.pending == 1 }
            waits.advance()
        }
        await n.usageTask?.value  // the retry loop has ended
        XCTAssertNil(n.contextUsage)
        XCTAssertEqual(quiet.reads.filter { $0 == "breakdown" }.count, 3, "one read, then one per retry delay, then it stops")
        XCTAssertEqual(waits.requested, [1, 4], "waited once per retry delay, in order")
    }

    func testOpenStopsRetryingOnceATurnReportsUsage() async throws {
        let l = FakeChatLink()
        let waits = ManualSleep()
        let m = try await opening(l, retries: [0.2, 0.2], sleep: waits.sleep)
        try await waitUntil { waits.pending == 1 }  // first read done, parked before the first retry
        m.apply(.usage(ContextUsage(used: 5, max: 50, percent: 10)))
        waits.advance()
        await m.usageTask?.value
        XCTAssertEqual(l.reads.filter { $0 == "breakdown" }.count, 1, "no retry after a figure arrived")
        XCTAssertEqual(waits.requested, [0.2], "it stopped at the first wake-up")
        XCTAssertEqual(m.contextUsage?.percent, 10)
    }

    func testPickingAModelSwitchesThisChatOnlyAndPaintsAtOnce() async throws {
        let l = link()
        let m = try await ready(l)
        m.selectModel(provider: "openrouter", model: "big")
        XCTAssertEqual(m.currentModel, "big", "painted before the reply")
        XCTAssertEqual(m.currentProvider, "openrouter")
        XCTAssertEqual(m.reasoningEffort, "medium", "effort carries over")
        try await waitUntil { l.calls.contains("model:big --provider openrouter --session") }
        m.selectModel(provider: "openrouter", model: "big")  // re-pick: refused synchronously
        m.selectModel(provider: "anthropic", model: "m2")  // a real pick after it marks the end of the sequence
        try await waitUntil { l.calls.contains("model:m2 --provider anthropic --session") }
        XCTAssertEqual(l.calls.filter { $0.hasPrefix("model:") },
                       ["model:big --provider openrouter --session", "model:m2 --provider anthropic --session"],
                       "re-picking the current model sends nothing")
    }

    func testARefusedPickRollsBackWithANote() async throws {
        let l = link()
        l.switchResult = { _, _, _ in throw GatewayClient.RPCError(code: 5001, message: "unknown model", data: nil) }
        let m = try await ready(l)
        m.selectModel(provider: "anthropic", model: "m2")
        try await waitUntil { m.currentModel == "m1" }
        XCTAssertTrue(m.lines.contains { $0.role == .system && $0.text.hasPrefix("Couldn't switch the model") })
    }

    func testANewerInfoIsNotRolledBack() async throws {
        let l = link()
        // The refusal waits for the test's go: the newer info is applied strictly before the rollback runs.
        let go = DispatchSemaphore(value: 0)
        l.switchResult = { _, _, _ in
            go.wait()
            throw GatewayClient.RPCError(code: 5001, message: "no", data: nil)
        }
        let m = try await ready(l)
        m.selectModel(provider: "anthropic", model: "m2")
        m.apply(.info(SessionInfoSnapshot(model: "other", provider: "x")))
        go.signal()
        try await waitUntil { m.lines.contains { $0.role == .system } }
        XCTAssertEqual(m.currentModel, "other", "the backend's newer report wins over the rollback")
    }

    func testAnExpensivePickAsksFirstAndResendsConfirmed() async throws {
        let l = link()
        l.switchResult = { m, _, confirmed in
            confirmed ? ModelSwitchOutcome(value: m) : ModelSwitchOutcome(value: m, confirmRequired: true, confirmMessage: "Pricey")
        }
        let m = try await ready(l)
        m.selectModel(provider: "openrouter", model: "big")
        try await waitUntil { m.modelConfirm != nil }
        XCTAssertEqual(m.modelConfirm?.message, "Pricey")
        XCTAssertEqual(m.currentModel, "m1", "not applied while unconfirmed")
        m.confirmModelSwitch()
        try await waitUntil { l.calls.contains("model:big --provider openrouter --session confirm") }
        XCTAssertEqual(m.currentModel, "big")
        XCTAssertNil(m.modelConfirm)

        m.selectModel(provider: "anthropic", model: "m2")
        try await waitUntil { m.modelConfirm != nil }
        m.cancelModelSwitch()
        XCTAssertEqual(m.currentModel, "big")
        XCTAssertFalse(l.calls.contains("model:m2 --provider anthropic --session confirm"))
    }

    func testAPickDuringATurnIsDeferredAndKept() async throws {
        let l = link()
        l.switchResult = { m, _, _ in ModelSwitchOutcome(value: m, deferred: true) }
        let m = try await ready(l)
        m.selectModel(provider: "anthropic", model: "m2")
        try await waitUntil { m.lines.contains { $0.text == ChatModel.deferredModelNote("m2") } }
        XCTAssertEqual(m.currentModel, "m2")
    }

    func testAnOlderBackendRefusingMidTurnKeepsThePick() async throws {
        let l = link()
        l.switchResult = { _, _, _ in throw GatewayClient.RPCError(code: ChatModel.busyModelSwitchCode, message: "busy", data: nil) }
        let m = try await ready(l)
        m.selectModel(provider: "anthropic", model: "m2")
        try await waitUntil { m.lines.contains { $0.role == .system } }
        XCTAssertEqual(m.currentModel, "m2")
    }

    func testSessionInfoUpdatesThePills() async throws {
        let m = try await ready(link())
        m.apply(.info(SessionInfoSnapshot(model: "m2", provider: "anthropic", reasoningEffort: "ultra", reasoningEffortWire: "max",
                                          usage: ContextUsage(used: 9, max: 10, percent: 90))))
        XCTAssertEqual(m.currentModel, "m2")
        XCTAssertEqual(m.contextUsage?.percent, 90)
        try await waitUntil { m.modelCatalog != nil }
        XCTAssertFalse(m.showsReasoning, "m2 has no reasoning control")
        XCTAssertEqual(ReasoningMenu.label("ultra", wire: "max"), "Ultra→Max")
        XCTAssertEqual(ReasoningMenu.label("", wire: ""), "Medium")
    }

    // MARK: B7 reasoning

    func testReasoningIsSessionScopedAndRollsBackOnFailure() async throws {
        let l = link()
        let m = try await ready(l)
        m.selectReasoning("high")
        XCTAssertEqual(m.reasoningEffort, "high")
        try await waitUntil { l.calls.contains("reasoning:high") }
        m.selectReasoning("show")
        XCTAssertEqual(m.reasoningEffort, "high", "display words are not levels")
        l.reasoningResult = { _ in throw GatewayClient.RPCError(code: 4002, message: "bad", data: nil) }
        m.selectReasoning("low")
        try await waitUntil { m.reasoningEffort == "high" }
        XCTAssertTrue(m.lines.contains { $0.text.hasPrefix("Couldn't change the reasoning effort") })
    }

    func testControlsWaitForTheChat() async throws {
        let l = link()
        let m = ChatModel(bot: bot, opener: { _ in l })
        m.log = { _ in }
        XCTAssertFalse(m.canChangeControls)
        m.selectModel(provider: "openrouter", model: "big")
        m.selectReasoning("low")
        XCTAssertTrue(l.calls.isEmpty)
    }

    // MARK: B9 usage + compaction

    func testUsageFollowsEventsAndTurnEnds() async throws {
        let l = link()
        l.usageResult = ContextUsage(used: 50_000, max: 200_000, percent: 25)
        let m = try await ready(l)
        m.apply(.usage(ContextUsage(used: 30_000, max: 200_000, percent: 15)))
        XCTAssertEqual(m.contextUsage?.percent, 15)
        m.apply(.completed(ChatCompletion(text: "x", usage: ContextUsage(used: 40_000, max: 200_000, percent: 20))))
        XCTAssertEqual(m.contextUsage?.percent, 20)
        m.apply(.completed(ChatCompletion(text: "y")))
        XCTAssertEqual(m.contextUsage?.percent, 20, "no change while idle")
        m.apply(.started)
        m.apply(.completed(ChatCompletion(text: "z")))
        try await waitUntil { m.contextUsage?.percent == 25 }
        XCTAssertTrue(l.reads.contains("usage"), "a completion without usage asks session.usage")
    }

    func testCompactingShowsUntilTheTurnResumes() async throws {
        let l = link()
        l.usageResult = ContextUsage(used: 2, max: 10, percent: 20, compressions: 1)
        let m = try await ready(l)
        m.apply(.started)
        m.apply(.status(kind: "compacting", text: "Compacting context…"))
        XCTAssertTrue(m.compacting)
        m.apply(.delta("back"))
        XCTAssertFalse(m.compacting, "the first output after it means the turn resumed")
        m.apply(.status(kind: "compressing", text: ""))
        XCTAssertTrue(m.compacting)
        m.apply(.status(kind: "compacted", text: "done"))
        XCTAssertFalse(m.compacting)
        try await waitUntil { m.contextUsage?.compressions == 1 }
    }

    func testBreakdownLoadsForThePopover() async throws {
        let l = link()
        l.breakdownResult = ContextBreakdown(categories: [.init(id: "system_prompt", label: "System prompt", tokens: 900)],
                                             usage: ContextUsage(used: 30_000, max: 200_000, percent: 15))
        let m = try await ready(l)
        m.loadContextBreakdown()
        try await waitUntil { m.contextBreakdown != nil && !m.breakdownLoading }
        XCTAssertEqual(m.contextBreakdown?.categories.first?.tokens, 900)
        XCTAssertEqual(m.contextUsage?.percent, 15)
    }

    func testGaugeText() {
        XCTAssertEqual(ContextGauge.compact(999), "999")
        XCTAssertEqual(ContextGauge.compact(1_250), "1.2k")
        XCTAssertEqual(ContextGauge.compact(200_000), "200k")
        XCTAssertEqual(ContextGauge.compact(1_500_000), "1.5M")
        let u = ContextUsage(used: 34_000, max: 200_000, percent: 17, estimated: true)
        XCTAssertEqual(ContextGauge.percentText(u), "~17%")
        XCTAssertEqual(ContextGauge.summary(u), "~34k of 200k tokens · ~17% full")
    }

    // MARK: B2 copy

    func testFullResponseJoinsTheTurnsReplyTexts() {
        let lines = [
            ChatLine(role: .user, text: "q1"),
            ChatLine(role: .bot, text: "only answer"),
            ChatLine(role: .user, text: "q2"),
            ChatLine(role: .thought, text: "thinking"),
            ChatLine(role: .bot, text: "Let me check."),
            ChatLine(role: .tool, text: "ls", tool: ToolLine(toolId: "t", name: "terminal", state: .done)),
            ChatLine(role: .bot, text: "  Found it.  "),
            ChatLine(role: .system, text: "note"),
        ]
        let full = ChatCopy.fullResponses(lines)
        XCTAssertNil(full[lines[1].id], "a single reply text needs no second action")
        XCTAssertEqual(full[lines[4].id], "Let me check.\n\nFound it.")
        XCTAssertEqual(full[lines[6].id], "Let me check.\n\nFound it.")
        XCTAssertNil(full[lines[3].id], "Thought rows are not copied")
    }

    func testWhatCanBeCopied() {
        XCTAssertTrue(ChatCopy.copyable(ChatLine(role: .user, text: "hi")))
        XCTAssertTrue(ChatCopy.copyable(ChatLine(role: .bot, text: "done")))
        XCTAssertFalse(ChatCopy.copyable(ChatLine(role: .bot, text: "stream", streaming: true)), "not while it streams")
        XCTAssertFalse(ChatCopy.copyable(ChatLine(role: .bot, text: "  ")))
        XCTAssertFalse(ChatCopy.copyable(ChatLine(role: .thought, text: "t")))
        XCTAssertFalse(ChatCopy.copyable(ChatLine(role: .error, text: "e")))
    }
}
