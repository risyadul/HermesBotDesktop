import XCTest
@testable import HermesGatewayKit

/// Tool activity lines, history seeding and system lines in `ChatTranscript`, alongside the existing
/// settling rules (`ChatTranscriptTests`).
final class ChatTranscriptToolTests: XCTestCase {
    private func roles(_ t: ChatTranscript) -> [ChatLine.Role] { t.lines.map(\.role) }
    private func start(_ id: String, _ name: String = "terminal", context: String? = "ls") -> ChatEvent {
        .toolStarted(ToolStart(toolId: id, name: name, context: context))
    }

    func testToolRowFlushesStreamedTextAndFinalDoesNotRepeatIt() {
        var t = ChatTranscript()
        _ = t.beginTurn("check the dir")
        t.apply(.started); t.apply(.delta("Let me look."))
        t.apply(.toolGenerating(name: "terminal"))
        XCTAssertEqual(t.draftingTool, "terminal")
        t.apply(start("t1"))
        XCTAssertNil(t.draftingTool)
        XCTAssertEqual(roles(t), [.user, .bot, .tool])
        XCTAssertFalse(t.lines[1].streaming, "the pre-tool text is sealed before the row")
        XCTAssertEqual(t.lines[2].tool?.state, .running)
        XCTAssertEqual(t.lines[2].text, "ls")
        t.apply(.toolCompleted(ToolCompletion(toolId: "t1", name: "terminal", duration: 0.4, summary: "2 files")))
        XCTAssertEqual(t.lines[2].tool, ToolLine(toolId: "t1", name: "terminal", state: .done, duration: 0.4, summary: "2 files"))
        t.apply(.delta("Two files."))
        XCTAssertEqual(roles(t), [.user, .bot, .tool, .bot])
        t.apply(.completed(ChatCompletion(text: "Let me look.\n\nTwo files.")))
        XCTAssertEqual(t.lines.filter { $0.role == .bot }.map(\.text), ["Let me look.", "Two files."],
                       "the final's leading repeat of the sealed segment is dropped")
        XCTAssertEqual(roles(t), [.user, .bot, .tool, .bot])
        XCTAssertFalse(t.busy)
    }

    func testEmptyLiveBubbleIsDroppedAtToolStartAndUnknownCompletionUpserts() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.started)
        t.apply(start("t1"))
        XCTAssertEqual(roles(t), [.user, .tool])
        t.apply(.toolCompleted(ToolCompletion(toolId: "t9", name: "web", failed: true)))
        XCTAssertEqual(roles(t), [.user, .tool, .tool])
        XCTAssertEqual(t.lines[2].tool?.state, .failed)
        t.apply(start("t1"))
        XCTAssertEqual(roles(t), [.user, .tool, .tool], "a repeated start updates its row")
    }

    func testRunningToolsSettleWithTheTurn() {
        var t = ChatTranscript()
        _ = t.beginTurn("a")
        t.apply(start("t1"))
        t.apply(.completed(ChatCompletion(text: "done")))
        XCTAssertEqual(t.lines[1].tool?.state, .done)

        _ = t.beginTurn("b")
        t.apply(start("t2"))
        t.apply(.completed(ChatCompletion(text: nil, status: "interrupted")))
        XCTAssertEqual(t.lines.last { $0.role == .tool }?.tool?.state, .failed)

        _ = t.beginTurn("c")
        t.apply(start("t3"))
        t.apply(.error("boom"))
        XCTAssertEqual(t.lines.last { $0.role == .tool }?.tool?.state, .failed)
        XCTAssertEqual(t.lines.last?.role, .error)
        XCTAssertFalse(t.busy)
    }

    func testSeedFromHistory() {
        var t = ChatTranscript()
        XCTAssertTrue(t.seed(history: [ChatHistoryMessage(role: .user, text: "hi"),
                                       ChatHistoryMessage(role: .tool, text: "", toolName: "web", toolContext: "weather"),
                                       ChatHistoryMessage(role: .assistant, text: "sunny"),
                                       ChatHistoryMessage(role: .system, text: "compacted")]))
        XCTAssertEqual(roles(t), [.user, .tool, .bot, .system])
        XCTAssertEqual(t.lines[1].tool?.name, "web")
        XCTAssertEqual(t.lines[1].tool?.state, .done)
        XCTAssertEqual(t.lines[1].text, "weather")
        XCTAssertFalse(t.busy)
        _ = t.beginTurn("next")
        XCTAssertFalse(t.seed(history: []), "never while a turn runs")
        XCTAssertEqual(t.lines.count, 5)
    }

    func testSystemLineKeepsTheLiveBubbleLast() {
        var t = ChatTranscript()
        t.appendSystem("  goal set  ")
        t.appendSystem("   ")
        XCTAssertEqual(t.lines.map(\.text), ["goal set"])
        _ = t.beginTurn("x")
        t.apply(.delta("part"))
        t.appendSystem("note")
        t.apply(.delta(" two"))
        XCTAssertEqual(t.lines.map(\.text), ["goal set", "x", "note", "part two"])
        XCTAssertEqual(t.lines.last?.streaming, true)
    }

    func testRequestEventsDoNotTouchTheTranscript() {
        var t = ChatTranscript()
        _ = t.beginTurn("x")
        let before = t
        t.apply(.request(ServerRequest(wireId: "srq-1", method: "approval", params: ["session_id": "s"])))
        t.apply(.requestCancelled(id: "srq-1", reason: "timeout"))
        t.apply(.approvalsCancelled(requestIds: ["q"]))
        XCTAssertEqual(t, before)
    }
}

