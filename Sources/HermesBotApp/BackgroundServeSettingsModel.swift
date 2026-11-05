import Foundation
import HermesGatewayKit

/// What Settings needs from `BackgroundServe` (roadmap E1). Tests inject a fake; nothing here ever touches
/// launchd or `~/Library/LaunchAgents` on its own.
protocol BackgroundServeControl: Sendable {
    var plistURL: URL { get }
    var logFile: URL { get }
    func status() async -> BackgroundServe.Status
    func resolveHermes() throws -> BackgroundServe.ResolvedHermes
    func install(bootstrap: Bool, expecting: String?) async throws
    func start() async throws
    func uninstall() async throws
    func jobPID() async -> Int32?
}

extension BackgroundServe: BackgroundServeControl {}

/// Colour role of a Settings status line (DESIGN.md status roles; mapped to tokens in SettingsSections.swift).
enum SettingsTone: Equatable { case ok, attention, danger, neutral }

/// What the app around Settings does when the background Hermes changes (AppModel in production).
struct BackgroundServeHost {
    /// The app runs its own spawned `hermes serve`.
    var ownsSpawnedBackend: @MainActor () -> Bool
    /// Pid of the backend the app is attached to through the `serve` host role (the role the background
    /// Hermes publishes), or nil.
    var attachedServePID: @MainActor () -> Int32?
    /// Stops the app's own spawned backend (its connection drops).
    var stopOwnedBackend: @MainActor () async -> Void
    /// Connects again; `waitForBackground`: give a just-started background Hermes time to publish itself
    /// before falling back to a spawn.
    var reconnect: @MainActor (_ waitForBackground: Bool) async -> Void

    static let app = BackgroundServeHost(
        ownsSpawnedBackend: { AppModel.shared.backend?.owned != nil },
        attachedServePID: {
            guard case .attached(let a)? = AppModel.shared.backend?.mode, a.role == .serve else { return nil }
            return a.record.pid
        },
        stopOwnedBackend: { await AppModel.shared.stopOwnedBackend(reason: "switching to the background Hermes") },
        reconnect: { wait in
            await AppModel.shared.reconnect(reason: "the background Hermes changed",
                                            waitForAttach: wait ? AppModel.backgroundAttachWait : 0)
        })
}

/// Settings → Background: the opt-in "Keep Hermes running in the background" LaunchAgent.
///
/// - The toggle is on while a plist is installed (`loaded`, `loadedNotRunning`, `installedNotLoaded`, and the
///   broken `binaryMissing`/`unreadable`, so turning it off removes them).
/// - Turning it on always asks first (`prompt`), naming the hermes executable launchd will run and warning
///   when `HERMES_BOT_APP_HERMES_BIN` chose it. The install then refuses if a different hermes is found by
///   the time it runs. When the app runs its own spawned serve, the question is "Switch Now" (stop it,
///   install, reconnect to the background one) or "At Next Launch" (write the plist only; the next app launch
///   starts it, `startPendingAtLaunch`, or launchd does at the next login) — never a second serve beside the
///   app's own.
/// - Turning it off while the app is attached to that very serve asks first (the connection drops and a
///   Group Chat round in progress stops), then reconnects.
/// - One operation at a time (`busy`): a second toggle, Start or Reinstall while one runs is ignored. The
///   status is re-read after every operation, success or not. Errors are shown through `Redaction.describe`.
@MainActor
final class BackgroundServeSettingsModel: ObservableObject {
    enum Prompt: Equatable {
        /// Confirm turning on. `offerSwitch`: the app runs its own serve (Switch Now / At Next Launch).
        case enable(hermes: String, fromEnvironment: Bool, offerSwitch: Bool)
        /// Turning off would stop the backend the app is attached to.
        case disableWhileAttached
    }

    enum EnableChoice: Equatable { case now, switchNow, atNextLaunch }

    /// UserDefaults flag: "At Next Launch" was chosen; the next launch starts the installed agent.
    static let startAtLaunchKey = "hba.backgroundServe.startAtLaunch"

