import Foundation

/// Launches and owns one `hermes serve` backend for this app.
///
/// Two modes: the M0 spike (private home + private lock dir, below) and the M1 spawn-if-absent
/// fallback (`Configuration.sameHomeDefault()`: `HERMES_HOME=~/.hermes`, `--isolated`, default lock
/// dir). The clean-env, token, parent-watchdog and stop rules below apply to both.
///
/// Rules (see docs/gateway-contract.md §1, verified against hermes-agent source):
/// - The child gets a CLEAN environment (no inherited HERMES_* from whatever shell/agent launched us).
/// - Spike mode only: `HERMES_HOME` points at a root OUTSIDE `~/.hermes`, so `gateway.hosted_rooms.default_db_path()`
///   resolves to `<home>/shared-state.db` and `local_authority_gateway_id()` to that root's own
///   install_id. Under `~/.hermes` every serve/gateway process shares ROOT `shared-state.db` and the
///   same authority, so the Electron backend's room worker could lease and run our rooms.
///   Same-home mode deliberately shares them: per probe t_8cf3b257 the per-room durable lease fences
///   double execution, and 1:1 chat sessions do not touch rooms at all.
/// - Spike mode only: `HERMES_GATEWAY_LOCK_DIR` is private, so this serve never claims/reads the per-OS-user host
///   rendezvous records (`~/.local/state/hermes/gateway-locks/host-*.json`) the Electron app's attach
///   ladder and `_reclaim_host_from_orphaned_owner` use.
/// - No `HERMES_DESKTOP=1`: the backend is not "desktop-owned", so it never runs the desktop orphan reap.
/// - `HERMES_PARENT_PID` arms the backend's parent-death watchdog, so it exits if we die.
/// - The session token is minted per start and handed to the child via env. It is NOT memory-only:
///   the serve publishes it to `<lockDir>/host-serve.token` (owner-only 0600) next to its rendezvous
///   record and removes both on a graceful exit (SIGTERM/atexit). A SIGKILL/crash can leave the file
///   until the next serve in the same lock dir discards the dead record. See contract doc §1.
/// - One owned serve per lock dir: a second start while the first lives attaches-first and exits 0
///   without READY (surfaced as `exitedBeforeReady(0)`).
public final class ServeProcess: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var hermesExecutable: URL
        /// `HERMES_HOME` for the child. Spike mode: a root outside `~/.hermes`. Same-home mode (M1):
        /// `~/.hermes` itself, so the child serves the user's real profiles.
        public var hermesHome: URL
        /// `HERMES_GATEWAY_LOCK_DIR` for the child. `nil` = not set: the child uses the per-OS-user
        /// default (`~/.local/state/hermes/gateway-locks`), i.e. the same dir `HostRendezvous` reads.
        public var lockDir: URL?
        public var logFile: URL
        public var host: String = "127.0.0.1"
        public var port: Int = 0  // 0 = OS-assigned; real port comes from the READY sentinel
        public var readyTimeout: TimeInterval = 120
        /// `--isolated`: skip the child's own attach-first ladder (`main_dashboard.py:895`), so it
        /// binds even if a `host-serve` owner appeared between our discovery and its start. It does
        /// NOT stop the child from publishing `host-serve` (`web_server.py:1319-1367`).
        public var isolated: Bool = false
        /// Guard: refuse a home inside `~/.hermes` unless explicitly allowed (same-home mode).
        public var allowDefaultRoot: Bool = false

        public init(hermesExecutable: URL, hermesHome: URL, lockDir: URL?, logFile: URL) {
            self.hermesExecutable = hermesExecutable
            self.hermesHome = hermesHome
            self.lockDir = lockDir
            self.logFile = logFile
        }

        static func defaultExecutable() -> URL {
            ProcessInfo.processInfo.environment["HERMES_BOT_APP_HERMES_BIN"].map(URL.init(fileURLWithPath:))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes")
        }

        /// Defaults used by the M0 spike: `~/.hermes-bot-app-spike/{home,locks,serve.log}`.
        public static func spikeDefault() -> Configuration {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes-bot-app-spike")
            return Configuration(
                hermesExecutable: defaultExecutable(),
                hermesHome: base.appendingPathComponent("home"),
                lockDir: base.appendingPathComponent("locks"),
                logFile: base.appendingPathComponent("serve.log"))
        }

        /// M1 spawn-if-absent: `hermes serve --host 127.0.0.1 --port 0 --isolated` on the user's own
        /// root (`~/.hermes`). `lockDir` nil = the real per-user rendezvous dir. Log:
        /// `~/Library/Logs/HermesBotApp/serve.log`.
        public static func sameHomeDefault(lockDir: URL? = nil) -> Configuration {
            let fm = FileManager.default
            let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HermesBotApp")
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
            var c = Configuration(
                hermesExecutable: defaultExecutable(),
                hermesHome: fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
                lockDir: lockDir,
                logFile: logs.appendingPathComponent("serve.log"))
            c.isolated = true
            c.allowDefaultRoot = true
            return c
        }
    }

    public enum ServeError: Error, CustomStringConvertible {
        case homeInsideDefaultRoot(String)
        case exitedBeforeReady(Int32)
        case readyTimeout
        public var description: String {
            switch self {
            case .homeInsideDefaultRoot(let p): return "HERMES_HOME \(p) is inside ~/.hermes and would share its shared-state.db"
            case .exitedBeforeReady(let c): return "hermes serve exited (status \(c)) before READY"
            case .readyTimeout: return "hermes serve did not print HERMES_BACKEND_READY in time"
            }
        }
    }

    public let configuration: Configuration
    public private(set) var port: Int?
    /// Session token for `?token=` on /api/ws. Never logged.
    public let sessionToken: String
    private let process = Process()
    private var logHandle: FileHandle?
    private var stdoutBuffer = Data()
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Int, Error>?

    public init(configuration: Configuration) {
        self.configuration = configuration
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.sessionToken = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public var wsURL: URL? {
        guard let port else { return nil }
        var c = URLComponents()
        c.scheme = "ws"; c.host = configuration.host; c.port = port; c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: sessionToken)]
        return c.url
    }

    /// Starts the backend and resolves with the bound port once `HERMES_BACKEND_READY port=N` appears.
    public func start() async throws -> Int {
        let fm = FileManager.default
        let defaultRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").standardizedFileURL.path
        let home = configuration.hermesHome.standardizedFileURL.path
        if !configuration.allowDefaultRoot && (home == defaultRoot || home.hasPrefix(defaultRoot + "/")) {
            throw ServeError.homeInsideDefaultRoot(home)
        }
        if let lockDir = configuration.lockDir {
            try fm.createDirectory(at: lockDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: configuration.logFile.path) {
            fm.createFile(atPath: configuration.logFile.path, contents: nil)
        }
        logHandle = try FileHandle(forWritingTo: configuration.logFile)
        logHandle?.seekToEndOfFile()
        logHandle?.write(Data("--- ServeProcess start \(Date()) ---\n".utf8))

        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL"] {
            if let v = parent[key] { env[key] = v }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (parent["PATH"] ?? "")
        env["HERMES_HOME"] = home
        if let lockDir = configuration.lockDir { env["HERMES_GATEWAY_LOCK_DIR"] = lockDir.path }
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = sessionToken
        env["HERMES_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)

        process.executableURL = configuration.hermesExecutable
        process.arguments = ["serve", "--host", configuration.host, "--port", String(configuration.port)]
            + (configuration.isolated ? ["--isolated"] : [])
        process.environment = env
        process.currentDirectoryURL = configuration.hermesHome
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.appendLog(d) }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.consumeStdout(d) }
        }
        process.terminationHandler = { [weak self] p in
            self?.resolveReady(.failure(ServeError.exitedBeforeReady(p.terminationStatus)))
        }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); readyContinuation = cont; lock.unlock()
            do { try process.run() } catch { resolveReady(.failure(error)); return }
            let timeout = configuration.readyTimeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveReady(.failure(ServeError.readyTimeout))
            }
        }
    }

    /// SIGTERM, then SIGKILL after `grace` seconds. Only ever touches the child this object spawned.
    public func stop(grace: TimeInterval = 10) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? logHandle?.close()
    }

    private func appendLog(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        logHandle?.write(d)
    }

    private func consumeStdout(_ d: Data) {
        appendLog(d)
        lock.lock()
        stdoutBuffer.append(d)
        var found: Int?
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: stdoutBuffer[..<nl], as: UTF8.self)
            stdoutBuffer.removeSubrange(...nl)
            // Headless serve prints the neutral token first, then the legacy one.
            for prefix in ["HERMES_BACKEND_READY port=", "HERMES_DASHBOARD_READY port="] where line.hasPrefix(prefix) {
                found = found ?? Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
        }
        lock.unlock()
        if let found { resolveReady(.success(found)) }
    }

    private func resolveReady(_ result: Result<Int, Error>) {
        lock.lock()
        let cont = readyContinuation
        readyContinuation = nil
        if case .success(let p) = result, cont != nil { port = p }
        lock.unlock()
        cont?.resume(with: result)
    }
}
