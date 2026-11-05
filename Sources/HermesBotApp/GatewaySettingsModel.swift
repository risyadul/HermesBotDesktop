import Foundation
import HermesGatewayKit

/// What Settings needs from `GatewayStatus` (roadmap K8). Tests inject a fake.
protocol GatewayControl: Sendable {
    func state() async -> GatewayStatus.State
    func start() async throws -> CommandResult
}

extension GatewayStatus: GatewayControl {}

/// Settings → Kanban dispatcher: is `hermes gateway` running, and a Start action when it is installed but
/// stopped. Never installs: when the LaunchAgent is missing the view shows `GatewayStatus.installCommand`
/// for the user to run. One action at a time (`busy`); output and errors are scrubbed before display.
@MainActor
final class GatewaySettingsModel: ObservableObject {
    /// After a successful start the gateway needs a moment to publish its record: re-read the state this
    /// many times, `settleDelay` apart, until it reports running.
    static let settleAttempts = 5
    static let maxOutput = 300

    /// nil until the first `refresh()` answers.
    @Published private(set) var state: GatewayStatus.State?
    @Published private(set) var busy = false
    @Published private(set) var starting = false
    /// Tail of `hermes gateway start` output after a successful start.
    @Published private(set) var output: String?
    @Published private(set) var error: String?

    let control: any GatewayControl
    private let settleDelay: Duration

    init(control: any GatewayControl = GatewayStatus(), settleDelay: Duration = .seconds(1)) {
        self.control = control
        self.settleDelay = settleDelay
    }

    var canStart: Bool { state == .installedNotRunning && !busy }

    var summary: (title: String, tone: SettingsTone) {
        switch state {
        case nil: return ("Checking…", .neutral)
        case .running(let pid)?: return ("Running (pid \(pid))", .ok)
        case .installedNotRunning?: return ("Stopped", .attention)
        case .notInstalled?: return ("Not installed", .neutral)
        case .unknown?: return ("Status unknown", .attention)
        }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        state = await control.state()
        busy = false
    }

    func start() async {
        guard canStart else { return }
        busy = true
        starting = true
        output = nil
        error = nil
        var ok = false
        do {
            let r = try await control.start()
            ok = true
            let text = Redaction.scrub(r.output).trimmingCharacters(in: .whitespacesAndNewlines)
            output = text.isEmpty ? nil : String(text.suffix(Self.maxOutput))
        } catch {
            self.error = Redaction.describe(error)
        }
        state = await control.state()
        if ok {
            var attempts = 0
            while attempts < Self.settleAttempts, !isRunning {
                attempts += 1
                try? await Task.sleep(for: settleDelay)
                state = await control.state()
            }
        }
        starting = false
        busy = false
    }

    private var isRunning: Bool { if case .running? = state { return true }; return false }
}
