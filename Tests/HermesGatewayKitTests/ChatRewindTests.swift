import Foundation
import XCTest
@testable import HermesGatewayKit

/// B3 / B4 in the kit: rewind planning, the exact `prompt.submit` truncation payloads Hermes Desktop sends, the
/// survivor rebinding, branch counts and the `session.branch` wire shape (in-process `FakeGateway`, nothing real).
final class ChatRewindTests: XCTestCase {
    private func params(_ gw: FakeGateway, _ method: String) -> JSONValue? {
        gw.received.last { $0["method"]?.string == method }?["params"]
    }

    private func seeded() -> ChatTranscript {
        var t = ChatTranscript()
        t.seed(history: [
            ChatHistoryMessage(role: .user, text: "first", rowId: 10),
            ChatHistoryMessage(role: .assistant, text: "one", rowId: 11),
            ChatHistoryMessage(role: .tool, text: "", toolName: "terminal", rowId: 12),
            ChatHistoryMessage(role: .user, text: "second", rowId: 13),
            ChatHistoryMessage(role: .assistant, text: "two", rowId: 14),
        ])
        return t
    }

    // MARK: params (Desktop `truncateSubmitParams` + `runRewindSubmit`, durable-row mode)

    func testRewindParamsWithARowIdMatchDesktop() {
        XCTAssertEqual(RewindParams.submit(sessionId: "rt", text: "again", rowId: 13, confirmDeep: false, rebind: [10, 11, 10]),
                       ["session_id": "rt", "text": "again", "confirm_truncate": true, "truncate_before_row_id": 13,
                        "confirm_empty_truncate": true, "rebind_survivor_row_ids": [10, 11]])
        XCTAssertEqual(RewindParams.submit(sessionId: "rt", text: "x", rowId: 10, confirmDeep: true, rebind: [])["confirm_deep_truncate"], true)
        XCTAssertNil(RewindParams.submit(sessionId: "rt", text: "x", rowId: 10, confirmDeep: false, rebind: [])["confirm_deep_truncate"],
                     "never sent unless the user confirmed")
    }

    func testWithoutARowIdNothingIsCut() {
        let p = RewindParams.submit(sessionId: "rt", text: "x", rowId: nil, confirmDeep: true, rebind: [])
        XCTAssertEqual(p, ["session_id": "rt", "text": "x"], "no truncation field rides on a plain resubmit")
    }

    // MARK: planning

    func testRegeneratePlansTheUserTurnAboveTheReply() throws {
        let t = seeded()
        let reply = t.lines.first { $0.text == "one" }!
        let plan = try XCTUnwrap(RewindPlanner.plan(.regenerate, from: reply.id, in: t.lines))
        XCTAssertEqual(plan.text, "first")
        XCTAssertEqual(plan.rowId, 10)
        XCTAssertEqual(plan.ordinal, 0)
        XCTAssertEqual(plan.laterUserTurns, 1)
        XCTAssertTrue(plan.isDeepCut, "an older reply archives the later turn")
        let tail = try XCTUnwrap(RewindPlanner.plan(.regenerate, from: t.lines.last!.id, in: t.lines))
        XCTAssertFalse(tail.isDeepCut)
        XCTAssertEqual(tail.rowId, 13)
    }

    func testEditAndRestoreNameTheUserLine() {
        let t = seeded()
        let user = t.lines.first { $0.text == "second" }!
        let reply = t.lines.last!
        XCTAssertNil(RewindPlanner.plan(.restore, from: reply.id, in: t.lines), "restore is offered on a sent message")
        XCTAssertNil(RewindPlanner.plan(.edit, from: user.id, in: t.lines, editedPrompt: " second "), "unchanged edit")
        XCTAssertNil(RewindPlanner.plan(.edit, from: user.id, in: t.lines, editedPrompt: "  "))
        let e = RewindPlanner.plan(.edit, from: user.id, in: t.lines, editedPrompt: "better")
        XCTAssertEqual(e?.text, "better")
        XCTAssertEqual(e?.sourceText, "second", "the original text is the row-id lookup key")
        let skip = RewindPlanner.plan(.regenerate, from: reply.id, in: t.lines) { $0.text != "second" }
        XCTAssertEqual(skip?.text, "first", "lines that are not prompts are skipped")
    }