    /// nil until the first `load()` answers.
    @Published private(set) var status: BackgroundServe.Status?
    @Published private(set) var busy = false
    /// The state the toggle is moving to while an operation runs (the switch does not flick back).
    @Published private(set) var target: Bool?
    @Published private(set) var error: String?
    @Published private(set) var pendingNextLaunch = false
    /// A question the view shows as a confirmation dialog.
    @Published private(set) var prompt: Prompt?

    let control: any BackgroundServeControl
    private let host: BackgroundServeHost
    private let defaults: UserDefaults

    init(control: any BackgroundServeControl = BackgroundServe(), host: BackgroundServeHost = .app,
         defaults: UserDefaults = .standard) {
        self.control = control
        self.host = host
        self.defaults = defaults
    }

    // MARK: presentation

    var isOn: Bool { target ?? (status?.isInstalled ?? false) }
    var canToggle: Bool { status != nil && !busy && prompt == nil }
    /// `installedNotLoaded` / `loadedNotRunning`: Start bootstraps or kickstarts the agent as installed.
    var canStart: Bool {
        switch status {
        case .installedNotLoaded?, .loadedNotRunning?: return true
        default: return false
        }
    }
    /// `binaryMissing`: Reinstall points the agent at the hermes found now.
    var needsReinstall: Bool { if case .binaryMissing = status { return true }; return false }

    var summary: (title: String, tone: SettingsTone) {
        switch status {
        case nil: return ("Checking…", .neutral)
        case .notInstalled?: return ("Off", .neutral)
        case .loaded?: return ("Running", .ok)
        case .loadedNotRunning?: return ("Loaded but not running", .attention)
        case .installedNotLoaded?: return ("Installed but not running", .attention)
        case .binaryMissing?: return ("Hermes not found", .attention)
        case .unreadable?: return ("LaunchAgent not recognised", .attention)
        }
    }

    /// Second line under the status, when the state needs one.
    var detail: String? {
        switch status {
        case .binaryMissing(let path)?:
            return "The background Hermes points at \(path), which is gone or not executable. Reinstall to use the hermes found now."
        case .loadedNotRunning?:
            return "launchd has the agent, but Hermes is not running (it exited, or launchd is waiting after a crash). Start runs it again; the log says why it stopped."
        case .unreadable(let why)?:
            return "\(why). Turning this off removes it."
        default: return nil
        }
    }

    /// Title, message and the confirming buttons of `prompt`.
    static func promptText(_ prompt: Prompt) -> (title: String, message: String) {
        switch prompt {
        case .enable(let hermes, let fromEnvironment, let offerSwitch):
            var message = "launchd will run \(hermes) serve at login and restart it if it crashes."
            if fromEnvironment {
                message += "\n\nThis path comes from HERMES_BOT_APP_HERMES_BIN, not the usual search. Make sure you trust it: it keeps running after the app quits."
            }
            if offerSwitch {
                message += "\n\nThe app is running its own Hermes now. Switch Now stops it (a Group Chat round in progress stops) and connects to the background Hermes. At Next Launch only installs the agent: it starts the next time you open the app, or at login."
            }
            return ("Keep Hermes running in the background?", message)
        case .disableWhileAttached:
            return ("Stop the background Hermes?",
                    "The app is connected to it: the connection drops and any Group Chat round in progress stops. The app then reconnects, starting its own Hermes if none is running.")
        }
    }

    // MARK: actions

    func load() async {
        guard !busy else { return }
        busy = true
        status = await control.status()
        if defaults.bool(forKey: Self.startAtLaunchKey), case .installedNotLoaded? = status { pendingNextLaunch = true }
        busy = false
    }

    /// The toggle. On: asks first (`prompt`). Off: asks first when the app is attached to that serve.
    func setEnabled(_ on: Bool) async {
        guard canToggle, on != isOn else { return }
        if on {
            askToInstall()
            return
        }
        // Busy while launchd is asked for the pid, so a second toggle meanwhile is ignored (one uninstall).
        busy = true
        let attached = await isAttachedToBackground()
        busy = false
        if attached {
            prompt = .disableWhileAttached
            return
        }
        await run(target: false) { try await self.control.uninstall() }
    }

