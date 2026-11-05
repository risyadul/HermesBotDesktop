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
    /// Throws only when the process cannot be launched; a non-zero exit is a result.
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult
}

/// `Foundation.Process` runner: no shell, clean environment, stdin from /dev/null, SIGTERM at the timeout
/// then SIGKILL after 2 s.
public struct ProcessCommandRunner: CommandRunner {
    public static let maxOutput = 64 * 1024

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
        let box = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                box.append((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                cont.resume(returning: CommandResult(status: p.terminationStatus, output: box.text, timedOut: box.timedOut))
            }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                let ns = error as NSError
                cont.resume(throwing: LaunchError(description: "could not run \(executable): \(ns.domain) \(ns.code)"))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout)) {
                guard process.isRunning else { return }
                box.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
            }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var _timedOut = false

        func append(_ d: Data) {
            guard !d.isEmpty else { return }
            lock.withLock {
                data.append(d)
                if data.count > ProcessCommandRunner.maxOutput { data = data.suffix(ProcessCommandRunner.maxOutput) }
            }
        }

        func markTimedOut() { lock.withLock { _timedOut = true } }
        var timedOut: Bool { lock.withLock { _timedOut } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