    func testResolveRowIdByContentLikeDesktop() {
        let rows = [HistoryRow(role: "user", text: "hi", rowId: 1), HistoryRow(role: "assistant", text: "a", rowId: 2),
                    HistoryRow(role: "user", text: "marker", rowId: 3, displayKind: "timeline"),
                    HistoryRow(role: "user", text: "hi", rowId: 4), HistoryRow(role: "user", text: "solo", rowId: 5)]
        XCTAssertEqual(RewindPlanner.resolveRowId("solo", ordinal: 2, history: rows), 5)
        XCTAssertNil(RewindPlanner.resolveRowId("hi", ordinal: 0, history: rows), "ambiguous and not the latest turn")
        XCTAssertNil(RewindPlanner.resolveRowId("marker", ordinal: 0, history: rows), "timeline rows are not prompts")
        let latest = Array(rows.prefix(4))
        XCTAssertEqual(RewindPlanner.resolveRowId("hi", ordinal: 1, history: latest), 4, "the newest turn wins a tie")
        XCTAssertNil(RewindPlanner.resolveRowId("missing", ordinal: 0, history: rows))
    }

    // MARK: transcript

    func testSeedKeepsRowIdsAndPrompts() {
        let t = seeded()
        XCTAssertEqual(t.lines.map(\.rowId), [10, 11, 12, 13, 14])
        XCTAssertEqual(t.lines[0].prompt, "first")
        XCTAssertEqual(t.durableRowIds, [10, 11, 12, 13, 14])
    }

    func testBeginRewindCutsBackAndRunsALocalTurn() {
        var t = seeded()
        let first = t.lines[0].id
        XCTAssertTrue(t.beginRewind(at: first, editedText: " edited ", prompt: "edited!"))
        XCTAssertEqual(t.lines.map(\.text), ["edited"])
        XCTAssertEqual(t.lines[0].prompt, "edited!")
        XCTAssertNil(t.lines[0].rowId, "the cut re-inserts the turn as a new row")
        XCTAssertTrue(t.busy)
        XCTAssertTrue(t.turnIsLocal)
        XCTAssertFalse(t.beginRewind(at: first), "not while a turn runs")
        t.bindSentUser(rowId: 99)
        XCTAssertEqual(t.lines[0].rowId, 99)
        t.apply(.delta("new"))
        t.apply(.completed(ChatCompletion(text: "new")))
        XCTAssertEqual(t.lines.map(\.text), ["edited", "new"])
        XCTAssertFalse(t.busy)
        var u = seeded()
        XCTAssertFalse(u.beginRewind(at: u.lines[1].id), "only a user line")
        XCTAssertFalse(u.busy)
    }

    func testSurvivorRebinding() {
        var t = seeded()
        let map: [Int: Int?] = [10: 20, 11: nil]
        t.rebindRowIds(map)
        XCTAssertEqual(t.lines.map(\.rowId), [20, nil, 12, 13, 14], "unnamed rows keep their id")
        t.rebindUserRowIds([30])
        XCTAssertEqual(t.lines.filter { $0.role == .user }.map(\.rowId), [30, nil], "past the list: id cleared")
    }

    func testReceiptParsesMapAndLegacyList() {
        let r = RewindReceipt(["status": "streaming", "survivor_row_id_map": ["10": 20, "11": .null, "x": 1], "user_row_id": 31],
                              truncated: true)
        XCTAssertEqual(r.survivorMap?[10], .some(20))
        XCTAssertEqual(r.survivorMap?[11], .some(nil))
        XCTAssertEqual(r.survivorMap?.count, 2)
        XCTAssertEqual(r.userRowId, 31)
        XCTAssertNil(r.survivorUserIds, "the map wins")
        let legacy = RewindReceipt(["status": "streaming", "survivor_user_row_ids": [5, .null]], truncated: true)
        XCTAssertEqual(legacy.survivorUserIds, [5, nil])
    }

    func testFailedTurnCarriesItsErrorSurface() {
        var t = ChatTranscript()
        _ = t.beginTurn("q")
        t.apply(.completed(ChatCompletion(payload: ["status": "error", "error": "401 bad key", "text": "",
                                                    "error_surface": ["layer": "auth", "code": "auth", "retryable": false,
                                                                      "provider": "openrouter"]])))
        let line = t.lines.last!
        XCTAssertEqual(line.role, .error)
        XCTAssertEqual(line.failure?.source, .turn)
        XCTAssertEqual(line.failure?.message, "401 bad key")
        XCTAssertEqual(line.failure?.surface, ErrorSurface(layer: "auth", code: "auth", retryable: false, provider: "openrouter"))
        t.dismissError(line.id)
        XCTAssertEqual(t.lines.map(\.role), [.user])
        t.dismissError(t.lines[0].id)
        XCTAssertEqual(t.lines.count, 1, "dismiss only removes error lines")
    }

