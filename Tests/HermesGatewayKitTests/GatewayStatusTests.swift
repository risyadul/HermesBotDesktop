import Darwin
import Foundation
import XCTest
@testable import HermesGatewayKit

/// `GatewayStatus` against temp lock dirs and a temp home (never the real launchd or lock dir).
final class GatewayStatusTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private struct Env {
        let home: URL
        let hermes: URL
        let lockDir: URL
        var plist: URL { home.appendingPathComponent("Library/LaunchAgents/ai.hermes.gateway.plist") }
    }

    private func env() throws -> Env {
        let (home, hermes) = try TempFS.home()
        cleanup.append(home)
        let lockDir = home.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(lockDir.path, 0o700)
        return Env(home: home, hermes: hermes, lockDir: lockDir)
    }

    private func status(_ e: Env, runner: FakeCommandRunner = FakeCommandRunner()) -> GatewayStatus {
        GatewayStatus(lockDir: e.lockDir, home: e.home, environment: ["HERMES_BOT_APP_HERMES_BIN": e.hermes.path], runner: runner)
    }

    private func writeRecord(_ e: Env, pid: Int32, startTime: Int64?, role: String = "gateway") throws {
        var o: [String: JSONValue] = ["role": .string(role), "pid": .number(Double(pid)), "protocolVersion": 1, "host": nil, "port": nil]
        if let startTime { o["startTime"] = .number(Double(startTime)) }
        try Data(JSONValue.object(o).compactJSON().utf8).write(to: e.lockDir.appendingPathComponent("host-gateway.json"))
    }

    private func installPlist(_ e: Env) throws {
        try FileManager.default.createDirectory(at: e.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: e.plist)
    }

    func testNotInstalledAndInstalledNotRunning() throws {
        let e = try env()
        XCTAssertEqual(status(e).state(), .notInstalled)
        try installPlist(e)
        XCTAssertEqual(status(e).state(), .installedNotRunning)
    }

    func testLiveRecordIsRunning() throws {
        let e = try env()
        let me = getpid()
        try writeRecord(e, pid: me, startTime: HostRendezvous.processStartCentiseconds(me))
        XCTAssertEqual(status(e).state(), .running(pid: me))
    }

    func testStaleRecordFallsBackToLaunchAgent() throws {
        let e = try env()
        try writeRecord(e, pid: getpid(), startTime: 1)  // live pid, different incarnation: reused pid
        XCTAssertEqual(status(e).state(), .notInstalled)
        try installPlist(e)
        XCTAssertEqual(status(e).state(), .installedNotRunning)
    }

    func testUntrustedRecordsAreUnknown() throws {
        let e = try env()
        let record = e.lockDir.appendingPathComponent("host-gateway.json")

        try Data("not json".utf8).write(to: record)
        guard case .unknown = status(e).state() else { return XCTFail("corrupt record") }

        try writeRecord(e, pid: getpid(), startTime: nil, role: "serve")
        guard case .unknown = status(e).state() else { return XCTFail("wrong role") }

        try FileManager.default.removeItem(at: record)
        let real = e.home.appendingPathComponent("real.json")
        try Data(#"{"role":"gateway","pid":\#(getpid())}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: real)
        guard case .unknown(let why) = status(e).state() else { return XCTFail("symlinked record") }
        XCTAssertTrue(why.contains("symlink"), why)

        try FileManager.default.removeItem(at: record)
        try writeRecord(e, pid: getpid(), startTime: HostRendezvous.processStartCentiseconds(getpid()))
        chmod(e.lockDir.path, 0o777)
        defer { chmod(e.lockDir.path, 0o700) }
        guard case .unknown(let w) = status(e).state() else { return XCTFail("world-writable lock dir") }
        XCTAssertTrue(w.contains("group/world-writable"), w)
    }

    func testStartRefusesWhenNotInstalled() async throws {
        let e = try env()
        let runner = FakeCommandRunner()
        do { try await status(e, runner: runner).start(); XCTFail("expected refusal") } catch {
            XCTAssertEqual(error as? GatewayStatus.Failure, .notInstalled)
            XCTAssertTrue("\(error)".contains("hermes gateway install"))
        }
        XCTAssertTrue(runner.calls.isEmpty, "never installs or starts without the LaunchAgent")
    }

    func testStartRunsHermesGatewayStart() async throws {
        let e = try env()
        try installPlist(e)
        let runner = FakeCommandRunner()
        try await status(e, runner: runner).start()
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(call.executable, TempFS.real(e.hermes))
        XCTAssertEqual(call.arguments, ["gateway", "start"])
        XCTAssertEqual(call.environment?["HERMES_HOME"], e.home.appendingPathComponent(".hermes").path)
        XCTAssertNil(call.environment?["HERMES_BOT_APP_HERMES_BIN"], "clean environment")
    }

    func testStartFailureCarriesScrubbedOutput() async throws {
        let e = try env()
        try installPlist(e)
        let runner = FakeCommandRunner { _, _ in CommandResult(status: 1, output: "launchctl kickstart failed Authorization: Bearer abcdefgh12345\n") }
        do { try await status(e, runner: runner).start(); XCTFail("expected failure") } catch {
            guard case .startFailed(1, let out)? = error as? GatewayStatus.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(out.contains("kickstart failed"))
            XCTAssertFalse(out.contains("abcdefgh12345"))
        }
    }

    func testProcessRunnerRunsAndTimesOut() async throws {
        let r = try await ProcessCommandRunner().run("/bin/echo", ["hi"], environment: nil, timeout: 10)
        XCTAssertEqual(r, CommandResult(status: 0, output: "hi\n"))
        let slow = try await ProcessCommandRunner().run("/bin/sleep", ["5"], environment: nil, timeout: 0.3)
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.succeeded)
        do { _ = try await ProcessCommandRunner().run("echo", [], environment: nil, timeout: 1); XCTFail("relative path ran") } catch {}
    }
}
