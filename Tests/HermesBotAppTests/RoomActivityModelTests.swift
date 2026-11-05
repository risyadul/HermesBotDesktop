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
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    func set(_ s: BotActivityPluginManager.State) { state = s }
    func fail(_ e: Error?) { failure = e }
    /// Parks the next `install` or `remove` until `release()`.
    func hold() { holdNext = true }
    func release() { gate?.resume(); gate = nil }
    var parked: Bool { gate != nil }

    private func parkIfHeld() async {
        guard holdNext else { return }
        holdNext = false
        await withCheckedContinuation { gate = $0 }
    }

    func pluginState() async throws -> BotActivityPluginManager.State { calls.append("state"); return state }
    func install(force: Bool) async throws {
        calls.append(force ? "install(force)" : "install")
        await parkIfHeld()
        if let failure { throw failure }
    }
    func turnOn() async throws { calls.append("turnOn"); if let failure { throw failure } }
    func remove() async throws {
        calls.append("remove")
        await parkIfHeld()
        if let failure { throw failure }
    }
}

/// Stands in for `hermes -p <bot> plugins enable|disable bot-activity`; never runs anything.
private actor FakeProfiles: BotActivityProfileToggle {
    private(set) var calls: [String] = []
    var failing: [String: String] = [:]

    func fail(_ bot: String, _ why: String) { failing[bot] = why }

    func setEnabled(_ enable: Bool, bot: String) async throws {
        calls.append("\(enable ? "enable" : "disable") \(bot)")
        if let why = failing[bot] { throw BotActivityProfileSwitch.Failure(description: why) }
    }
}

