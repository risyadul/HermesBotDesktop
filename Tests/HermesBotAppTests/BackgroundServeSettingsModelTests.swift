import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Scripted `BackgroundServe`: records calls, never touches launchd. `install`/`uninstall`/`start` move
/// `current` like the real thing unless a failure is set; `holdNextInstall` parks the next install until
/// `release()`.
private actor FakeBackgroundServe: BackgroundServeControl {
    nonisolated let plistURL = URL(fileURLWithPath: "/tmp/hba-test/Library/LaunchAgents/io.github.risyadul.hermesbot.serve.plist")
    nonisolated let logFile = URL(fileURLWithPath: "/tmp/hba-test/Library/Logs/HermesBotApp/background-serve.log")
    nonisolated let resolved: BackgroundServe.ResolvedHermes?
    var current: BackgroundServe.Status
    var installFailure: Error?
    var uninstallFailure: Error?
    var pid: Int32?
    private(set) var calls: [String] = []
    private var holdNextInstall = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ status: BackgroundServe.Status, resolved: BackgroundServe.ResolvedHermes? = .init(path: "/opt/hermes/bin/hermes", fromEnvironment: false),
         pid: Int32? = nil) {
        current = status; self.resolved = resolved; self.pid = pid
    }

    func set(_ s: BackgroundServe.Status) { current = s }
    func failInstall(_ e: Error?) { installFailure = e }
    func failUninstall(_ e: Error?) { uninstallFailure = e }
    func hold() { holdNextInstall = true }
    func release() { gate?.resume(); gate = nil }
    var isHeld: Bool { gate != nil }

    func status() async -> BackgroundServe.Status { calls.append("status"); return current }

    nonisolated func resolveHermes() throws -> BackgroundServe.ResolvedHermes {
        guard let resolved else { throw BackgroundServe.Failure.hermes("hermes not found") }
        return resolved
    }

    func install(bootstrap: Bool, expecting: String?) async throws {
        calls.append(bootstrap ? "install" : "install(plist only)")
        if holdNextInstall {
            holdNextInstall = false
            await withCheckedContinuation { gate = $0 }
        }
        if let installFailure { throw installFailure }
        current = bootstrap ? .loaded(executable: "/opt/hermes/bin/hermes") : .installedNotLoaded(executable: "/opt/hermes/bin/hermes")
    }

    func start() async throws {
        calls.append("start")
        if case .installedNotLoaded(let e) = current { current = .loaded(executable: e) }
        if case .loadedNotRunning(let e) = current { current = .loaded(executable: e) }
    }

    func uninstall() async throws {
        calls.append("uninstall")
        if let uninstallFailure { throw uninstallFailure }
        current = .notInstalled
    }

    func jobPID() async -> Int32? { calls.append("pid"); return pid }
}

/// Records what Settings asked the app to do.
@MainActor
private final class HostLog {
    var owns = false
    var attachedPID: Int32?
    var events: [String] = []

    var host: BackgroundServeHost {
        BackgroundServeHost(
            ownsSpawnedBackend: { self.owns },
            attachedServePID: { self.attachedPID },
            stopOwnedBackend: { self.events.append("stopOwned") },
            reconnect: { wait in self.events.append(wait ? "reconnect(wait)" : "reconnect") })
    }
}

