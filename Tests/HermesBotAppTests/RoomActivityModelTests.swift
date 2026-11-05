import Combine
import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

// MARK: - fakes

/// Scripted `bot-activity` REST side. `activity` answers come from `pages` in order (then empty pages);
/// `holdNext` parks the next call until `release()`.
private actor FakeActivitySource: BotActivitySource {
    var pages: [Result<BotActivityPage, Error>] = []
    var setupResult: Result<BotActivitySetup, Error> = .success(BotActivitySetup(profiles: [], untracked: [], outdated: [], optedOut: []))
    var rollOutResult: Result<BotActivityRollOut, Error> = .success(BotActivityRollOut(results: [], ok: true))
    private(set) var calls: [(room: String, since: Int)] = []
    private(set) var setupCalls = 0
    private(set) var rollOutCalls = 0
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    func script(_ p: [Result<BotActivityPage, Error>]) { pages = p }
    func setSetup(_ r: Result<BotActivitySetup, Error>) { setupResult = r }
    func setRollOut(_ r: Result<BotActivityRollOut, Error>) { rollOutResult = r }
    func hold() { holdNext = true }
    func release() { gate?.resume(); gate = nil }
    var callCount: Int { calls.count }
    var rooms: [String] { calls.map(\.room) }
    var sinces: [Int] { calls.map(\.since) }

    func page(room: String, since: Int) async throws -> BotActivityPage {
        calls.append((room, since))
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if pages.isEmpty { return BotActivityPage(rows: [], rev: since, now: nil, since: since, limit: 300) }
        return try pages.removeFirst().get()
    }

    func setup() async throws -> BotActivitySetup {
        setupCalls += 1
        return try setupResult.get()
    }

    func rollOutAll() async throws -> BotActivityRollOut {
        rollOutCalls += 1
        return try rollOutResult.get()
    }
}

private actor FakeInstaller: BotActivityInstaller {
    var state: BotActivityPluginManager.State = .notInstalled
    var failure: Error?
    private(set) var calls: [String] = []

    func set(_ s: BotActivityPluginManager.State) { state = s }
    func fail(_ e: Error?) { failure = e }

    func pluginState() async throws -> BotActivityPluginManager.State { calls.append("state"); return state }
    func install() async throws { calls.append("install"); if let failure { throw failure } }
    func turnOn() async throws { calls.append("turnOn"); if let failure { throw failure } }
    func remove() async throws { calls.append("remove"); if let failure { throw failure } }
}

// MARK: - tests

@MainActor
final class RoomActivityModelTests: XCTestCase {
    private let members = [RoomMember(memberId: "alice", profile: "alice", handle: "alice", displayName: "Alice"),
                           RoomMember(memberId: "m-bob", profile: "bob", handle: "bob")]
    private let missing = PluginREST.Failure.pluginUnavailable(plugin: "bot-activity")

    private func row(_ key: String, rev: Int, ts: Double = 100, updated: Double? = nil, member: String? = nil,
                     bot: String? = "alice", kind: String = "tool", status: String? = "ok", title: String? = "terminal",
                     args: JSONValue? = nil, result: JSONValue? = nil, text: String? = nil, durationMs: Int? = nil) -> BotActivityRow {
        BotActivityRow(key: key, rev: rev, ts: ts, updated: updated ?? ts, bot: bot, roomId: "hba-r1", memberId: member,
                       kind: kind, status: status, title: title, args: args, result: result, text: text, durationMs: durationMs)
    }

    private func page(_ rows: [BotActivityRow], rev: Int, since: Int, now: Double? = nil) -> BotActivityPage {
        BotActivityPage(rows: rows, rev: rev, now: now, since: since, limit: 300)
    }

