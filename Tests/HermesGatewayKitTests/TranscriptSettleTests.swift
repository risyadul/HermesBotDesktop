import Foundation
import XCTest
@testable import HermesGatewayKit

/// Turns that could stick or duplicate: a bubble seeded from a resume snapshot, a joined turn whose
/// `message.complete` was missed, a late `message.complete` while idle, a submit that never left. Also the
/// offline slash refusal table.
final class TranscriptSettleTests: XCTestCase {
    func testSeededBubbleIsReplacedByTheFinalWhenDeltasWereMissed() {
        var t = ChatTranscript()
        t.resumeRunningTurn(InflightTurn(user: "q", assistant: "Hello wor"))
        // The deltas "ld. More" were sent before we subscribed; only the tail arrives.
        t.apply(.delta(" text"))
        t.apply(.completed(ChatCompletion(text: "Hello world. More text")))
        XCTAssertEqual(t.lines.map(\.role), [.user, .bot])
        XCTAssertEqual(t.lines.last?.text, "Hello world. More text", "authoritative final, no duplicate reply")
        XCTAssertFalse(t.busy)
    }

    func testSeededBubbleKeepsWhatStreamedWhenTheFinalIsEmpty() {
        var t = ChatTranscript()
        t.resumeRunningTurn(InflightTurn(user: "", assistant: "partial"))
        t.apply(.completed(ChatCompletion(text: "")))
        XCTAssertEqual(t.lines.map(\.text), ["partial"])
    }

    func testCompleteWhileIdleChangesNothing() {
        var t = ChatTranscript()
        t.seed(history: [ChatHistoryMessage(role: .assistant, text: "done earlier")])
        t.apply(.completed(ChatCompletion(text: "done earlier")))
        XCTAssertEqual(t.lines.map(\.text), ["done earlier"], "the history already carries that turn")
        XCTAssertFalse(t.busy)
    }

    func testIdleReportSettlesAJoinedTurnButNotALocalOne() {
        var t = ChatTranscript()
        t.resumeRunningTurn(InflightTurn(user: "q", assistant: "half"))
        t.apply(.idle)
        XCTAssertFalse(t.busy, "the backend reports no running turn: the gate reopens")
        XCTAssertEqual(t.lines.last?.role, .system)

        var local = ChatTranscript()
        XCTAssertNotNil(local.beginTurn("mine"))
        local.apply(.idle)
        XCTAssertTrue(local.busy, "a stale idle report never ends a turn this client just submitted")
    }

    func testAbandonSettlesWithANeutralNoteAndBumpsNothingWhenIdle() {
        var t = ChatTranscript()
        t.apply(.delta("remote"))
        let serial = t.turnSerial
        t.abandon("Stopped.")
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.lines.map(\.role), [.bot, .system])
        t.abandon("again")
        XCTAssertEqual(t.lines.count, 2, "idle: no-op")
        XCTAssertEqual(t.turnSerial, serial)
    }

    func testRetractUnsentRemovesTheUserLine() {
        var t = ChatTranscript()
        t.seed(history: [ChatHistoryMessage(role: .user, text: "old")])
        XCTAssertNotNil(t.beginTurn("new"))
        t.retractUnsent("socket closed")
        XCTAssertEqual(t.lines.map(\.text), ["old", "socket closed"])
        XCTAssertFalse(t.busy)
        XCTAssertNotNil(t.beginTurn("new"))
        XCTAssertEqual(t.lines.filter { $0.role == .user && $0.text == "new" }.count, 1, "no duplicate on resend")
    }

    // MARK: slash refusals without a catalog

    func testOfflineTableRefusesHiddenBuiltInsWithDesktopWording() {
        XCTAssertEqual(SlashCatalog.offlineUnavailableMessage("config"), "/config is only available in the terminal interface.")
        XCTAssertEqual(SlashCatalog.offlineUnavailableMessage("/APPROVE"), "/approve is only used from messaging platforms.")
        XCTAssertEqual(SlashCatalog.offlineUnavailableMessage("login"), "/login is managed from the Hermes Desktop sidebar.")
        XCTAssertEqual(SlashCatalog.offlineUnavailableMessage("kanban"),
                       "/kanban is not shown in the slash palette here. Use the relevant Hermes Desktop control or terminal interface instead.")
        XCTAssertNotNil(SlashCatalog.offlineUnavailableMessage("voice"))
        XCTAssertNil(SlashCatalog.offlineUnavailableMessage("goal"), "offered built-ins and skills run")
    }

    func testHiddenDispositionIsNotARefusal() {
        let c = SlashCatalog(result: ["pairs": [], "commands": ["/model": ["desktop": "hidden"], "/fast": ["desktop": "advanced"]]])
        XCTAssertNil(c.unavailableMessage("model"), "hidden only keeps it out of the menu")
        XCTAssertNotNil(c.unavailableMessage("fast"))
    }
}
