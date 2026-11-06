import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Scripted `GatewayStatus`: `states` answer `state()` in order (the last one repeats); `start` answers from
/// `startResult`. `hold()` parks the next `state()` or `start()` until `release()`. Never runs `hermes`.
private actor FakeGateway: GatewayControl {
    var states: [GatewayStatus.State]
    var startResult: Result<CommandResult, Error> = .success(CommandResult(status: 0, output: ""))
    private(set) var calls: [String] = []
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ states: [GatewayStatus.State]) { self.states = states }

    func script(_ s: [GatewayStatus.State]) { states = s }
    func setStart(_ r: Result<CommandResult, Error>) { startResult = r }
    func hold() { holdNext = true }
    func release() { gate?.resume(); gate = nil }
    var isHeld: Bool { gate != nil }

    private func parkIfHeld() async {
        guard holdNext else { return }
        holdNext = false
        await withCheckedContinuation { gate = $0 }
    }

    func state() async -> GatewayStatus.State {
        calls.append("state")
        await parkIfHeld()
        return states.count > 1 ? states.removeFirst() : states[0]
    }

    func start() async throws -> CommandResult {
        calls.append("start")
        await parkIfHeld()
        return try startResult.get()
    }
}

@MainActor
final class DispatcherStatusModelTests: XCTestCase {
    private func model(_ fake: FakeGateway) -> DispatcherStatusModel {
        DispatcherStatusModel(control: fake, settleDelay: .zero)
    }

    func testStateMapping() async {
        let cases: [(GatewayStatus.State, title: String, tone: SettingsTone, canStart: Bool)] = [
            (.running(pid: 4242), "Running (pid 4242)", .ok, false),
            (.installedNotRunning, "Stopped", .attention, true),
            (.notInstalled, "Not installed", .neutral, false),
            (.unknown("gateway record not owned by this uid"), "Status unknown", .attention, false),
        ]
        for c in cases {
            let m = model(FakeGateway([c.0]))
            XCTAssertEqual(m.summary.title, "Checking…")
            XCTAssertFalse(m.canStart)
            await m.refresh()
            XCTAssertEqual(m.state, c.0)
            XCTAssertEqual(m.summary.title, c.title)
            XCTAssertEqual(m.summary.tone, c.tone)
            XCTAssertEqual(m.canStart, c.canStart, "\(c.0)")
            XCTAssertFalse(m.starting)
        }
    }

