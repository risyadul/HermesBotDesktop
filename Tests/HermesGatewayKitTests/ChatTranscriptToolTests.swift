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
