import XCTest
@testable import HermesGatewayKit

/// The submit gate and completion reconciliation.
final class ChatTranscriptTests: XCTestCase {
    private func bots(_ t: ChatTranscript) -> [String] { t.lines.filter { $0.role == .bot }.map(\.text) }
    private func complete(_ text: String?, status: String? = "complete", previewed: Bool = false,
                          reused: Bool = false, transformed: Bool = false) -> ChatEvent {
        .completed(ChatCompletion(text: text, status: status, responsePreviewed: previewed,
                                  responseReused: reused, responseTransformed: transformed))
    }

    // MARK: submit gate

    func testBusyRefusesSubmitAndKeepsState() {
        var t = ChatTranscript()
        XCTAssertEqual(t.beginTurn("  first  "), "first")
        XCTAssertTrue(t.busy)
        let before = t
        XCTAssertNil(t.beginTurn("Please retain the follow-up"), "busy must refuse")
        XCTAssertEqual(t, before, "a refused submit changes nothing")
        XCTAssertEqual(t.lines.filter { $0.role == .user }.count, 1)
    }

    func testDoubleSubmitBeforeAnyEventPassesOnce() {
        var t = ChatTranscript()
        let accepted = [t.beginTurn("hi"), t.beginTurn("hi")].compactMap { $0 }
        XCTAssertEqual(accepted, ["hi"])
    }

    func testBlankRefusedAndIdleAcceptedAfterComplete() {
        var t = ChatTranscript()
        XCTAssertNil(t.beginTurn("  \n "))
        XCTAssertFalse(t.busy)
        XCTAssertNotNil(t.beginTurn("one"))
        t.apply(.started); t.apply(.delta("a")); t.apply(complete("a"))
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.beginTurn("two"), "two")
    }

    // MARK: completion reconciliation

    func testOrdinaryStreamSettlesOnFinal() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("Hello ")); t.apply(.delta("world"))
        XCTAssertEqual(t.lines.last?.streaming, true)
        t.apply(complete("Hello world"))
        XCTAssertEqual(bots(t), ["Hello world"])
        XCTAssertFalse(t.lines.contains(where: \.streaming))
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.deltaCount, 2)
    }

    func testNoDeltaShowsFinal() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(complete("Only final"))
        XCTAssertEqual(bots(t), ["Only final"])
    }

    func testFinalExtendingStreamIsAuthoritative() {
        // Reviewer replay: start → delta("Partial") → complete("Partial plus final suffix").
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("Partial")); t.apply(complete("Partial plus final suffix"))
        XCTAssertEqual(bots(t), ["Partial plus final suffix"])
    }

    func testTransformedFinalReplacesStream() {
        // Reviewer replay: delta("TOKEN_1") → complete("example-service.internal", response_transformed).
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("TOKEN_1"))
        t.apply(complete("example-service.internal", transformed: true))
        XCTAssertEqual(bots(t), ["example-service.internal"])
    }

    func testEmptyFinalKeepsStream() {
        // Bot Chat silence guard: complete text "" must not erase what streamed.
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("streamed reply")); t.apply(complete(""))
        XCTAssertEqual(bots(t), ["streamed reply"])
        XCTAssertFalse(t.lines.contains(where: \.streaming))
    }

    func testEmptyFinalKeepsStreamEvenIfTransformedFlagged() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("kept")); t.apply(complete("", transformed: true))
        XCTAssertEqual(bots(t), ["kept"])
    }

    func testMissingFinalTextUsesStream() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("from stream")); t.apply(complete(nil))
        XCTAssertEqual(bots(t), ["from stream"])
    }

    func testEmptyTurnLeavesNoEmptyBubble() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(complete(""))
        XCTAssertEqual(bots(t), [])
        XCTAssertFalse(t.busy)
    }

    func testUnrelatedFinalWithoutTransformKeepsBoth() {
        // TUI parity (`recordMessageComplete`): a streamed tail the final does not carry is flushed as
        // its own segment; only response_transformed makes the final a replacement.
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("draft words")); t.apply(complete("Different answer"))
        XCTAssertEqual(bots(t), ["draft words", "Different answer"])
    }

    func testInterimSealsSegmentAndFinalIsSeparate() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("Checking calc"))
        t.apply(.interim("Checking calculator.", alreadyStreamed: true))
        t.apply(.delta("Final result: 42")); t.apply(complete("Final result: 42"))
        XCTAssertEqual(bots(t), ["Checking calculator.", "Final result: 42"])
        XCTAssertEqual(t.lines.filter(\.interim).count, 1)
    }

    func testNonStreamedInterimIsShown() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.interim("Looking it up.", alreadyStreamed: false))
        t.apply(complete("Done."))
        XCTAssertEqual(bots(t), ["Looking it up.", "Done."])
    }

    func testPreviewedFinalIsNotDuplicated() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.interim("same reply", alreadyStreamed: false))
        t.apply(complete("same reply", previewed: true))
        XCTAssertEqual(bots(t), ["same reply"])
    }

    func testIdenticalInterimAndFinalWithoutPreviewStaySeparate() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.interim("same reply", alreadyStreamed: false)); t.apply(complete("same reply"))
        XCTAssertEqual(bots(t), ["same reply", "same reply"])
    }

    func testFinalRepeatingInterimPrefixShowsOnlyTailWhenPreviewed() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.interim("Step one.", alreadyStreamed: false))
        t.apply(complete("Step one.\n\nStep two.", previewed: true))
        XCTAssertEqual(bots(t), ["Step one.", "Step two."])
    }

    func testNonCompleteStatusAddsErrorLine() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("part")); t.apply(complete("part", status: "interrupted"))
        XCTAssertEqual(bots(t), ["part"])
        XCTAssertEqual(t.lines.last?.role, .error)
        XCTAssertFalse(t.busy)
    }

    // MARK: failure paths (WARN-001)

    func testErrorEventSealsStreamAndEndsTurn() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started); t.apply(.delta("half")); t.apply(.error("boom"))
        XCTAssertEqual(bots(t), ["half"])
        XCTAssertFalse(t.lines.contains(where: \.streaming))
        XCTAssertEqual(t.lines.last?.text, "boom")
        XCTAssertFalse(t.busy)
    }

    func testDisconnectDuringTurnEndsIt() {
        var t = ChatTranscript(); _ = t.beginTurn("q")
        t.apply(.started)
        t.apply(.disconnected("socket closed"))
        XCTAssertFalse(t.busy)
        XCTAssertEqual(bots(t), [], "empty live bubble is dropped")
        XCTAssertEqual(t.lines.last?.role, .error)
    }

    func testDisconnectWhileIdleChangesNothing() {
        var t = ChatTranscript()
        t.apply(.disconnected("socket closed"))
        XCTAssertTrue(t.lines.isEmpty)
    }
}