    func testStartSuccessShowsScrubbedOutputAndWaitsForRunning() async {
        let fake = FakeGateway([.installedNotRunning])
        let m = model(fake)
        await m.refresh()
        await fake.setStart(.success(CommandResult(status: 0, output: "Started gateway\nX-Hermes-Token: abcdef0123456789\n")))
        await fake.script([.installedNotRunning, .installedNotRunning, .running(pid: 77)])
        await m.start()
        XCTAssertEqual(m.state, .running(pid: 77))
        XCTAssertNil(m.error)
        XCTAssertEqual(m.output?.hasPrefix("Started gateway"), true)
        XCTAssertEqual(m.output?.contains("abcdef0123456789"), false)
        XCTAssertFalse(m.starting)
        XCTAssertFalse(m.starting)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["state", "start", "state", "state", "state"], "re-read until running")
    }

    func testStartSettleIsBounded() async {
        let fake = FakeGateway([.installedNotRunning])
        let m = model(fake)
        await m.refresh()
        await m.start()
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "state" }.count, 2 + DispatcherStatusModel.settleAttempts)
        XCTAssertEqual(m.state, .installedNotRunning)
        XCTAssertNil(m.output, "empty output is not shown")
    }

    func testStartFailureShowsErrorAndRereadsOnce() async {
        let fake = FakeGateway([.installedNotRunning])
        await fake.setStart(.failure(GatewayStatus.Failure.startFailed(status: 1, output: "launchctl kickstart failed")))
        let m = model(fake)
        await m.refresh()
        await m.start()
        XCTAssertEqual(m.error, "`hermes gateway start` failed (status 1): launchctl kickstart failed")
        XCTAssertNil(m.output)
        XCTAssertEqual(m.state, .installedNotRunning)
        XCTAssertTrue(m.canStart, "can try again")
        let calls = await fake.calls
        XCTAssertEqual(calls, ["state", "start", "state"])
    }

    func testNotInstalledNeverStarts() async {
        let fake = FakeGateway([.notInstalled])
        let m = model(fake)
        await m.refresh()
        XCTAssertFalse(m.canStart)
        await m.start()
        let calls = await fake.calls
        XCTAssertEqual(calls, ["state"], "no start (and so no install) when the LaunchAgent is missing")
        XCTAssertEqual(GatewayStatus.installCommand, "hermes gateway install")
    }

    func testRunningAndUnknownNeverStart() async {
        for s: GatewayStatus.State in [.running(pid: 1), .unknown("x")] {
            let fake = FakeGateway([s])
            let m = model(fake)
            await m.refresh()
            await m.start()
            let calls = await fake.calls
            XCTAssertEqual(calls, ["state"], "\(s)")
        }
    }

    func testRefreshPicksUpChanges() async {
        let fake = FakeGateway([.installedNotRunning, .running(pid: 9)])
        let m = model(fake)
        await m.refresh()
        XCTAssertEqual(m.state, .installedNotRunning)
        await m.refresh()
        XCTAssertEqual(m.state, .running(pid: 9))
    }
    // MARK: chip text, one shared instance, generation guard (L1, L2)

    func testChipOutcomeText() async {
        let ok = FakeGateway([.installedNotRunning, .running(pid: 3)])
        let m = model(ok)
        await m.refresh()
        await m.start()
        XCTAssertEqual(m.startResult, "Dispatcher started.")
        XCTAssertFalse(m.startFailed)

        let bad = FakeGateway([.installedNotRunning])
        await bad.setStart(.failure(GatewayStatus.Failure.startFailed(status: 1, output: "")))
        let f = model(bad)
        await f.refresh()
        await f.start()
        XCTAssertTrue(f.startFailed)
        XCTAssertEqual(f.startResult, "Start failed: `hermes gateway start` failed (status 1)")
    }

    func testHubAndSettingsShareOneModel() {
        let shared = model(FakeGateway([.notInstalled]))
        let hub = KanbanHub(dispatcher: shared)
        XCTAssertTrue(hub.dispatcher === shared)
        XCTAssertTrue(AppModel.shared.kanban.dispatcher === AppModel.shared.kanban.dispatcher)
    }

    func testRefreshAnsweringAfterResetIsDropped() async {
        let fake = FakeGateway([.running(pid: 1)])
        let m = model(fake)
        await fake.hold()
        let stale = Task { await m.refresh() }
        await waitUntil { await fake.isHeld }
        m.reset()  // reconnect / disconnect
        await fake.release()
        await stale.value
        XCTAssertNil(m.state, "the stale answer was not written")
        await m.refresh()
        XCTAssertEqual(m.state, .running(pid: 1), "a refresh after the reset works")
    }

    func testStartFinishingAfterResetWritesNothing() async {
        let fake = FakeGateway([.installedNotRunning])
        let m = model(fake)
        await m.refresh()
        await fake.setStart(.failure(GatewayStatus.Failure.startFailed(status: 1, output: "boom")))
        await fake.hold()
        let stale = Task { await m.start() }
        await waitUntil { await fake.isHeld }
        XCTAssertTrue(m.starting)
        m.reset()
        XCTAssertTrue(m.starting, "`hermes gateway start` is still running: the reset keeps Start disabled")
        XCTAssertFalse(m.canStart)
        await m.start()  // a second Start meanwhile is refused
        await fake.release()
        await stale.value
        XCTAssertNil(m.error, "the old Start's failure is not shown after the reset")
        XCTAssertNil(m.startResult)
        XCTAssertNil(m.output)
        XCTAssertFalse(m.starting, "cleared when the old Start returned")
        XCTAssertTrue(m.canStart)
        XCTAssertEqual(m.state, .installedNotRunning, "the state (a local fact) is kept")
        let calls = await fake.calls
        XCTAssertEqual(calls, ["state", "start"], "no state re-read for the dropped Start")
    }

    func testHubConnectAndDisconnectResetTheDispatcher() async {
        let fake = FakeGateway([.installedNotRunning])
        let d = model(fake)
        await d.refresh()
        await fake.setStart(.failure(GatewayStatus.Failure.notInstalled))
        await d.start()
        XCTAssertNotNil(d.error)
        let hub = KanbanHub(dispatcher: d)
        let before = d.generation
        hub.connect(api: nil)
        XCTAssertNil(d.error)
        XCTAssertGreaterThan(d.generation, before)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out")
    }
}