    private func make(_ source: FakeActivitySource, _ installer: FakeInstaller = FakeInstaller(),
                      room: String = "hba-r1") -> RoomActivityModel {
        RoomActivityModel(roomId: room, members: members, source: source, installer: installer, interval: .milliseconds(20))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: polling

    func testFirstPageThenIncrementalMerge() async {
        let source = FakeActivitySource()
        await source.script([
            .success(page([row("a", rev: 1, ts: 100, status: "running"), row("b", rev: 2, ts: 101, bot: "bob", title: "read_file")],
                          rev: 2, since: 0)),
            .success(page([row("a", rev: 3, ts: 100, updated: 105, status: "ok", durationMs: 1500)], rev: 3, since: 2)),
        ])
        let m = make(source)
        await m.poll()
        XCTAssertEqual(m.pluginState, .ready)
        XCTAssertTrue(m.loaded)
        XCTAssertEqual(m.memberActivity.map(\.id), ["alice", "m-bob"], "room member order")
        XCTAssertEqual(m.memberActivity[0].items.first?.line?.tool?.state, .running)
        let firstId = m.memberActivity[0].items.first?.line?.id
        await m.poll()
        let sinces = await source.sinces
        XCTAssertEqual(sinces, [0, 2], "first page since 0, then from the cursor")
        let tool = m.memberActivity[0].items.first?.line
        XCTAssertEqual(tool?.tool?.state, .done, "the later rev replaced the running row")
        XCTAssertEqual(tool?.tool?.duration, 1.5)
        XCTAssertEqual(tool?.id, firstId, "the row keeps its line identity (disclosure state) across revs")
        XCTAssertEqual(m.memberActivity[1].items.map(\.id), ["b"])
        let setupCalls = await source.setupCalls
        XCTAssertEqual(setupCalls, 1, "setup is checked once per load")
    }

    func testPollingStopsWhenHiddenAndDropsTheInFlightAnswer() async {
        let source = FakeActivitySource()
        await source.script([.success(page([row("a", rev: 1)], rev: 1, since: 0))])
        await source.hold()
        let m = make(source)
        m.start()
        XCTAssertTrue(m.isPolling)
        await waitUntil("the first poll") { await source.callCount == 1 }
        m.stop()  // panel hidden while the request is in flight
        XCTAssertFalse(m.isPolling)
        await source.release()
        await waitUntil("the stale answer to be dropped") { m.droppedStale == 1 }
        XCTAssertFalse(m.loaded, "a poll of a stopped loop never writes")
        XCTAssertEqual(m.pluginState, .unknown)
        XCTAssertTrue(m.memberActivity.allSatisfy { $0.items.isEmpty })
        try? await Task.sleep(for: .milliseconds(120))
        let calls = await source.callCount
        XCTAssertEqual(calls, 1, "no poll after stop")
    }

    func testPollsRepeatWhileShown() async {
        let source = FakeActivitySource()
        let m = make(source)
        m.start()
        await waitUntil("three polls") { await source.callCount >= 3 }
        m.stop()
        XCTAssertEqual(m.pluginState, .ready)
    }

    func testRoomSwitchStopsTheOldRoomAndTheNewOnePollsItsOwnRoom() async {
        let source = FakeActivitySource()
        await source.script([.success(page([row("a", rev: 1)], rev: 1, since: 0))])
        await source.hold()
        let old = make(source, room: "hba-r1")
        let new = make(source, room: "hba-r2")
        old.start()
        await waitUntil("the old room's poll") { await source.callCount == 1 }
        old.stop()  // the room pane is replaced
        new.start()
        await waitUntil("the new room's poll") { await source.callCount >= 2 }
        await source.release()
        await waitUntil("the old answer to be dropped") { old.droppedStale == 1 }
        new.stop()
        XCTAssertFalse(old.loaded)
        let rooms = await source.rooms
        XCTAssertEqual(rooms.first, "hba-r1")
        XCTAssertTrue(rooms.dropFirst().allSatisfy { $0 == "hba-r2" }, "each model asks only for its own room: \(rooms)")
    }

    func testShutdownNeverRestarts() async {
        let m = make(FakeActivitySource())
        m.shutdown()
        m.start()
        XCTAssertFalse(m.isPolling)
    }

    // MARK: plugin state

    func testPluginUnavailableMeansPluginMissingAndClearsTheFeed() async {
        let source = FakeActivitySource()
        await source.script([.success(page([row("a", rev: 1)], rev: 1, since: 0)), .failure(missing)])
        let m = make(source)
        await m.poll()
        XCTAssertTrue(m.loaded)
        let wait = await m.poll()
        XCTAssertEqual(m.pluginState, .pluginMissing)
        XCTAssertFalse(m.loaded)
        XCTAssertTrue(m.canEnable)
        XCTAssertTrue(m.memberActivity.allSatisfy { $0.items.isEmpty })
        XCTAssertEqual(m.feed.cursor, 0, "a later install starts from the most recent rows again")
        XCTAssertGreaterThan(wait, .milliseconds(20), "errors back off")
    }

    func testOtherErrorsAreShownRedactedAndClearedByTheNextSuccess() async {
        let source = FakeActivitySource()
        await source.script([.failure(PluginREST.Failure.http(status: 500, detail: "boom")), .success(page([], rev: 0, since: 0))])
        let m = make(source)
        await m.poll()
        guard case .error(let text) = m.pluginState else { return XCTFail("expected .error, got \(m.pluginState)") }
        XCTAssertTrue(text.contains("HTTP 500"), text)
        await m.poll()
        XCTAssertEqual(m.pluginState, .ready)
    }

    func testUntrackedOrOutdatedBotsAskForRollOut() async {
        let source = FakeActivitySource()
        await source.setSetup(.success(BotActivitySetup(profiles: [], untracked: ["carol", "bob"], outdated: ["dave"], optedOut: ["eve"])))
        let m = make(source)
        await m.poll()
        XCTAssertEqual(m.pluginState, .needsRollOut(["bob", "carol", "dave"]))
        await source.setSetup(.success(BotActivitySetup(profiles: [], untracked: [], outdated: [], optedOut: ["eve"])))
        await m.rollOut()
        let rollOuts = await source.rollOutCalls
        XCTAssertEqual(rollOuts, 1)
        XCTAssertEqual(m.pluginState, .ready, "setup is checked again after the roll-out")
        XCTAssertNil(m.actionError)
    }

    func testFailedSetupCheckKeepsTheFeedReady() async {
        let source = FakeActivitySource()
        await source.setSetup(.failure(PluginREST.Failure.http(status: 404, detail: "x")))
        let m = make(source)
        await m.poll()
        XCTAssertEqual(m.pluginState, .ready)
    }

    // MARK: enable / turn off

    func testEnableInstallsRollsOutAndPollsAgain() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await source.script([.failure(missing), .success(page([row("a", rev: 1)], rev: 1, since: 0))])
        let m = make(source, installer)
        await m.poll()
        XCTAssertEqual(m.pluginState, .pluginMissing)
        var seen: [RoomActivityModel.PluginState] = []
        let sink = m.$pluginState.sink { seen.append($0) }
        await m.enable()
        sink.cancel()
        let calls = await installer.calls
        XCTAssertEqual(calls, ["state", "install"])
        let rollOuts = await source.rollOutCalls
        XCTAssertEqual(rollOuts, 1, "rolled out to every bot after the install")
        XCTAssertTrue(seen.contains(.enabling))
        XCTAssertEqual(m.pluginState, .ready)
        XCTAssertTrue(m.loaded)
        XCTAssertNil(m.enableStage)
        XCTAssertNil(m.actionError)
    }

