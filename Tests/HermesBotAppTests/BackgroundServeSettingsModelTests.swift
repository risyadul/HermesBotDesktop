import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Scripted `BackgroundServe`: records calls, never touches launchd. `install`/`uninstall` move `current`
/// like the real thing unless a failure is set; `holdNextInstall` parks the next install until `release()`.
private actor FakeBackgroundServe: BackgroundServeControl {
    nonisolated let plistURL = URL(fileURLWithPath: "/tmp/hba-test/Library/LaunchAgents/io.github.risyadul.hermesbot.serve.plist")
    nonisolated let logFile = URL(fileURLWithPath: "/tmp/hba-test/Library/Logs/HermesBotApp/background-serve.log")
    var current: BackgroundServe.Status
    var installFailure: Error?
    var uninstallFailure: Error?
    private(set) var calls: [String] = []
    private var holdNextInstall = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ status: BackgroundServe.Status) { current = status }

    func set(_ s: BackgroundServe.Status) { current = s }
    func failInstall(_ e: Error?) { installFailure = e }
    func failUninstall(_ e: Error?) { uninstallFailure = e }
    func hold() { holdNextInstall = true }
    func release() { gate?.resume(); gate = nil }
    var isHeld: Bool { gate != nil }

    func status() async -> BackgroundServe.Status { calls.append("status"); return current }

    func install() async throws {
        calls.append("install")
        if holdNextInstall {
            holdNextInstall = false
            await withCheckedContinuation { gate = $0 }
        }
        if let installFailure { throw installFailure }
        current = .loaded(executable: "/opt/hermes/bin/hermes")
    }

    func uninstall() async throws {
        calls.append("uninstall")
        if let uninstallFailure { throw uninstallFailure }
        current = .notInstalled
    }
}

@MainActor
final class BackgroundServeSettingsModelTests: XCTestCase {
    private func model(_ fake: FakeBackgroundServe, owns: Bool = false) -> BackgroundServeSettingsModel {
        BackgroundServeSettingsModel(control: fake, ownsSpawnedBackend: { owns })
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: status mapping

    func testStatusMapsToToggleAndActions() async {
        let cases: [(BackgroundServe.Status, on: Bool, start: Bool, reinstall: Bool, title: String, tone: SettingsTone)] = [
            (.notInstalled, false, false, false, "Off", .neutral),
            (.loaded(executable: "/x/hermes"), true, false, false, "Running", .ok),
            (.installedNotLoaded(executable: "/x/hermes"), true, true, false, "Installed but not running", .attention),
            (.binaryMissing(path: "/gone/hermes"), true, false, true, "Hermes not found", .attention),
            (.unreadable("plist was not written by this app"), true, false, false, "LaunchAgent not recognised", .attention),
        ]
        for c in cases {
            let m = model(FakeBackgroundServe(c.0))
            XCTAssertNil(m.status)
            XCTAssertFalse(m.canToggle, "no toggling before the first status")
            XCTAssertEqual(m.summary.title, "Checking…")
            await m.load()
            XCTAssertEqual(m.status, c.0)
            XCTAssertEqual(m.isOn, c.on, "\(c.0)")
            XCTAssertEqual(m.canStart, c.start, "\(c.0)")
            XCTAssertEqual(m.needsReinstall, c.reinstall, "\(c.0)")
            XCTAssertEqual(m.summary.title, c.title)
            XCTAssertEqual(m.summary.tone, c.tone)
            XCTAssertTrue(m.canToggle)
        }
    }

    func testBinaryMissingDetailNamesThePath() async {
        let m = model(FakeBackgroundServe(.binaryMissing(path: "/gone/hermes")))
        await m.load()
        XCTAssertTrue(m.detail?.contains("/gone/hermes") ?? false)
    }

    // MARK: toggle

    func testTurningOnInstallsThenRereadsStatus() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"])
        XCTAssertEqual(m.status, .loaded(executable: "/opt/hermes/bin/hermes"))
        XCTAssertTrue(m.isOn)
        XCTAssertNil(m.error)
        XCTAssertFalse(m.busy)
        XCTAssertNil(m.target)
        XCTAssertFalse(m.pendingNextLaunch, "attached (or not connected): nothing to defer")
    }