private func profile(_ bot: String, installed: Bool = true, enabled: Bool = true, optedOut: Bool = false) -> BotActivitySetup.Profile {
    BotActivitySetup.Profile(json: ["bot": .string(bot), "installed": .bool(installed), "enabled": .bool(enabled),
                                    "opted_out": .bool(optedOut)])!
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

    private func make(_ source: FakeActivitySource, _ installer: FakeInstaller = FakeInstaller(), profiles: FakeProfiles = FakeProfiles(),
                      gate: BotActivityActionGate = BotActivityActionGate(), room: String = "hba-r1") -> RoomActivityModel {
        RoomActivityModel(roomId: room, members: members, source: source, installer: installer, profiles: profiles, gate: gate,
                          interval: .milliseconds(20))
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

    func testTryAgainRestartsTheLoopWithTheBackoffReset() async {
        let source = FakeActivitySource()
        let boom = PluginREST.Failure.http(status: 500, detail: "boom")
        await source.script([.failure(boom), .failure(boom), .failure(boom)])
        // A long interval: after a failure the loop would wait (at least) 20 s before polling again.
        let m = RoomActivityModel(roomId: "hba-r1", members: members, source: source, installer: FakeInstaller(),
                                  profiles: FakeProfiles(), gate: BotActivityActionGate(), interval: .seconds(10))
        m.start()
        await waitUntil("the first failure") { m.failures == 1 }
        guard case .error = m.pluginState else { return XCTFail("expected .error, got \(m.pluginState)") }
        let gen = m.generation
        m.retry()
        XCTAssertTrue(m.isPolling)
        XCTAssertGreaterThan(m.generation, gen, "a fresh loop: the old one's answers are dropped")
        await waitUntil("the retry's poll") { await source.callCount == 2 }
        await waitUntil("its failure") { m.failures == 1 }
        XCTAssertEqual(m.failures, 1, "the backoff restarted from zero, not counted twice")
        m.retry()
        await waitUntil("another poll") { await source.callCount == 3 }
        m.stop()
        let calls = await source.callCount
        XCTAssertEqual(calls, 3, "one poll per Try Again, never a second loop beside the first")
        m.retry()
        XCTAssertFalse(m.isPolling, "the panel is closed: Try Again does not start polling")
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

    func testFailedSetupCheckIsNotRetriedOnEveryPoll() async {
        let source = FakeActivitySource()
        await source.setSetup(.failure(PluginREST.Failure.http(status: 500, detail: "x")))
        let m = make(source)
        for _ in 0..<5 { await m.poll() }
        let polls = await source.callCount
        XCTAssertEqual(polls, 5)
        var setupCalls = await source.setupCalls
        XCTAssertEqual(setupCalls, 1, "a failed setup check waits \(RoomActivityModel.setupRetryDelay) before the next")
        XCTAssertGreaterThanOrEqual(RoomActivityModel.setupRetryDelay, .seconds(60))
        XCTAssertEqual(m.pluginState, .ready)

        // An action checks again at once (its own GET /setup, then the follow-up poll's).
        await source.setSetup(.success(BotActivitySetup(profiles: [], untracked: ["bob"], outdated: [], optedOut: [])))
        await m.rollOut()
        setupCalls = await source.setupCalls
        XCTAssertEqual(setupCalls, 2, "the poll after the action re-checks setup")
        XCTAssertEqual(m.pluginState, .needsRollOut(["bob"]))
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

    func testEnableTurnsOnAnInstalledButDisabledPinnedCopy() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await installer.set(.installed(status: "disabled", version: "0.1.0", source: "user", pinnedSHA: BotActivityPluginManager.pinnedRef))
        let m = make(source, installer)
        await m.enable()
        let calls = await installer.calls
        XCTAssertEqual(calls, ["state", "turnOn"])
        XCTAssertEqual(m.pluginState, .ready)
    }

    func testEnableNeverTurnsOnACopyThatIsNotTheReviewedCommit() async {
        for sha: String? in [nil, "0000000000000000000000000000000000000000"] {
            let source = FakeActivitySource()
            let installer = FakeInstaller()
            await source.script([.failure(missing), .failure(missing)])
            await installer.set(.installed(status: "disabled", version: "0.1.0", source: "user", pinnedSHA: sha))
            let m = make(source, installer)
            await m.poll()
            await m.enable()
            XCTAssertEqual(m.pluginState, .unpinnedCopy, "sha \(sha ?? "nil")")
            XCTAssertFalse(m.canEnable, "Reinstall Pinned Version is the way on")
            let calls = await installer.calls
            XCTAssertEqual(calls, ["state"], "never toggled")
            let v1 = await source.rollOutCalls
            XCTAssertEqual(v1, 0)
            await m.poll()
            XCTAssertEqual(m.pluginState, .unpinnedCopy, "a missing-plugin poll keeps the warning")

            await m.reinstallPinned()
            let after = await installer.calls
            XCTAssertEqual(after, ["state", "install(force)"], "reinstall replaces the copy with the pinned commit")
            let v2 = await source.rollOutCalls
            XCTAssertEqual(v2, 1)
            XCTAssertEqual(m.pluginState, .ready)
        }
    }

    func testReinstallFailureKeepsTheWarning() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await source.script([.failure(missing), .failure(missing)])
        await installer.set(.installed(status: "disabled", version: "0.1.0", source: "user", pinnedSHA: nil))
        let m = make(source, installer)
        await m.enable()
        await installer.fail(GatewayClient.RPCError(code: 5026, message: "clone failed", data: nil))
        await m.reinstallPinned()
        XCTAssertEqual(m.pluginState, .unpinnedCopy)
        XCTAssertTrue(m.actionError?.hasPrefix("Couldn't reinstall") == true, m.actionError ?? "nil")
    }

    func testAReinstalledCopyIsNoLongerFlaggedEvenIfNotLiveYet() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await source.script([.failure(missing), .failure(missing)])
        await source.setSetup(.failure(missing))
        await installer.set(.installed(status: "disabled", version: "0.1.0", source: "user", pinnedSHA: nil))
        let m = make(source, installer)
        await m.enable()
        XCTAssertEqual(m.pluginState, .unpinnedCopy)
        await m.reinstallPinned()
        XCTAssertEqual(m.pluginState, .pluginMissing, "the pinned commit is installed; Enable can finish the roll-out")
        XCTAssertTrue(m.canEnable)
        XCTAssertNotNil(m.actionError)
    }

    func testEnableTurnsOptedOutBotsBackOnBeforeRollingOut() async {
        let source = FakeActivitySource()
        let profiles = FakeProfiles()
        await profiles.fail("eve", "Plugin 'bot-activity' not found")
        await source.setSetup(.success(BotActivitySetup(profiles: [profile("alice"), profile("bob", optedOut: true)], untracked: [],
                                                        outdated: [], optedOut: ["bob", "eve"])))
        let m = make(source, profiles: profiles)
        await m.enable()
        let calls = await profiles.calls
        XCTAssertEqual(calls, ["enable bob", "enable eve"])
        let v3 = await source.rollOutCalls
        XCTAssertEqual(v3, 1, "then POST /setup refreshes and enables the rest")
        XCTAssertEqual(m.actionError, "Activity tracking could not be turned on for: eve (Plugin 'bot-activity' not found).")
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

    func testTurnOffDisablesEveryProfileThenRemovesTheRootCopy() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        let profiles = FakeProfiles()
        await source.script([.success(page([row("a", rev: 1)], rev: 1, since: 0))])
        await source.setSetup(.success(BotActivitySetup(
            profiles: [profile("default"), profile("alice"), profile("bob", enabled: false, optedOut: true),
                       profile("carol", installed: false, enabled: false)],
            untracked: ["carol"], outdated: [], optedOut: ["bob"])))
        let m = make(source, installer, profiles: profiles)
        await m.poll()
        XCTAssertTrue(m.loaded)
        await m.turnOff()
        let disabled = await profiles.calls
        XCTAssertEqual(disabled, ["disable default", "disable alice", "disable bob"], "every profile with a copy; carol has none")
        let calls = await installer.calls
        XCTAssertEqual(calls, ["remove"])
        XCTAssertEqual(m.pluginState, .pluginMissing)
        XCTAssertNil(m.actionError)
        XCTAssertFalse(m.loaded)
        XCTAssertTrue(m.memberActivity.allSatisfy { $0.items.isEmpty })
    }

    func testTurnOffReportsBotsItCouldNotDisable() async {
        let source = FakeActivitySource()
        let profiles = FakeProfiles()
        await profiles.fail("bob", "timed out")
        await source.setSetup(.success(BotActivitySetup(profiles: [profile("alice"), profile("bob")], untracked: [], outdated: [], optedOut: [])))
        let m = make(source, profiles: profiles)
        await m.poll()
        await m.turnOff()
        XCTAssertEqual(m.pluginState, .pluginMissing, "the root copy is gone")
        XCTAssertEqual(m.actionError, "Activity tracking was removed, but could not be turned off for: bob (timed out).")
    }

    func testTurnOffFailureKeepsTrackingOn() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        let profiles = FakeProfiles()
        await profiles.fail("bob", "read-only config")
        await source.setSetup(.success(BotActivitySetup(profiles: [profile("bob")], untracked: [], outdated: [], optedOut: [])))
        await installer.fail(PluginREST.Failure.transport("socket closed"))
        let m = make(source, installer, profiles: profiles)
        await m.poll()
        await m.turnOff()
        XCTAssertEqual(m.pluginState, .ready, "only a removed root copy ends in .pluginMissing")
        XCTAssertTrue(m.actionError?.hasPrefix("Couldn't turn off activity tracking") == true, m.actionError ?? "nil")
        XCTAssertTrue(m.actionError?.contains("bob (read-only config)") == true, m.actionError ?? "nil")
    }

    func testTurnOffWithoutTheBotListChangesNothing() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        await source.setSetup(.failure(PluginREST.Failure.http(status: 500, detail: "x")))
        let m = make(source, installer)
        await m.turnOff()
        let calls = await installer.calls
        XCTAssertEqual(calls, [], "never removes the root copy while bot copies would keep recording")
        XCTAssertTrue(m.actionError?.contains("couldn't list the bots") == true, m.actionError ?? "nil")
    }

    // MARK: app-wide gate

    func testASecondRoomJoinsTheEnableInFlight() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        let gate = BotActivityActionGate()
        await installer.hold()
        let a = make(source, installer, gate: gate, room: "hba-r1")
        let b = make(source, installer, gate: gate, room: "hba-r2")
        let first = Task { await a.enable() }
        await waitUntil("the install to start") { await installer.parked }
        XCTAssertTrue(gate.isBusy)
        XCTAssertEqual(gate.action, .enable)
        let second = Task { await b.enable() }
        await waitUntil("room 2 to join") { b.pluginState == .enabling }
        XCTAssertEqual(b.enableStage, .installing, "room 2 shows the same progress")
        let before = await source.callCount
        await b.poll()
        let v4 = await source.callCount
        XCTAssertEqual(v4, before, "no room polls while the action runs")
        await installer.release()
        await first.value
        await second.value
        let calls = await installer.calls
        XCTAssertEqual(calls, ["state", "install"], "one install for both rooms")
        let v5 = await source.rollOutCalls
        XCTAssertEqual(v5, 1)
        XCTAssertEqual(a.pluginState, .ready)
        XCTAssertEqual(b.pluginState, .ready)
        XCTAssertFalse(gate.isBusy)
        XCTAssertNil(gate.action)
    }

    func testTurnOffFromAnotherRoomIsRefusedWhileEnableRuns() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        let profiles = FakeProfiles()
        let gate = BotActivityActionGate()
        await source.setSetup(.success(BotActivitySetup(profiles: [profile("alice")], untracked: [], outdated: [], optedOut: [])))
        await installer.hold()
        let a = make(source, installer, profiles: profiles, gate: gate, room: "hba-r1")
        let b = make(source, installer, profiles: profiles, gate: gate, room: "hba-r2")
        await a.poll()
        await b.poll()
        let enabling = Task { await a.enable() }
        await waitUntil("the install to start") { await installer.parked }
        let refused = Task { await b.turnOff() }
        // Refused at once, not joined (a join would wait for the parked install).
        await waitUntil("the refusal") { b.actionError != nil }
        XCTAssertEqual(b.actionError, BotActivityActionGate.busyMessage)
        XCTAssertEqual(b.actionError, "Another activity action is running; try again when it finishes.")
        XCTAssertEqual(b.pluginState, .ready, "room 2 neither shows the enable nor a removal")
        XCTAssertEqual(gate.action, .enable)
        await installer.release()
        await enabling.value
        await refused.value
        let calls = await installer.calls
        XCTAssertFalse(calls.contains("remove"), "the refused turn-off never ran")
        let disabled = await profiles.calls
        XCTAssertEqual(disabled, [], "no profile was turned off")
        XCTAssertEqual(a.pluginState, .ready)
    }

    func testASecondRoomJoinsTheTurnOffInFlight() async {
        let source = FakeActivitySource()
        let installer = FakeInstaller()
        let gate = BotActivityActionGate()
        await source.setSetup(.success(BotActivitySetup(profiles: [profile("alice")], untracked: [], outdated: [], optedOut: [])))
        await installer.hold()
        let a = make(source, installer, gate: gate, room: "hba-r1")
        let b = make(source, installer, gate: gate, room: "hba-r2")
        await a.poll()
        await b.poll()
        let first = Task { await a.turnOff() }
        await waitUntil("the remove to start") { await installer.parked }
        let second = Task { await b.turnOff() }
        await waitUntil("room 2 to join") { b.pluginState == .removing }
        await installer.release()
        await first.value
        await second.value
        let calls = await installer.calls
        XCTAssertEqual(calls, ["remove"], "one removal for both rooms")
        XCTAssertEqual(a.pluginState, .pluginMissing)
        XCTAssertEqual(b.pluginState, .pluginMissing, "the joined room gets the same outcome")
        XCTAssertNil(b.actionError)
    }

    func testGateRefusesADifferentActionWithoutRunningIt() async {
        let gate = BotActivityActionGate()
        var release: CheckedContinuation<Void, Never>?
        let first = Task { await gate.run(.enable) { await withCheckedContinuation { release = $0 }; return .init() } }
        await waitUntil("the enable to run") { release != nil }
        var ran = false
        var refused: BotActivityActionGate.Outcome?
        Task { refused = await gate.run(.turnOff) { ran = true; return .init(removed: true) } }
        await waitUntil("the refusal") { refused != nil }  // never waits for the enable's body
        XCTAssertFalse(ran)
        XCTAssertEqual(refused, .init(error: BotActivityActionGate.busyMessage))
        let joined = Task { await gate.run(.enable) { ran = true; return .init(error: "not this one") } }
        release?.resume()
        let out = await first.value
        let joinedOut = await joined.value
        XCTAssertFalse(ran, "the joined enable awaited the first one's body")
        XCTAssertEqual(joinedOut, out)
        XCTAssertFalse(gate.isBusy)
    }

    // MARK: visibility

    func testPollingPausesWhileTheWindowIsNotVisible() async {
        let source = FakeActivitySource()
        let m = make(source)
        m.setVisible(false)
        m.start()
        XCTAssertFalse(m.isPolling, "an occluded window never starts polling")
        m.setVisible(true)
        XCTAssertTrue(m.isPolling, "back on screen: resumes")
        await waitUntil("a poll") { await source.callCount >= 1 }
        m.setVisible(false)
        XCTAssertFalse(m.isPolling)
        let calls = await source.callCount
        try? await Task.sleep(for: .milliseconds(120))
        let later = await source.callCount
        XCTAssertLessThanOrEqual(later, calls + 1, "at most the in-flight poll")
        m.stop()
        m.setVisible(true)
        XCTAssertFalse(m.isPolling, "the panel is closed: visibility alone does not start polling")
        XCTAssertTrue(RoomActivityModel.isOnScreen(occlusion: .visible, appHidden: false))
        XCTAssertFalse(RoomActivityModel.isOnScreen(occlusion: [], appHidden: false))
        XCTAssertFalse(RoomActivityModel.isOnScreen(occlusion: .visible, appHidden: true))
    }

    // MARK: feed memory

    func testRowsOfAnotherRoomAreDropped() async {
        let source = FakeActivitySource()
        let stray = BotActivityRow(key: "x", rev: 2, ts: 100, updated: 100, bot: "alice", roomId: "hba-r2", kind: "tool", status: "ok")
        await source.script([.success(page([row("a", rev: 1), stray], rev: 2, since: 0))])
        let m = make(source)
        await m.poll()
        XCTAssertEqual(m.feed.rows.map(\.key), ["a"])
        XCTAssertEqual(m.memberActivity[0].items.map(\.id), ["a"])
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
        let ribbon = RoomPresentation.memberStates(room: room, timeline: timeline, driver: driver)
        let statuses = ActivityPresentation.fallbackStatuses(room: room, turns: ribbon)
        XCTAssertEqual(ribbon, ["alice": .replied, "m-bob": .failed, "carol": .needsApproval])
        XCTAssertEqual(statuses["alice"], ActivityStatus(label: "replied", symbol: "checkmark", tone: .done))
        XCTAssertEqual(statuses["m-bob"], ActivityStatus(label: "failed", symbol: "exclamationmark.triangle.fill", tone: .danger))
        XCTAssertEqual(statuses["carol"], ActivityStatus(label: "needs approval", symbol: "hand.raised.fill", tone: .attention))
        for (id, state) in ribbon { XCTAssertEqual(statuses[id]?.label, state.label, "the panel says what the ribbon says") }
        let noTurns = ActivityPresentation.fallbackStatuses(room: room, turns: ["alice": .replied])
        XCTAssertEqual(Set(noTurns.keys), ["alice", "m-bob", "carol"], "every member gets a chip")
        XCTAssertEqual(noTurns["m-bob"], ActivityStatus(label: "idle", symbol: nil, tone: .quiet), "no turn state: idle")
    }

    private func roundFixture() throws -> (RoomSummary, (Int, String, String, JSONValue) -> RoomEvent) {
        let room = try XCTUnwrap(RoomSummary([
            "room_id": "hba-r1", "name": "Test",
            "members": [["member_id": "alice", "profile": "alice", "handle": "alice", "display_name": "Alice"],
                        ["member_id": "m-bob", "profile": "bob", "handle": "bob"],
                        ["member_id": "carol", "profile": "carol", "handle": "carol"]],
        ]))
        func turn(_ seq: Int, _ kind: String, _ m: String, _ extra: JSONValue) -> RoomEvent {
            var p: [String: JSONValue] = ["member_id": .string(m), "discussion_event_id": "user:bbb", "thread_id": "main"]
            for (k, v) in extra.object ?? [:] { p[k] = v }
            return RoomEvent(seq: seq, eventId: "t\(seq)", kind: kind, actor: ["kind": "gateway", "id": "x"], payload: .object(p),
                             createdAt: Double(seq))
        }
        return (room, turn)
    }

    func testThisRoundTellsTheLatestRoundNewestFirst() throws {
        let (room, turn) = try roundFixture()
        var timeline = RoomTimeline()
        timeline.apply(RoomLogPage(events: [
            RoomEvent(seq: 1, eventId: "user:aaa", kind: "message.user", payload: ["text": "old", "thread_id": "main"], createdAt: 1),
            RoomEvent(seq: 2, eventId: "t2", kind: "turn.settled", payload: ["member_id": "alice", "discussion_event_id": "user:aaa"], createdAt: 2),
            RoomEvent(seq: 3, eventId: "user:bbb", kind: "message.user", payload: ["text": "hi", "thread_id": "main"], createdAt: 3),
            turn(4, "turn.settled", "alice", [:]),
            turn(5, "turn.settled", "m-bob", ["passed": true]),
            turn(6, "turn.failed", "carol", ["error": "LLM request timed out"]),
        ], cursor: 6, latestSeq: 6, hasMore: false))
        let approval = RoomApproval(memberId: "m-bob", taskId: "k9", executionGeneration: 1, requestId: "r1", choices: ["once", "deny"],
                                    command: "ls", description: nil)
        let driver = RoomDriverStatus(working: true, pendingActions: [.approval(approval)])
        let feed = ActivityPresentation.roundFeed(room: room, timeline: timeline, driver: driver)
        XCTAssertEqual(feed.map(\.title), ["bob", "Round", "carol", "bob", "Alice", "Round"])
        XCTAssertEqual(feed.map(\.status.label), ["needs approval", "working", "timed out", "passed", "replied", "queued"])
        XCTAssertEqual(feed.first?.status.tone, .attention)
        XCTAssertFalse(feed.contains { $0.id == "turn:2" }, "only the latest round")
        let ribbon = RoomPresentation.memberStates(room: room, timeline: timeline, driver: driver)
        XCTAssertEqual(ribbon["alice"].map { ActivityPresentation.status($0) }, feed.first { $0.memberId == "alice" }?.status,
                       "the same mapping as the ribbon")
        XCTAssertEqual(ActivityPresentation.roundFeed(room: room, timeline: timeline, driver: driver, limit: 2).count, 2)

        timeline.apply(RoomLogPage(events: [
            RoomEvent(seq: 7, eventId: "a7", kind: "room.activity",
                      payload: ["status": "settled", "reason_code": "all_replied", "discussion_event_id": "user:bbb"], createdAt: 7),
        ], cursor: 7, latestSeq: 7, hasMore: false))
        let settled = ActivityPresentation.roundFeed(room: room, timeline: timeline, driver: RoomDriverStatus(working: false))
        XCTAssertEqual(settled.first?.status.label, "settled")
        XCTAssertFalse(settled.contains { $0.status.label == "working" }, "a settled round is not working")
        XCTAssertTrue(ActivityPresentation.roundFeed(room: room, timeline: RoomTimeline(), driver: nil).isEmpty)
    }

    func testThisRoundIsCapped() throws {
        let (room, turn) = try roundFixture()
        var timeline = RoomTimeline()
        var events = [RoomEvent(seq: 1, eventId: "user:bbb", kind: "message.user", payload: ["thread_id": "main"], createdAt: 1)]
        events += (2...60).map { turn($0, "turn.deferred", "alice", [:]) }
        timeline.apply(RoomLogPage(events: events, cursor: 60, latestSeq: 60, hasMore: false))
        let feed = ActivityPresentation.roundFeed(room: room, timeline: timeline, driver: nil)
        XCTAssertEqual(feed.count, ActivityPresentation.roundLimit)
        XCTAssertEqual(feed.first?.id, "turn:60", "newest first")
        XCTAssertEqual(feed.first?.status.label, "needs retry")
    }

    func testLiveChipsKeepTheTurnState() {
        XCTAssertEqual(ActivityPresentation.chips(phase: .idle, current: nil, turn: .needsApproval).map(\.label),
                       ["needs approval", "idle"], "live data never hides a pending approval")
        XCTAssertEqual(ActivityPresentation.chips(phase: .running, current: nil, turn: .failed).map(\.label), ["failed", "working"])
        XCTAssertEqual(ActivityPresentation.chips(phase: .running, current: nil, turn: .replied).map(\.label), ["working", "replied"])
        XCTAssertEqual(ActivityPresentation.chips(phase: .waiting, current: nil, turn: .needsApproval).map(\.label),
                       ["waiting for approval"], "one approval chip")
        XCTAssertEqual(ActivityPresentation.chips(phase: .running, current: nil, turn: .waiting).map(\.label), ["working"])
        XCTAssertEqual(ActivityPresentation.chips(phase: .idle, current: nil, turn: .waiting).map(\.label), ["idle", "waiting"])
        XCTAssertEqual(ActivityPresentation.chips(phase: .idle, current: nil, turn: .idle).map(\.label), ["idle"])
        XCTAssertEqual(ActivityPresentation.chips(phase: .idle, current: nil, turn: nil).map(\.label), ["idle"])
    }

    func testConfirmationsSayExactlyWhatHappens() {
        let off = ActivityPresentation.turnOffConfirmation
        XCTAssertTrue(off.contains("every bot profile"))
        XCTAssertTrue(off.contains("stay on disk but inactive"))
        XCTAssertTrue(off.contains("Enable Tracking turns them back on"))
        XCTAssertTrue(ActivityPresentation.reinstallConfirmation.contains(String(BotActivityPluginManager.pinnedRef.prefix(7))))
    }

    func testEnableSheetLinksThePinnedCommit() {
        XCTAssertEqual(EnableActivitySheet.sourceURL.absoluteString,
                       "https://github.com/risyadul/hermes-bot-activity/tree/" + BotActivityPluginManager.pinnedRef)
    }
}