    func testEnableTurnsOnAnInstalledButDisabledCopy() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await installer.set(.installed(status: "disabled", version: "0.1.0", source: "user"))
        let m = make(source, installer)
        await m.enable()
        let calls = await installer.calls
        XCTAssertEqual(calls, ["state", "turnOn"])
        XCTAssertEqual(m.pluginState, .ready)
    }

    func testEnableFailureKeepsTheFallbackAndSaysWhy() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await installer.fail(GatewayClient.RPCError(code: 5026, message: "install failed: git not found", data: nil))
        await source.script([.failure(missing), .failure(missing)])
        let m = make(source, installer)
        await m.poll()
        await m.enable()
        let rollOuts = await source.rollOutCalls
        XCTAssertEqual(rollOuts, 0, "no roll-out after a failed install")
        XCTAssertEqual(m.pluginState, .pluginMissing)
        XCTAssertTrue(m.actionError?.hasPrefix("Couldn't enable activity tracking") == true, m.actionError ?? "nil")
        XCTAssertTrue(m.actionError?.contains("git not found") == true)
        m.dismissActionError()
        XCTAssertNil(m.actionError)
    }

    func testPartialRollOutNamesTheBotsThatFailed() async throws {
        let source = FakeActivitySource()
        let failed = try XCTUnwrap(BotActivityRollOut.Result(json: ["bot": "bob", "ok": false, "error": "read-only profile"]))
        await source.setRollOut(.success(BotActivityRollOut(results: [failed], ok: false)))
        let m = make(source)
        await m.enable()
        XCTAssertEqual(m.actionError, "Activity tracking could not be turned on for: bob (read-only profile).")
    }

    func testTurnOffRemovesThePluginAndFallsBack() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await source.script([.success(page([row("a", rev: 1)], rev: 1, since: 0))])
        let m = make(source, installer)
        await m.poll()
        XCTAssertTrue(m.loaded)
        await m.turnOff()
        let calls = await installer.calls
        XCTAssertEqual(calls, ["remove"])
        XCTAssertEqual(m.pluginState, .pluginMissing)
        XCTAssertFalse(m.loaded)
        XCTAssertTrue(m.memberActivity.allSatisfy { $0.items.isEmpty })
    }

    func testTurnOffFailureKeepsTrackingOn() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await installer.fail(PluginREST.Failure.transport("socket closed"))
        let m = make(source, installer)
        await m.poll()
        await m.turnOff()
        XCTAssertEqual(m.pluginState, .ready)
        XCTAssertTrue(m.actionError?.contains("Couldn't turn off") == true)
    }

    // MARK: mapping

    func testRowsMapToMembersByMemberIdThenBotProfile() {
        let rows = [
            row("1", rev: 1, member: "m-bob", bot: "alice"),   // member_id wins
            row("2", rev: 2, member: nil, bot: "alice"),       // bot profile → alice
            row("3", rev: 3, member: "unknown", bot: "bob"),   // not a member id → bot profile → m-bob
            row("4", rev: 4, member: nil, bot: "stranger"),    // a bot not in the room: ignored
            row("5", rev: 5, member: nil, bot: nil),           // nothing to map: ignored
        ]
        XCTAssertEqual(rows.map { RoomActivityModel.memberId(for: $0, members: members) }, ["m-bob", "alice", "m-bob", nil, nil])
        let built = RoomActivityModel.memberActivity(rows: rows, members: members, now: 200)
        XCTAssertEqual(built.members.map(\.id), ["alice", "m-bob"])
        XCTAssertEqual(built.members[0].items.map(\.id), ["2"])
        XCTAssertEqual(built.members[1].items.map(\.id), ["3", "1"], "newest first")
        XCTAssertEqual(Set(built.lines.keys), ["1", "2", "3"], "only kept rows keep a line")
    }

    func testMemberPhaseAndCurrentRow() {
        let rows = [row("t", rev: 1, ts: 190, status: "running"), row("old", rev: 2, ts: 10, status: "running")]
        let a = RoomActivityModel.memberActivity(rows: rows, members: members, now: 200).members[0]
        XCTAssertEqual(a.phase, .running)
        XCTAssertEqual(a.current?.key, "t")
        let idle = RoomActivityModel.memberActivity(rows: rows, members: members, now: 200).members[1]
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertNil(idle.current)
        XCTAssertTrue(idle.items.isEmpty)
    }

    // MARK: presentation

    func testToolRowBecomesTheBotChatToolRowInput() {
        let r = row("tool:1", rev: 1, title: "terminal", args: ["command": "cd /tmp && git status 2>&1 | tail -5"],
                    result: ["output": "clean", "exit_code": 0], durationMs: 1200)
        let item = ActivityPresentation.item(r, now: 200)
        let line = try? XCTUnwrap(item.line)
        XCTAssertEqual(line?.role, .tool)
        XCTAssertEqual(line?.tool?.name, "terminal")
        XCTAssertEqual(line?.tool?.state, .done)
        XCTAssertEqual(line?.tool?.duration, 1.2)
        let p = ToolRowPresentation(line!)
        XCTAssertEqual(p.title, "Ran git status")
        XCTAssertEqual(p.duration, "1.2s")
        XCTAssertTrue(p.expandable)
        XCTAssertTrue(p.details.contains(.code(label: "Output", language: nil, text: "clean")))
        XCTAssertFalse(item.isError)

        let failed = ActivityPresentation.item(row("tool:2", rev: 2, status: "error", title: "read_file",
                                                   args: ["path": "/x"], result: ["error": "no such file"]), now: 200)
        XCTAssertEqual(failed.line?.tool?.state, .failed)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(ToolRowPresentation(failed.line!).title, "Read /x")

        let running = ActivityPresentation.item(row("tool:3", rev: 3, status: "running", title: nil, result: .string("raw text")), now: 200)
        XCTAssertEqual(running.line?.tool?.state, .running)
        XCTAssertEqual(running.line?.tool?.name, "tool")
        XCTAssertEqual(running.line?.tool?.result, .string("raw text"), "a non-JSON result stays the raw string")
    }

    func testOtherKindsBecomePanelRows() {
        let thinking = ActivityPresentation.item(row("r", rev: 1, ts: 190, updated: 195, kind: "reasoning", status: "streaming",
                                                     title: "reasoning", text: "  hmm  "), now: 200)
        XCTAssertEqual(thinking.line?.role, .thought)
        XCTAssertEqual(thinking.line?.text, "hmm")
        XCTAssertEqual(thinking.line?.streaming, true)
        let quiet = ActivityPresentation.item(row("r", rev: 1, ts: 100, kind: "reasoning", status: "streaming", text: "x"), now: 200)
        XCTAssertEqual(quiet.line?.streaming, false, "a stream quiet for 30 s is done")
        XCTAssertEqual(ActivityPresentation.item(row("m", rev: 1, ts: 199, kind: "message", status: "streaming", text: "Hello"), now: 200).kind,
                       .message(text: "Hello", streaming: true))
        XCTAssertEqual(ActivityPresentation.item(row("u", rev: 1, kind: "turn", status: "done", title: "fix the bug", durationMs: 4200), now: 200).kind,
                       .turn(title: "fix the bug", finished: true, duration: "4.2s"))
        XCTAssertEqual(ActivityPresentation.item(row("u2", rev: 1, kind: "turn", status: "running", title: nil), now: 200).kind,
                       .turn(title: nil, finished: false, duration: nil))
        let error = ActivityPresentation.item(row("e", rev: 1, kind: "error", status: "error", title: "Rate limited", text: "{}"), now: 200)
        XCTAssertEqual(error.kind, .error(title: "Rate limited", detail: "{}"))
        XCTAssertTrue(error.isError)
        XCTAssertEqual(ActivityPresentation.item(row("p", rev: 1, kind: "approval", status: "waiting", title: "rm -rf build"), now: 200).kind,
                       .approval(title: "rm -rf build", status: "waiting for approval"))
        XCTAssertEqual(ActivityPresentation.item(row("w", rev: 1, kind: "warning", status: "warn", title: "Tool output flagged"), now: 200).kind,
                       .other(title: "Tool output flagged", status: "warn"))
    }

    func testPhaseChipsAndCurrentText() {
        XCTAssertEqual(ActivityPresentation.status(.waiting, current: nil).tone, .attention)
        XCTAssertEqual(ActivityPresentation.status(.waiting, current: nil).label, "waiting for approval")
        XCTAssertEqual(ActivityPresentation.status(.running, current: nil), ActivityStatus(label: "working", symbol: nil, tone: .working))
        XCTAssertEqual(ActivityPresentation.status(.streaming, current: row("r", rev: 1, kind: "reasoning")).label, "thinking")
        XCTAssertEqual(ActivityPresentation.status(.streaming, current: row("m", rev: 1, kind: "message")).label, "writing")
        XCTAssertEqual(ActivityPresentation.status(.idle, current: nil).label, "idle")
        let current = row("t", rev: 1, ts: 188, status: "running", title: "terminal", args: ["command": "npm test"])
        XCTAssertEqual(ActivityPresentation.currentText(current, now: 200), "Ran npm test · 12s")
    }

    // MARK: fallback (C1.3)

    func testFallbackStatusesComeFromTheTimeline() throws {
        let room = try XCTUnwrap(RoomSummary([
            "room_id": "hba-r1", "name": "Test",
            "members": [["member_id": "alice", "profile": "alice", "handle": "alice"],
                        ["member_id": "m-bob", "profile": "bob", "handle": "bob"],
                        ["member_id": "carol", "profile": "carol", "handle": "carol"]],
        ]))
        func turn(_ seq: Int, _ kind: String, _ m: String) -> RoomEvent {
            RoomEvent(seq: seq, eventId: "t\(seq)", kind: kind, actor: ["kind": "gateway", "id": "x"],
                      payload: ["member_id": .string(m), "discussion_event_id": "user:aaa", "thread_id": "main", "task_id": .string("k\(seq)")])
        }
        var timeline = RoomTimeline()
        timeline.apply(RoomLogPage(events: [
            RoomEvent(seq: 1, eventId: "user:aaa", kind: "message.user", actor: ["kind": "user", "id": "desktop"],
                      payload: ["text": "hi", "thread_id": "main"]),
            turn(2, "turn.settled", "alice"),
            turn(3, "turn.failed", "m-bob"),
        ], cursor: 3, latestSeq: 3, hasMore: false))
        let approval = RoomApproval(memberId: "carol", taskId: "k9", executionGeneration: 1, requestId: "r1", choices: ["once", "deny"],
                                    command: "ls", description: nil)
        let driver = RoomDriverStatus(working: true, pendingActions: [.approval(approval)])
        let statuses = ActivityPresentation.fallbackStatuses(room: room, timeline: timeline, driver: driver)
        let ribbon = RoomPresentation.memberStates(room: room, timeline: timeline, driver: driver)
        XCTAssertEqual(ribbon, ["alice": .replied, "m-bob": .failed, "carol": .needsApproval])
        XCTAssertEqual(statuses["alice"], ActivityStatus(label: "replied", symbol: "checkmark", tone: .done))
        XCTAssertEqual(statuses["m-bob"], ActivityStatus(label: "failed", symbol: "exclamationmark.triangle.fill", tone: .danger))
        XCTAssertEqual(statuses["carol"], ActivityStatus(label: "needs approval", symbol: "hand.raised.fill", tone: .attention))
        for (id, state) in ribbon { XCTAssertEqual(statuses[id]?.label, state.label, "the panel says what the ribbon says") }
    }

    func testEnableSheetLinksThePinnedCommit() {
        XCTAssertEqual(EnableActivitySheet.sourceURL.absoluteString,
                       "https://github.com/risyadul/hermes-bot-activity/tree/" + BotActivityPluginManager.pinnedRef)
    }
}