@MainActor
final class BackgroundServeSettingsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "hba-bg-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(_ fake: FakeBackgroundServe, host: HostLog = HostLog()) -> BackgroundServeSettingsModel {
        BackgroundServeSettingsModel(control: fake, host: host.host, defaults: defaults)
    }

    /// Toggle on and confirm the prompt with `choice` (the prompt's own path).
    private func enable(_ m: BackgroundServeSettingsModel, _ choice: BackgroundServeSettingsModel.EnableChoice = .now) async {
        await m.setEnabled(true)
        guard case .enable(let hermes, _, _)? = m.prompt else { return XCTFail("no enable prompt: \(String(describing: m.prompt))") }
        await m.confirmEnable(choice, hermes: hermes)
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
            (.loadedNotRunning(executable: "/x/hermes"), true, true, false, "Loaded but not running", .attention),
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

    func testDetailLines() async {
        let missing = model(FakeBackgroundServe(.binaryMissing(path: "/gone/hermes")))
        await missing.load()
        XCTAssertTrue(missing.detail?.contains("/gone/hermes") ?? false)
        let stopped = model(FakeBackgroundServe(.loadedNotRunning(executable: "/x/hermes")))
        await stopped.load()
        XCTAssertTrue(stopped.detail?.contains("not running") ?? false)
    }

    // MARK: turning on asks first

    func testTurningOnAsksWithThePathThenInstalls() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        XCTAssertEqual(m.prompt, .enable(hermes: "/opt/hermes/bin/hermes", fromEnvironment: false, offerSwitch: false))
        XCTAssertFalse(m.canToggle, "the toggle waits for the answer")
        var calls = await fake.calls
        XCTAssertEqual(calls, ["status"], "nothing installed before the confirmation")
        let text = BackgroundServeSettingsModel.promptText(m.prompt!)
        XCTAssertTrue(text.message.contains("/opt/hermes/bin/hermes serve"), text.message)
        XCTAssertFalse(text.message.contains("HERMES_BOT_APP_HERMES_BIN"))

        await m.confirmEnable(.now, hermes: "/opt/hermes/bin/hermes")
        calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"])
        XCTAssertNil(m.prompt)
        XCTAssertEqual(m.status, .loaded(executable: "/opt/hermes/bin/hermes"))
        XCTAssertTrue(m.isOn)
        XCTAssertNil(m.error)
        XCTAssertFalse(m.busy)
        XCTAssertNil(m.target)
        XCTAssertFalse(m.pendingNextLaunch, "attached (or not connected): nothing to defer")
    }

    func testCancellingThePromptChangesNothing() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        m.cancelPrompt()
        XCTAssertNil(m.prompt)
        XCTAssertFalse(m.isOn)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testEnvironmentOverrideIsWarnedAbout() async {
        let fake = FakeBackgroundServe(.notInstalled, resolved: .init(path: "/tmp/odd/hermes", fromEnvironment: true))
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        XCTAssertEqual(m.prompt, .enable(hermes: "/tmp/odd/hermes", fromEnvironment: true, offerSwitch: false))
        let text = BackgroundServeSettingsModel.promptText(m.prompt!).message
        XCTAssertTrue(text.contains("/tmp/odd/hermes"))
        XCTAssertTrue(text.contains("HERMES_BOT_APP_HERMES_BIN"), text)
    }

    func testUnresolvableHermesShowsTheErrorWithoutAPrompt() async {
        let fake = FakeBackgroundServe(.notInstalled, resolved: nil)
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        XCTAssertNil(m.prompt)
        XCTAssertEqual(m.error, "hermes not found")
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testTurningOffUninstalls() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.setEnabled(false)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "uninstall", "status"], "not attached: no question, no pid lookup")
        XCTAssertEqual(m.status, .notInstalled)
        XCTAssertFalse(m.isOn)
    }

    func testSettingTheCurrentValueDoesNothing() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        let m = model(fake)
        await m.load()
        await m.setEnabled(true)
        XCTAssertNil(m.prompt)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testToggleBeforeFirstStatusIsIgnored() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.setEnabled(true)
        XCTAssertNil(m.prompt)
        let calls = await fake.calls
        XCTAssertEqual(calls, [])
    }

    func testInFlightInstallBlocksASecondInstall() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let m = model(fake)
        await m.load()
        await fake.hold()
        let first = Task { await self.enable(m) }
        await waitUntil("install parked") { await fake.isHeld }
        XCTAssertTrue(m.busy)
        XCTAssertFalse(m.canToggle, "toggle disabled while in flight")
        XCTAssertTrue(m.isOn, "the switch shows where it is going")
        await m.setEnabled(true)
        await m.setEnabled(false)
        await m.confirmEnable(.now, hermes: "/opt/hermes/bin/hermes")
        await m.load()
        await fake.release()
        await first.value
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"], "exactly one install, nothing else while it ran")
        XCTAssertFalse(m.busy)
    }

    // MARK: M4: the app owns a spawned serve

    func testOwnedServeOffersSwitchNowWhichStopsInstallsAndReconnects() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let host = HostLog()
        host.owns = true
        let m = model(fake, host: host)
        await m.load()
        await m.setEnabled(true)
        XCTAssertEqual(m.prompt, .enable(hermes: "/opt/hermes/bin/hermes", fromEnvironment: false, offerSwitch: true))
        XCTAssertTrue(BackgroundServeSettingsModel.promptText(m.prompt!).message.contains("Switch Now"))
        await m.confirmEnable(.switchNow, hermes: "/opt/hermes/bin/hermes")
        XCTAssertEqual(host.events, ["stopOwned", "reconnect(wait)"])
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install", "status"])
        XCTAssertFalse(m.pendingNextLaunch)
        XCTAssertTrue(m.isOn)
    }

    func testSwitchNowReconnectsEvenWhenTheInstallFails() async {
        let fake = FakeBackgroundServe(.notInstalled)
        await fake.failInstall(BackgroundServe.Failure.launchctl(command: "bootstrap", status: 5, output: ""))
        let host = HostLog()
        host.owns = true
        let m = model(fake, host: host)
        await m.load()
        await enable(m, .switchNow)
        XCTAssertEqual(host.events, ["stopOwned", "reconnect"], "own serve already stopped: connect again, no wait")
        XCTAssertNotNil(m.error)
    }

    func testAtNextLaunchWritesThePlistOnlyAndFlagsTheLaunch() async {
        let fake = FakeBackgroundServe(.notInstalled)
        let host = HostLog()
        host.owns = true
        let m = model(fake, host: host)
        await m.load()
        await enable(m, .atNextLaunch)
        let calls = await fake.calls
        XCTAssertEqual(calls, ["status", "install(plist only)", "status"], "no bootstrap: no second serve now")
        XCTAssertTrue(host.events.isEmpty, "the app's own serve keeps running")
        XCTAssertTrue(m.pendingNextLaunch)
        XCTAssertTrue(m.isOn)
        XCTAssertTrue(defaults.bool(forKey: BackgroundServeSettingsModel.startAtLaunchKey))

        // Settings reopened before the next launch still says so.
        let again = model(fake, host: host)
        await again.load()
        XCTAssertTrue(again.pendingNextLaunch)

        // Turning it off again drops the note and the flag.
        await m.setEnabled(false)
        XCTAssertFalse(m.pendingNextLaunch)
        XCTAssertFalse(defaults.bool(forKey: BackgroundServeSettingsModel.startAtLaunchKey))
    }

    func testNextLaunchStartsTheInstalledAgentOnce() async {
        let fake = FakeBackgroundServe(.installedNotLoaded(executable: "/x/hermes"))
        var started = await BackgroundServeSettingsModel.startPendingAtLaunch(control: fake, defaults: defaults)
        XCTAssertFalse(started, "no flag: nothing")
        var calls = await fake.calls
        XCTAssertEqual(calls, [], "no launchctl call at all without the flag")

        defaults.set(true, forKey: BackgroundServeSettingsModel.startAtLaunchKey)
        started = await BackgroundServeSettingsModel.startPendingAtLaunch(control: fake, defaults: defaults)
        XCTAssertTrue(started)
        calls = await fake.calls
        XCTAssertEqual(calls, ["status", "start"])
        XCTAssertFalse(defaults.bool(forKey: BackgroundServeSettingsModel.startAtLaunchKey), "flag cleared")

        let loaded = FakeBackgroundServe(.loaded(executable: "/x/hermes"))
        defaults.set(true, forKey: BackgroundServeSettingsModel.startAtLaunchKey)
        started = await BackgroundServeSettingsModel.startPendingAtLaunch(control: loaded, defaults: defaults)
        XCTAssertFalse(started, "launchd already loaded it at login")
        calls = await loaded.calls
        XCTAssertEqual(calls, ["status"])
        XCTAssertFalse(defaults.bool(forKey: BackgroundServeSettingsModel.startAtLaunchKey))
    }

    // MARK: M2: turning off while attached to it

    func testTurningOffWhileAttachedToTheJobAsksThenReconnects() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"), pid: 4242)
        let host = HostLog()
        host.attachedPID = 4242
        let m = model(fake, host: host)
        await m.load()
        await m.setEnabled(false)
        XCTAssertEqual(m.prompt, .disableWhileAttached)
        var calls = await fake.calls
        XCTAssertEqual(calls, ["status", "pid"], "nothing removed before the confirmation")
        let text = BackgroundServeSettingsModel.promptText(.disableWhileAttached).message
        XCTAssertTrue(text.contains("connection drops") && text.contains("Group Chat round"), text)

        await m.confirmDisable()
        calls = await fake.calls
        XCTAssertEqual(calls, ["status", "pid", "uninstall", "status"])
        XCTAssertEqual(host.events, ["reconnect"])
        XCTAssertFalse(m.isOn)
    }

    func testAttachedToAnotherServeTurnsOffWithoutAsking() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"), pid: 4242)
        let host = HostLog()
        host.attachedPID = 999  // e.g. a serve started by hand
        let m = model(fake, host: host)
        await m.load()
        await m.setEnabled(false)
        XCTAssertNil(m.prompt)
        XCTAssertTrue(host.events.isEmpty)
        XCTAssertFalse(m.isOn)
    }

    func testAttachedServeRoleWhileTheJobRunsWithoutAPidCountsAsAttached() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"), pid: nil)
        let host = HostLog()
        host.attachedPID = 77
        let m = model(fake, host: host)
        await m.load()
        let attached = await m.isAttachedToBackground()
        XCTAssertTrue(attached)
        host.attachedPID = nil
        let notAttached = await m.isAttachedToBackground()
        XCTAssertFalse(notAttached)
    }

    func testFailedUninstallDoesNotReconnect() async {
        let fake = FakeBackgroundServe(.loaded(executable: "/x/hermes"), pid: 1)
        await fake.failUninstall(BackgroundServe.Failure.filesystem("cannot remove the plist"))
        let host = HostLog()
        host.attachedPID = 1
        let m = model(fake, host: host)
        await m.load()
        await m.setEnabled(false)
        await m.confirmDisable()
        XCTAssertTrue(host.events.isEmpty)
        XCTAssertNotNil(m.error)
    }

    // MARK: errors

    func testInstallErrorIsShownRedactedAndStatusReread() async {
        let fake = FakeBackgroundServe(.notInstalled)
        await fake.failInstall(BackgroundServe.Failure.launchctl(command: "bootstrap", status: 5,
                                                                 output: "Authorization: Bearer abcdef0123456789"))
        let m = model(fake)
        await m.load()
        await enable(m)
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
        await fake.failInstall(BackgroundServe.Failure.hermes("the hermes found now differs"))
        let m = model(fake)
        await m.load()
        await enable(m)
        XCTAssertEqual(m.error, "the hermes found now differs")
        await fake.failInstall(nil)
        await enable(m)
        XCTAssertNil(m.error)
        XCTAssertTrue(m.isOn)
    }

    // MARK: binaryMissing / installedNotLoaded / loadedNotRunning

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

    func testStartRunsTheInstalledAgentAsWritten() async {
        for s: BackgroundServe.Status in [.installedNotLoaded(executable: "/x/hermes"), .loadedNotRunning(executable: "/x/hermes")] {
            let fake = FakeBackgroundServe(s)
            let m = model(fake)
            await m.load()
            await m.start()
            let calls = await fake.calls
            XCTAssertEqual(calls, ["status", "start", "status"], "\(s): no reinstall, no new hermes lookup")
            XCTAssertEqual(m.summary.title, "Running")
        }
    }

    func testLogPathComesFromTheControl() {
        let m = model(FakeBackgroundServe(.notInstalled))
        XCTAssertEqual(m.control.logFile.lastPathComponent, "background-serve.log")
        XCTAssertEqual(BackgroundServe(home: URL(fileURLWithPath: "/Users/x")).logFile.path,
                       "/Users/x/Library/Logs/HermesBotApp/background-serve.log", "README's log path")
    }
}