    /// `.enable` for the hermes found now (or the error when none passes the checks).
    private func askToInstall() {
        do {
            let hermes = try control.resolveHermes()
            prompt = .enable(hermes: hermes.path, fromEnvironment: hermes.fromEnvironment, offerSwitch: host.ownsSpawnedBackend())
            error = nil
        } catch {
            self.error = Redaction.describe(error)
        }
    }

    func cancelPrompt() { prompt = nil }

    /// Confirms `.enable(hermes:…)` (turning on, or Reinstall) with one of its choices. The dialog passes the
    /// path it showed (the prompt itself may already be cleared by the dialog's dismissal). For Reinstall
    /// (`binaryMissing`) the broken agent is removed first; nothing is installed when that fails.
    func confirmEnable(_ choice: EnableChoice, hermes: String) async {
        let replacing = needsReinstall
        guard !busy, !isOn || replacing else { return }
        prompt = nil
        let install: (Bool) async throws -> Void = { bootstrap in
            if replacing { try await self.control.uninstall() }
            try await self.control.install(bootstrap: bootstrap, expecting: hermes)
        }
        switch choice {
        case .now:
            await run(target: true) { try await install(true) }
        case .switchNow:
            let ok = await run(target: true) {
                await self.host.stopOwnedBackend()
                try await install(true)
            }
            // The own serve is stopped either way: connect again (to the background one when it came up).
            await host.reconnect(ok)
        case .atNextLaunch:
            if await run(target: true, { try await install(false) }) {
                defaults.set(true, forKey: Self.startAtLaunchKey)
                pendingNextLaunch = true
            }
        }
    }

    /// Confirms `.disableWhileAttached`: uninstall, then reconnect (the attached backend is gone).
    func confirmDisable() async {
        guard !busy, isOn else { return }
        prompt = nil
        if await run(target: false, { try await self.control.uninstall() }) { await host.reconnect(false) }
    }

    /// `installedNotLoaded` / `loadedNotRunning` → `start()` (the agent as installed, no new hermes lookup).
    func start() async {
        guard !busy, canStart else { return }
        await run(target: true) { try await self.control.start() }
    }

    /// `binaryMissing` → asks like turning on (the hermes found now, Switch Now / At Next Launch when the app
    /// runs its own serve); confirming uninstalls, then installs (only if the uninstall worked).
    func reinstall() async {
        guard !busy, needsReinstall, prompt == nil else { return }
        askToInstall()
    }

    /// Attached through the `serve` role to the pid launchd reports for the job (or, when launchd reports no
    /// pid, while the job runs).
    func isAttachedToBackground() async -> Bool {
        guard let attached = host.attachedServePID() else { return false }
        if let pid = await control.jobPID() { return pid == attached }
        if case .loaded? = status { return true }
        return false
    }

    /// True when `operation` succeeded; false without running it while another operation is in flight.
    @discardableResult
    private func run(target on: Bool, _ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        target = on
        error = nil
        var failed = false
        do { try await operation() } catch {
            failed = true
            self.error = Redaction.describe(error)
        }
        status = await control.status()
        if !on {
            pendingNextLaunch = false
            if !failed { defaults.removeObject(forKey: Self.startAtLaunchKey) }
        }
        target = nil
        busy = false
        return !failed
    }

    // MARK: launch

    /// "At Next Launch" was chosen earlier: start the installed agent now (before connecting) and clear the
    /// flag. True when it was started, so the connect should wait for it to publish itself. Already loaded
    /// (launchd did it at login), removed, or broken: only the flag is cleared.
    static func startPendingAtLaunch(control: any BackgroundServeControl, defaults: UserDefaults = .standard) async -> Bool {
        guard defaults.bool(forKey: startAtLaunchKey) else { return false }
        defaults.removeObject(forKey: startAtLaunchKey)
        guard case .installedNotLoaded = await control.status() else { return false }
        do { try await control.start(); return true } catch { return false }
    }
}
