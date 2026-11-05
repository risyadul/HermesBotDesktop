import Darwin
import Foundation

/// Outcome of one finished command.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    /// stdout + stderr interleaved, capped at `ProcessCommandRunner.maxOutput` bytes (tail kept).
    public let output: String
    public let timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status; self.output = output; self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs a local executable. Injected into `BackgroundServe` (`/bin/launchctl`) and `GatewayStatus`
/// (`hermes gateway start`) so tests use fakes and never touch launchd.
public protocol CommandRunner: Sendable {
    /// `executable` must be absolute. `environment: nil` = `ProcessCommandRunner.cleanEnvironment()`.
    /// Throws when the process cannot be launched, or `CancellationError` when the calling task was
    /// cancelled (the process is then terminated); a non-zero exit is a result.
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult
}

/// `Foundation.Process` runner: no shell, clean environment, stdin from /dev/null, SIGTERM at the timeout
/// (or when the calling task is cancelled) then SIGKILL after 2 s.
///
/// Output is read while the process runs (a readability handler on a background queue, tail capped at
/// `maxOutput`), never with a blocking read after exit: a grandchild that inherited the pipe (e.g. a daemon
/// the command started) keeps it open, so once the process has exited the runner waits at most `eofGrace`
/// for end-of-file and then answers with what arrived.
public struct ProcessCommandRunner: CommandRunner {
    public static let maxOutput = 64 * 1024
    /// How long to wait for the pipe's end-of-file once the process has exited.
    public static let eofGrace: TimeInterval = 0.5
    static let killDelay: TimeInterval = 2

    public struct LaunchError: Error, RedactionSafeError {
        public let description: String
    }

    public init() {}

    /// HOME/USER/LOGNAME/LANG/TMPDIR from this process, a fixed PATH (no inherited HERMES_* variables).
    public static func cleanEnvironment(_ parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"] { if let v = parent[key] { env[key] = v } }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        return env
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
                    timeout: TimeInterval) async throws -> CommandResult {
        guard executable.hasPrefix("/") else { throw LaunchError(description: "\(executable) is not an absolute path") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? Self.cleanEnvironment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let run = Run(process: process, reader: pipe.fileHandleForReading)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { run.reachedEOF() } else { run.append(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                run.setContinuation(cont)
                process.terminationHandler = { p in
                    run.exited(status: p.terminationStatus)
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.eofGrace) { run.finish() }
                }
                do { try process.run() } catch {
                    let ns = error as NSError
                    run.fail(LaunchError(description: "could not run \(executable): \(ns.domain) \(ns.code)"))
                    return
                }
                run.launched()
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout)) { run.stop(timedOut: true) }
            }
        } onCancel: {
            run.stop(timedOut: false)
        }
    }

    /// One run's shared state: output tail, exit, EOF, and the continuation (resumed exactly once).
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let reader: FileHandle
        private var data = Data()
        private var status: Int32?
        private var eof = false
        private var isLaunched = false
        private var timedOut = false
        private var cancelled = false
        private var done = false
        private var continuation: CheckedContinuation<CommandResult, Error>?

        init(process: Process, reader: FileHandle) { self.process = process; self.reader = reader }

        func setContinuation(_ c: CheckedContinuation<CommandResult, Error>) { lock.withLock { continuation = c } }

        func append(_ d: Data) {
            lock.withLock {
                data.append(d)
                if data.count > ProcessCommandRunner.maxOutput { data = data.suffix(ProcessCommandRunner.maxOutput) }
            }
        }

        func reachedEOF() {
            reader.readabilityHandler = nil
            let ready = lock.withLock { () -> Bool in eof = true; return status != nil }
            if ready { finish() }
        }

        func exited(status s: Int32) {
            let ready = lock.withLock { () -> Bool in status = s; return eof }
            if ready { finish() }
        }

        /// The process is running: a cancellation that came before the launch stops it now.
        func launched() {
            let stopNow = lock.withLock { () -> Bool in isLaunched = true; return cancelled }
            if stopNow { terminate() }
        }

        /// Timeout (`timedOut`) or task cancellation: SIGTERM, then SIGKILL after `killDelay`. No-op once the
        /// process has exited.
        func stop(timedOut t: Bool) {
            let running = lock.withLock { () -> Bool in
                guard !done, status == nil else { return false }
                if t { timedOut = true } else { cancelled = true }
                return isLaunched
            }
            if running { terminate() }
        }

        private func terminate() {
            let process = self.process
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessCommandRunner.killDelay) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        func fail(_ error: Error) {
            let c = lock.withLock { () -> CheckedContinuation<CommandResult, Error>? in
                guard !done else { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            reader.readabilityHandler = nil
            c?.resume(throwing: error)
        }

        /// Resumes once: after exit and EOF, or `eofGrace` after exit when something still holds the pipe.
        func finish() {
            let outcome = lock.withLock { () -> (CheckedContinuation<CommandResult, Error>, Result<CommandResult, Error>)? in
                guard !done, let status, let continuation else { return nil }
                done = true
                self.continuation = nil
                if cancelled { return (continuation, .failure(CancellationError())) }
                let result = CommandResult(status: status, output: String(decoding: data, as: UTF8.self), timedOut: timedOut)
                return (continuation, .success(result))
            }
            guard let (c, result) = outcome else { return }
            reader.readabilityHandler = nil
            c.resume(with: result)
        }
    }
}