/// Thought lines: streamed reasoning, `reasoning.available`, and reasoning from history.
final class ChatTranscriptThoughtTests: XCTestCase {
    private func roles(_ t: ChatTranscript) -> [ChatLine.Role] { t.lines.map(\.role) }

    func testReasoningStreamsIntoAThoughtSealedByTextToolsAndTheEnd() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.reasoning("Let me ")); t.apply(.reasoning("think."))
        XCTAssertEqual(roles(t), [.user, .thought])
        XCTAssertEqual(t.lines[1].text, "Let me think.")
        XCTAssertTrue(t.lines[1].streaming)
        t.apply(.delta("Checking."))
        XCTAssertEqual(roles(t), [.user, .thought, .bot])
        XCTAssertFalse(t.lines[1].streaming, "text seals the Thought")
        t.apply(.toolStarted(ToolStart(toolId: "t1", name: "terminal", args: ["command": "ls"])))
        XCTAssertEqual(t.lines[3].tool?.args, ["command": "ls"])
        t.apply(.toolCompleted(ToolCompletion(toolId: "t1", name: "terminal", duration: 1, result: ["output": "a"])))
        XCTAssertEqual(t.lines[3].tool?.result, ["output": "a"])
        t.apply(.reasoning("Next step."))
        XCTAssertEqual(roles(t), [.user, .thought, .bot, .tool, .thought], "new reasoning after a tool is a new Thought")
        t.apply(.completed(ChatCompletion(text: "Checking.\n\nDone.")))
        XCTAssertEqual(roles(t), [.user, .thought, .bot, .tool, .thought, .bot])
        XCTAssertFalse(t.lines[4].streaming)
        XCTAssertEqual(t.lines.last?.text, "Done.", "the final does not repeat the text sealed before the tool")
        XCTAssertFalse(t.busy)
    }

    func testReasoningWhileTextStreamsStartsANewStepAfterIt() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.delta("Part one."))
        t.apply(.reasoning("hmm"))
        XCTAssertEqual(roles(t), [.user, .bot, .thought])
        XCTAssertFalse(t.lines[1].streaming)
        t.apply(.completed(ChatCompletion(text: "Part one. Part two.")))
        XCTAssertEqual(t.lines.filter { $0.role == .bot }.map(\.text), ["Part one.", "Part two."])
    }

    func testReasoningAvailableNeverTruncatesAStreamingThoughtAndIsIgnoredAfterText() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.reasoning("streamed in full"))
        t.apply(.reasoningAvailable("streamed in"))
        XCTAssertEqual(t.lines.filter { $0.role == .thought }.map(\.text), ["streamed in full"],
                       "the open Thought is kept: the event is cut to 500 characters")
        t.apply(.delta("Answer"))
        t.apply(.reasoningAvailable("late"))
        XCTAssertEqual(t.lines.filter { $0.role == .thought }.map(\.text), ["streamed in full"], "ignored once text shows")

        var fresh = ChatTranscript()
        _ = fresh.beginTurn("go")
        fresh.apply(.reasoningAvailable("all at once"))
        XCTAssertEqual(roles(fresh), [.user, .thought])
        fresh.apply(.completed(ChatCompletion(text: "ok")))
        XCTAssertEqual(roles(fresh), [.user, .thought, .bot])
        XCTAssertFalse(fresh.lines[1].streaming)

        var idle = ChatTranscript()
        idle.apply(.reasoningAvailable("stray"))
        XCTAssertTrue(idle.lines.isEmpty, "no turn, nothing to attach it to")
    }

    func testReasoningAfterMessageStartKeepsTheReplyBelowTheThought() {
        for reasoning in [ChatEvent.reasoning("why"), .reasoningAvailable("why")] {
            var t = ChatTranscript()
            _ = t.beginTurn("go")
            t.apply(.started)
            t.apply(reasoning)
            t.apply(.delta("Answer"))
            XCTAssertEqual(roles(t), [.user, .thought, .bot], "\(reasoning)")
            t.apply(.completed(ChatCompletion(text: "Answer")))
            XCTAssertEqual(t.lines.map(\.text), ["go", "why", "Answer"])
        }
    }

    func testEachUnstreamedStepGetsItsOwnThoughtInOrder() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.started)
        t.apply(.reasoningAvailable("step one plan"))
        t.apply(.toolStarted(ToolStart(toolId: "t1", name: "terminal")))
        t.apply(.toolCompleted(ToolCompletion(toolId: "t1", name: "terminal")))
        t.apply(.reasoningAvailable("step two plan"))
        t.apply(.toolStarted(ToolStart(toolId: "t2", name: "terminal")))
        t.apply(.completed(ChatCompletion(text: "Done")))
        XCTAssertEqual(roles(t), [.user, .thought, .tool, .thought, .tool, .bot])
        XCTAssertEqual(t.lines.filter { $0.role == .thought }.map(\.text), ["step one plan", "step two plan"])
    }

    func testBlankReasoningBeforeMessageStartDoesNotCorruptTheLiveBubble() {
        // Before the fix: a blank Thought sat before the live bubble, and removing it left the bubble's index
        // one past the end (index out of range on the next delta).
        for next in [ChatEvent.delta("Hello"), .completed(ChatCompletion(text: "Hello")), .interim("Hello", alreadyStreamed: false),
                     .toolStarted(ToolStart(toolId: "t", name: "terminal"))] {
            var t = ChatTranscript()
            _ = t.beginTurn("hi")
            t.apply(.reasoning("\n"))
            XCTAssertEqual(roles(t), [.user], "whitespace before any reasoning opens no Thought")
            t.apply(.started)
            t.apply(next)
            t.apply(.completed(ChatCompletion(text: "Hello")))
            XCTAssertFalse(t.busy, "\(next)")
            XCTAssertEqual(t.lines.first?.text, "hi")
        }
        var t = ChatTranscript()
        _ = t.beginTurn("hi")
        t.apply(.reasoning("\n")); t.apply(.reasoning("\nPlan"))
        XCTAssertEqual(t.lines.last?.text, "Plan", "leading whitespace is trimmed up to the first reasoning text")
    }

    func testErrorSealsTheThought() {
        var t = ChatTranscript()
        _ = t.beginTurn("go")
        t.apply(.reasoning("thinking"))
        t.apply(.error("boom"))
        XCTAssertEqual(roles(t), [.user, .thought, .error])
        XCTAssertFalse(t.lines[1].streaming)
    }

    func testHistoryReasoningToolArgsAndLabels() {
        let messages: JSONValue = [
            ["role": "user", "text": "continue"],
            ["role": "assistant", "text": "", "reasoning": "plan it"],
            ["role": "assistant", "text": "Melanjutkan", "reasoning_content": "why"],
            ["role": "tool", "name": "terminal", "context": "ls", "args": ["command": "ls -la"]],
            ["role": "tool", "name": "mcp_atlassian_getjiraissue", "context": "{}",
             "labels": [["text": "Atlassian · getjiraissue"]]],
            ["role": "assistant", "text": "   ", "reasoning": "  "],
        ]
        let history = ChatHistoryMessage.decode(messages)
        XCTAssertEqual(history.count, 5, "an assistant row with only blank text and reasoning is dropped")
        var t = ChatTranscript()
        t.seed(history: history)
        XCTAssertEqual(t.lines.map(\.role), [.user, .thought, .thought, .bot, .tool, .tool])
        XCTAssertEqual(t.lines[1].text, "plan it")
        XCTAssertEqual(t.lines[2].text, "why")
        XCTAssertFalse(t.lines[1].streaming)
        XCTAssertEqual(t.lines[4].tool?.args, ["command": "ls -la"])
        XCTAssertEqual(t.lines[5].tool?.label, "Atlassian · getjiraissue")
    }

    func testToolCompletionPayloadCarriesResultDiffAndFailureInResult() {
        let c = ToolCompletion(payload: ["tool_id": "t", "name": "patch", "args": ["path": "a"], "inline_diff": "-a\n+b",
                                         "result": ["error": "no such file"], "labels": [["text": "Files · patch"]]])
        XCTAssertTrue(c.failed, "a non-empty result.error is a failure")
        XCTAssertEqual(c.inlineDiff, "-a\n+b")
        XCTAssertEqual(c.label, "Files · patch")
        XCTAssertEqual(c.args, ["path": "a"])
        XCTAssertFalse(ToolCompletion(payload: ["tool_id": "t", "name": "x", "result": ["error": ""]]).failed)
        XCTAssertNil(ToolCompletion(payload: ["tool_id": "t", "name": "x", "result": .null]).result)
    }
}