    func testTurningOffUninstalls() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.setEnabled(false)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "uninstall", "status"])
        XCTAssertEqual(m.status, .notInstalled)
        XCTAssertFalse(m.isOn)
    }

    func testSettingTheCurrentValueDoesNothing() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testToggleBeforeFirstStatusIsIgnored() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.setEnabled(true)
        let calls = await fake.calls
        XCTAssertEqual(calls, [])
    }

    func testInFlightInstallBlocksASecondInstall() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.load()
        await fake.hold()
        let first = Task { await m.setEnabled(true) }
        await waitUntil("install parked") { await fake.isHeld }
        XCTAssertTrue(m.busy)
        XCTAssertFalse(m.canToggle, "toggle disabled while in flight")
        XCTAssertTrue(m.isOn, "the switch shows where it is going")
        await m.setEnabled(true)
        await m.setEnabled(false)
        await m.load()
        await fake.release()
        await first.value
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"], "exactly one install, nothing else while it ran")
        XCTAssertFalse(m.busy)
    }

    // MARK: errors

    func testInstallErrorIsShownRedactedAndStatusReread() async {
        let fake = FakeBackgroundServe(.notInstalled)
        await fake.failInstall(BackgroundServe.Failure.launchctl(command: "bootstrap", status: 5,
                                                                 output: "Authorization: Bearer abcdef0123456789"))
        let m = model(fake, owns: true)
        await m.load()
        await m.setEnabled(true)
        XCTAssertEqual(m.error?.contains("launchctl bootstrap failed (status 5)"), true)
        XCTAssertEqual(m.error?.contains("abcdef0123456789"), false, "token-shaped output is scrubbed")
        XCTAssertFalse(m.isOn, "toggle falls back to the real state")
        XCTAssertFalse(m.pendingNextLaunch, "no next-launch note after a failed install")
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"])
    }

    func testForeignErrorIsReducedToDomainAndCode() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        await fake.failUninstall(NSError(domain: "NSCocoaErrorDomain", code: 513,
                                         userInfo: [NSURLErrorFailingURLStringErrorKey: "ws://127.0.0.1/api/ws?token=secret123456"]))
        let m = model(fake)
        await m.load()
        await m.setEnabled(false)
        XCTAssertEqual(m.error?.hasPrefix("NSCocoaErrorDomain 513"), true)
        XCTAssertEqual(m.error?.contains("secret123456"), false)
        XCTAssertTrue(m.isOn, "uninstall failed: still installed")
    }

    func testSuccessClearsAPreviousError() async {
        let fake = FakeBackgroundServe(.notInstalled)
        await fake.failInstall(BackgroundServe.Failure.hermes("hermes not found"))
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        XCTAssertEqual(m.error, "hermes not found")
        await fake.failInstall(nil)
        await m.setEnabled(true)
        XCTAssertNil(m.error)
        XCTAssertTrue(m.isOn)
    }

    // MARK: binaryMissing / installedNotLoaded

    func testReinstallUninstallsThenInstalls() async {
        let fake = FakeBackgroundServe(.binaryMissing(path: "/gone/hermes"))
        let m = model(fake)
        await m.load()
        await m.reinstall()
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "uninstall", "install", "status"])
        XCTAssertEqual(m.status, .loaded(executable: "/opt/hermes/bin/hermes"))
        XCTAssertFalse(m.needsReinstall)
    }

    func testReinstallStopsWhenUninstallFails() async {
        let fake = FakeBackgroundServe(.binaryMissing(path: "/gone/hermes"))
        await fake.failUninstall(BackgroundServe.Failure.filesystem("cannot remove the plist"))
        let m = model(fake)
        await m.load()
        await m.reinstall()
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "uninstall", "status"], "no install after a failed uninstall")
        XCTAssertEqual(m.error, "background serve: cannot remove the plist")
    }

    func testReinstallOnlyWhenBinaryMissing() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.reinstall()
        await m.start()
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testStartReloadsAnInstalledButUnloadedAgent() async {
        let fake = FakeBackgroundServe(.installedNotLoaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.start()
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"])
        XCTAssertEqual(m.summary.title, "Running")
    }

    // MARK: next-launch note

    func testNextLaunchNoteOnlyWhenTheAppOwnsASpawnedBackend() async {
        let owned = model(FakeBackgroundServe(.notInstalled), owns: true)
        await owned.load()
        await owned.setEnabled(true)
        XCTAssertTrue(owned.pendingNextLaunch)
        await owned.setEnabled(false)
        XCTAssertFalse(owned.pendingNextLaunch, "turning it off again drops the note")

        let attached = model(FakeBackgroundServe(.notInstalled), owns: false)
        await attached.load()
        await attached.setEnabled(true)
        XCTAssertFalse(attached.pendingNextLaunch)
    }

    func testLogPathComesFromTheControl() {
        let m = model(FakeBackgroundServe(.notInstalled))
        XCTAssertEqual(m.control.logFile.lastPathComponent, "background-serve.log")
        XCTAssertEqual(BackgroundServe(home: URL(fileURLWithPath: "/Users/x")).logFile.path,
                       "/Users/x/Library/Logs/HermesBotApp/background-serve.log", "README's log path")
    }
}