    func testSendFailureAndDisconnectAreMarked() {
        var t = ChatTranscript()
        _ = t.beginTurn("q")
        t.retractUnsent("offline")
        XCTAssertEqual(t.lines.last?.failure?.source, .send)
        _ = t.beginTurn("q2")
        t.apply(.disconnected("gone"))
        XCTAssertEqual(t.lines.last?.failure?.source, .disconnected)
        _ = t.beginTurn("q3")
        t.apply(.error("boom"))
        XCTAssertEqual(t.lines.last?.failure, TurnFailure(source: .event, message: "boom"))
    }

    // MARK: branch count (Desktop `selectBranchMessages`)

    func testBranchCountUsesTheAuthoritativeHistory() {
        let t = seeded()
        let reply = t.lines.first { $0.text == "one" }!
        XCTAssertEqual(BranchPlanner.count(through: reply.id, lines: t.lines, history: nil), 2, "local: user + reply")
        let rows = [HistoryRow(role: "user", text: "hidden note", rowId: 1, displayKind: "hidden"),
                    HistoryRow(role: "user", text: "first", rowId: 10), HistoryRow(role: "assistant", text: "one", rowId: 11),
                    HistoryRow(role: "tool", text: "out", rowId: 12), HistoryRow(role: "user", text: "second", rowId: 13)]
        XCTAssertEqual(BranchPlanner.count(through: reply.id, lines: t.lines, history: rows), 3,
                       "the backend counts every visible user/assistant row, hidden ones too")
        var local = ChatTranscript()
        _ = local.beginTurn("first")
        local.apply(.completed(ChatCompletion(text: "one")))
        let unstamped = local.lines.last!
        XCTAssertEqual(BranchPlanner.count(through: unstamped.id, lines: local.lines, history: rows), 3, "by role + text ordinal")
        XCTAssertNil(BranchPlanner.count(through: t.lines[2].id, lines: t.lines, history: rows), "not from a tool row")
    }

    // MARK: wire

    func testRewindHistoryAndBranchOverTheGateway() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, p in
            switch m {
            case "prompt.submit": return ["status": "streaming", "survivor_row_id_map": ["10": 40], "user_row_id": 41]
            case "session.history": return ["count": 2, "messages": [["role": "user", "text": "first", "row_id": 10],
                                                                      ["role": "assistant", "text": "one", "row_id": 11]]]
            case "session.branch": return ["session_id": "rt-branch", "stored_session_id": "st-branch", "title": "Side quest",
                                           "parent": "st-1", "message_count": p["count"] ?? .null,
                                           "messages": [["role": "user", "text": "first"], ["role": "assistant", "text": "one"]],
                                           "info": ["model": "m1", "provider": "anthropic"]]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)

        let rows = try await s.historyRows()
        XCTAssertEqual(rows.map(\.rowId), [10, 11])
        XCTAssertEqual(params(gw, "session.history"), ["session_id": "rt-1"])

        let receipt = try await s.rewind(text: "first", rowId: 10, confirmDeep: false, rebind: [10, 11])
        XCTAssertEqual(receipt.userRowId, 41)
        XCTAssertEqual(receipt.survivorMap?[10], .some(40))
        XCTAssertEqual(params(gw, "prompt.submit"), ["session_id": "rt-1", "text": "first", "confirm_truncate": true,
                                                     "truncate_before_row_id": 10, "confirm_empty_truncate": true,
                                                     "rebind_survivor_row_ids": [10, 11]])

        let b = try await s.branch(count: 2, idempotencyKey: "branch-1-abc")
        XCTAssertEqual(params(gw, "session.branch"), ["session_id": "rt-1", "idempotency_key": "branch-1-abc", "count": 2])
        XCTAssertFalse(b.isCanonical)
        XCTAssertEqual(b.sessionId, "rt-branch")
        XCTAssertEqual(b.storedSessionId, "st-branch")
        XCTAssertEqual(b.title, "Side quest")
        XCTAssertEqual(b.history.map(\.text), ["first", "one"])
        XCTAssertEqual(b.openInfo?.model, "m1")
        let events = Collector<ChatEvent>()
        b.onEvent { events.add($0) }
        gw.push(["jsonrpc": "2.0", "method": "event",
                 "params": ["type": "message.delta", "session_id": "rt-branch", "payload": ["text": "hi"]]])
        try await Parity.waitUntil { events.all.contains(.delta("hi")) }
        b.detach()
        XCTAssertFalse(Parity.methods(gw).contains("session.close"), "a branch is never closed or deleted by the app")
        XCTAssertFalse(Parity.methods(gw).contains("session.delete"))
    }
}
