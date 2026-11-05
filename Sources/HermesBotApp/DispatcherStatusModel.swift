import Foundation
import HermesGatewayKit

/// What the dispatcher status needs from `GatewayStatus` (roadmap K8). Tests inject a fake.
protocol GatewayControl: Sendable {
    func state() async -> GatewayStatus.State
    func start() async throws -> CommandResult
}

extension GatewayStatus: GatewayControl {}

/// `hermes gateway` runs the kanban dispatcher: without it, ready + assigned cards never start. One instance
/// for the whole app (`AppModel.shared.kanban.dispatcher`), shown by the board header's chip and by
/// Settings → Kanban dispatcher, so both always agree.
///
/// - `refresh()` re-reads the state (local file checks only); the hub polls it while a board is on screen.
/// - `start()` runs `hermes gateway start` when the LaunchAgent is installed but stopped, then re-reads the
///   state up to `settleAttempts` times, `settleDelay` apart, until it reports running. Never installs: when
///   the agent is missing the UI shows `GatewayStatus.installCommand` for the user to run.
/// - One Start at a time; output and errors are scrubbed before display.
/// - `reset()` (the hub's connect / disconnect) bumps a generation: a refresh or Start still in flight from
///   before writes nothing afterwards.
@MainActor
final class DispatcherStatusModel: ObservableObject {
    static let settleAttempts = 5
    static let maxOutput = 300

    /// nil until the first `refresh()` answers.
    @Published private(set) var state: GatewayStatus.State?
    @Published private(set) var starting = false
    /// Tail of `hermes gateway start` output after a successful start.
    @Published private(set) var output: String?
    /// Why the last Start failed, in plain words.
    @Published private(set) var error: String?
    /// The last Start succeeded.
    @Published private(set) var started = false

    let control: any GatewayControl
    private let settleDelay: Duration
    private(set) var generation = 0
    private var refreshing = false

    init(control: any GatewayControl = GatewayStatus(), settleDelay: Duration = .seconds(1)) {
        self.control = control
        self.settleDelay = settleDelay
    }

    var canStart: Bool { state == .installedNotRunning && !starting }

    /// Settings' status line.
    var summary: (title: String, tone: SettingsTone) {
        switch state {
        case nil: return ("Checking…", .neutral)
        case .running(let pid)?: return ("Running (pid \(pid))", .ok)
        case .installedNotRunning?: return ("Stopped", .attention)
        case .notInstalled?: return ("Not installed", .neutral)
        case .unknown?: return ("Status unknown", .attention)
        }
    }

    /// The chip's one-line outcome of the last Start.
    var startResult: String? { error.map { "Start failed: \($0)" } ?? (started ? "Dispatcher started." : nil) }
    var startFailed: Bool { error != nil }

    /// Drops what an in-flight refresh or Start would still write, and the last Start's outcome. The state
    /// itself is kept (it is a local fact, not a connection's).
    func reset() {
        generation += 1
        refreshing = false
        starting = false
        output = nil
        error = nil
        started = false
    }

    func refresh() async {
        guard !refreshing, !starting else { return }
        refreshing = true
        let gen = generation
        let s = await control.state()
        guard gen == generation else { return }
        refreshing = false
        state = s
    }

    func start() async {
        guard canStart else { return }
        let gen = generation
        starting = true
        output = nil
        error = nil
        started = false
        var ok = false
        do {
            let r = try await control.start()
            guard gen == generation else { return }
            ok = true
            let text = Redaction.scrub(r.output).trimmingCharacters(in: .whitespacesAndNewlines)
            output = text.isEmpty ? nil : String(text.suffix(Self.maxOutput))
        } catch {
            guard gen == generation else { return }
            self.error = Redaction.describe(error)
        }
        let s = await control.state()
        guard gen == generation else { return }
        state = s
        if ok {
            var attempts = 0
            while attempts < Self.settleAttempts, !isRunning {
                attempts += 1
                try? await Task.sleep(for: settleDelay)
                let next = await control.state()
                guard gen == generation else { return }
                state = next
            }
        }
        started = ok
        starting = false
    }

    private var isRunning: Bool { if case .running? = state { return true }; return false }
}
