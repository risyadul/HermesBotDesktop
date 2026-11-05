import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Scripted `GatewayStatus`: `states` answer `state()` in order (the last one repeats); `start` answers from
/// `startResult`. Never runs `hermes`.
private actor FakeGateway: GatewayControl {
    var states: [GatewayStatus.State]
    var startResult: Result<CommandResult, Error> = .success(CommandResult(status: 0, output: ""))
    private(set) var calls: [String] = []

    init(_ states: [GatewayStatus.State]) { self.states = states }

    func script(_ s: [GatewayStatus.State]) { states = s }
    func setStart(_ r: Result<CommandResult, Error>) { startResult = r }

    func state() async -> GatewayStatus.State {
        calls.append("state")
        return states.count > 1 ? states.removeFirst() : states[0]
    }

    func start() async throws -> CommandResult {
        calls.append("start")
        return try startResult.get()
    }
}

@MainActor
final class GatewaySettingsModelTests: XCTestCase {
    private func model(_ fake: FakeGateway) -> GatewaySettingsModel {
        GatewaySettingsModel(control: fake, settleDelay: .zero)
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
            XCTAssertFalse(m.busy)
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
        XCTAssertFalse(m.busy)
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
        XCTAssertEqual(calls.filter { $0 == "state" }.count, 2 + GatewaySettingsModel.settleAttempts)
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
}
