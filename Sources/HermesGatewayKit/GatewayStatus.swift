import Darwin
import Foundation

/// Status of the Hermes messaging gateway (`hermes gateway`), which also runs the kanban dispatcher
/// (roadmap K8): without it, ready+assigned tasks sit idle.
///
/// - Running: the gateway publishes `<lockDir>/host-gateway.json` (`ROLE_GATEWAY`, `gateway/host_rendezvous.py:64`;
///   pid, start time, no port). It is read with the same rules as `HostRendezvous` (lock dir owned by this
///   uid, not a symlink, not group/world-writable; record opened with `O_NOFOLLOW`, owned by this uid), and
///   the pid must be alive with a matching start time when that can be proven (`incarnationMatches`).
/// - Installed: Hermes' own LaunchAgent `ai.hermes.gateway` (`hermes_cli/gateway_launchd.py:28-31`; plist
///   `~/Library/LaunchAgents/ai.hermes.gateway.plist`, `hermes_cli/gateway.py:2924-2928`). Named profiles get
///   `ai.hermes.gateway-<profile>`; only the default profile's agent is checked here.
///
/// `start()` runs `<hermes> gateway start` (launchd kickstart of that agent). It never installs: when the agent
/// is missing the UI shows `installCommand` for the user to run.
public struct GatewayStatus: Sendable {
    public static let launchAgentLabel = "ai.hermes.gateway"
    public static let recordName = "host-gateway.json"
    public static let installCommand = "hermes gateway install"
    public static let startTimeout: TimeInterval = 90

    public enum State: Sendable, Equatable {
        case running(pid: Int32)
        case installedNotRunning
        case notInstalled
        /// The record exists but cannot be trusted or read; `reason` is safe to show.
        case unknown(String)
    }

    public enum Failure: Error, RedactionSafeError, Equatable {
        /// No LaunchAgent: run `installCommand` (never done automatically).
        case notInstalled
        case hermes(String)
        case startFailed(status: Int32, output: String)

        public var description: String {
            switch self {
            case .notInstalled: return "the Hermes gateway is not installed; run `\(GatewayStatus.installCommand)`"
            case .hermes(let m): return m
            case .startFailed(let s, let o): return "`hermes gateway start` failed (status \(s))" + (o.isEmpty ? "" : ": \(o)")
            }
        }
    }

    public let lockDir: URL
    public let home: URL
    let environment: [String: String]
    let runner: any CommandRunner

    public init(lockDir: URL = HostRendezvous.lockDir(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: any CommandRunner = ProcessCommandRunner()) {
        self.lockDir = lockDir; self.home = home; self.environment = environment; self.runner = runner
    }

    public var launchAgentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist") }

    public func state() -> State {
        switch recordState() {
        case .some(.running(let pid)): return .running(pid: pid)
        case .some(.unknown(let why)): return .unknown(why)
        default:
            return HostRendezvous.lstatInfo(launchAgentPlist) != nil ? .installedNotRunning : .notInstalled
        }
    }

    /// `.running`, `.unknown`, or nil (no live gateway recorded).
    func recordState() -> State? {
        let url = lockDir.appendingPathComponent(Self.recordName)
        guard HostRendezvous.lstatInfo(url) != nil else { return nil }
        if let why = HostRendezvous.lockDirProblem(lockDir) { return .unknown(why) }
        guard let (data, info) = HostRendezvous.readNoFollow(url) else {
            return .unknown("gateway record is a symlink, not a regular file, or unreadable")
        }
        guard info.st_uid == getuid() else { return .unknown("gateway record not owned by this uid") }
        guard let record = try? JSONDecoder().decode(HostRendezvous.Record.self, from: data) else {
            return .unknown("gateway record unreadable/corrupt")
        }
        guard record.role == "gateway", record.pid > 0 else { return .unknown("gateway record role/pid invalid") }
        switch HostRendezvous.incarnationMatches(record) {
        case .some(true): return .running(pid: record.pid)
        case .some(false): return nil  // dead or a reused pid: a stale record
        case .none:
            // Start time unprovable: fall back to liveness alone (kill(pid, 0)).
            switch HostRendezvous.pidAlive(record.pid) {
            case .some(true): return .running(pid: record.pid)
            case .some(false): return nil
            case .none: return .unknown("cannot check gateway pid \(record.pid)")
            }
        }
    }

    /// Runs `<hermes> gateway start`. Refuses (`.notInstalled`) when the LaunchAgent is missing.
    @discardableResult
    public func start() async throws -> CommandResult {
        guard HostRendezvous.lstatInfo(launchAgentPlist) != nil else { throw Failure.notInstalled }
        let hermes: String
        switch ServeProcess.trustedExecutable(environment: environment, home: home, log: home.appendingPathComponent(".hermes/logs").path) {
        case .success(let path): hermes = path
        case .failure(let e): throw Failure.hermes(e.description)
        }
        var env = ProcessCommandRunner.cleanEnvironment(environment)
        env["HOME"] = home.path
        env["HERMES_HOME"] = home.appendingPathComponent(".hermes").path
        env["PATH"] = BackgroundServe.path(hermes: hermes, home: home.path)
        let r: CommandResult
        do { r = try await runner.run(hermes, ["gateway", "start"], environment: env, timeout: Self.startTimeout) } catch {
            throw Failure.startFailed(status: -1, output: Redaction.describe(error))
        }
        guard r.succeeded else {
            let tail = Redaction.scrub(r.output).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            throw Failure.startFailed(status: r.status, output: r.timedOut ? "timed out. \(tail)" : String(tail))
        }
        return r
    }
}
