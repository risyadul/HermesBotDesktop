import Foundation
import HermesGatewayKit

/// What Settings needs from `BackgroundServe` (roadmap E1). Tests inject a fake; nothing here ever touches
/// launchd or `~/Library/LaunchAgents` on its own.
protocol BackgroundServeControl: Sendable {
    var plistURL: URL { get }
    var logFile: URL { get }
    func status() async -> BackgroundServe.Status
    func install() async throws
    func uninstall() async throws
}

extension BackgroundServe: BackgroundServeControl {}

/// Colour role of a Settings status line (DESIGN.md status roles; mapped to tokens in SettingsSections.swift).
enum SettingsTone: Equatable { case ok, attention, danger, neutral }

/// Settings → Background: the opt-in "Keep Hermes running in the background" LaunchAgent.
///
/// - The toggle is on while a plist is installed (`loaded`, `installedNotLoaded`, and the broken
///   `binaryMissing`/`unreadable`, so turning it off removes them). On → `install()`, off → `uninstall()`.
/// - One operation at a time (`busy`): a second toggle, Start or Reinstall while one runs is ignored, so a
///   double click never installs twice. The status is re-read after every operation, success or not.
/// - Errors are shown through `Redaction.describe`.
/// - Turning it on never touches the live connection: when the app owns a spawned backend it says the
///   change applies next launch (`pendingNextLaunch`).
@MainActor
final class BackgroundServeSettingsModel: ObservableObject {
    /// nil until the first `load()` answers.
    @Published private(set) var status: BackgroundServe.Status?
    @Published private(set) var busy = false
    /// The state the toggle is moving to while an install/uninstall runs (the switch does not flick back).
    @Published private(set) var target: Bool?
    @Published private(set) var error: String?
    @Published private(set) var pendingNextLaunch = false

    let control: any BackgroundServeControl
    private let ownsSpawnedBackend: @MainActor () -> Bool

    init(control: any BackgroundServeControl = BackgroundServe(),
         ownsSpawnedBackend: @escaping @MainActor () -> Bool = { AppModel.shared.backend?.owned != nil }) {
        self.control = control
        self.ownsSpawnedBackend = ownsSpawnedBackend
    }

    // MARK: presentation

    var isOn: Bool { target ?? (status?.isInstalled ?? false) }
    var canToggle: Bool { status != nil && !busy }
    /// `installedNotLoaded`: Start re-bootstraps it (`install()`).
    var canStart: Bool { if case .installedNotLoaded = status { return true }; return false }
    /// `binaryMissing`: Reinstall points the agent at the hermes found now.
    var needsReinstall: Bool { if case .binaryMissing = status { return true }; return false }

    var summary: (title: String, tone: SettingsTone) {
        switch status {
        case nil: return ("Checking…", .neutral)
        case .notInstalled?: return ("Off", .neutral)
        case .loaded?: return ("Running", .ok)
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
        case .unreadable(let why)?:
            return "\(why). Turning this off removes it."
        default: return nil
        }
    }

    // MARK: actions

    func load() async {
        guard !busy else { return }
        busy = true
        status = await control.status()
        busy = false
    }

    func setEnabled(_ on: Bool) async {
        guard canToggle, on != isOn else { return }
        await run(target: on) {
            if on { try await self.control.install() } else { try await self.control.uninstall() }
        }
    }

    /// `installedNotLoaded` → `install()` (boots it into launchd again).
    func start() async {
        guard !busy, canStart else { return }
        await run(target: true) { try await self.control.install() }
    }

    /// `binaryMissing` → uninstall, then install (only if the uninstall worked).
    func reinstall() async {
        guard !busy, needsReinstall else { return }
        await run(target: true) {
            try await self.control.uninstall()
            try await self.control.install()
        }
    }

    private func run(target on: Bool, _ operation: () async throws -> Void) async {
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
        } else if !failed, status?.isInstalled == true, ownsSpawnedBackend() {
            pendingNextLaunch = true
        }
        target = nil
        busy = false
    }
}
