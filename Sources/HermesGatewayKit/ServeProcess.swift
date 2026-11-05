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
///   Same-home mode deliberately shares them: as probed against hermes-agent, the per-room durable lease fences
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
        /// Paths the default lookup tried, for `binaryNotFound`. Empty = `hermesExecutable` was given.
        var executableSearch: [String] = []
        /// Why `HERMES_BOT_APP_HERMES_BIN` cannot name the executable (not an absolute path), or nil.
        var executableProblem: String?

        public init(hermesExecutable: URL, hermesHome: URL, lockDir: URL?, logFile: URL) {
            self.hermesExecutable = hermesExecutable
            self.hermesHome = hermesHome
            self.lockDir = lockDir
            self.logFile = logFile
        }

        /// `hermes` lookup order: `HERMES_BOT_APP_HERMES_BIN` (if set, it replaces the search: nothing
        /// else is tried; `~/` expands to the home dir), `~/.local/bin`, each absolute dir of this
        /// process's `$PATH` (a Finder-launched app gets launchd's minimal one), `/opt/homebrew/bin`,
        /// `/usr/local/bin`. Deduplicated, in order.
        static func executableCandidates(environment env: [String: String], home: URL) -> [String] {
            if let o = env["HERMES_BOT_APP_HERMES_BIN"], !o.isEmpty {
                return [o.hasPrefix("~/") ? home.appendingPathComponent(String(o.dropFirst(2))).path : o]
            }
            var all = [home.appendingPathComponent(".local/bin/hermes").path]
            for dir in (env["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") {
                all.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("hermes").path)
            }
            all += ["/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            var seen = Set<String>()
            return all.filter { seen.insert($0).inserted }
        }

        /// First absolute candidate `isExecutableFile` accepts (nil if none), plus every path tried, and
        /// why the override is unusable (a relative path is never resolved against the working dir).
        static func resolveExecutable(environment env: [String: String], home: URL,
                                      isExecutableFile: (String) -> Bool = ServeProcess.isExecutableFile)
            -> (url: URL?, tried: [String], problem: String?) {
            let tried = executableCandidates(environment: env, home: home)
            if let bad = tried.first(where: { !$0.hasPrefix("/") }) {
                return (nil, tried, "HERMES_BOT_APP_HERMES_BIN (\(bad)) must be an absolute path")
            }
            return (tried.first(where: isExecutableFile).map(URL.init(fileURLWithPath:)), tried, nil)
        }

        /// Unresolved: the first candidate, so `start()` fails with `binaryNotFound` listing them all.
        static func defaultExecutable() -> (url: URL, tried: [String], problem: String?) {
            let r = resolveExecutable(environment: ProcessInfo.processInfo.environment,
                                      home: FileManager.default.homeDirectoryForCurrentUser)
            return (r.url ?? URL(fileURLWithPath: r.tried[0]), r.tried, r.problem)
        }

        /// Defaults used by the M0 spike: `~/.hermes-bot-app-spike/{home,locks,serve.log}`.
        public static func spikeDefault() -> Configuration {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes-bot-app-spike")
            let exe = defaultExecutable()
            var c = Configuration(
                hermesExecutable: exe.url,
                hermesHome: base.appendingPathComponent("home"),
                lockDir: base.appendingPathComponent("locks"),
                logFile: base.appendingPathComponent("serve.log"))
            c.executableSearch = exe.tried
            c.executableProblem = exe.problem
            return c
        }

        /// M1 spawn-if-absent: `hermes serve --host 127.0.0.1 --port 0 --isolated` on the user's own
        /// root (`~/.hermes`). `lockDir` nil = the real per-user rendezvous dir. Log:
        /// `~/Library/Logs/HermesBotApp/serve.log`.
        public static func sameHomeDefault(lockDir: URL? = nil) -> Configuration {
            let fm = FileManager.default
            let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HermesBotApp")
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            let exe = defaultExecutable()
            var c = Configuration(
                hermesExecutable: exe.url,
                hermesHome: fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
                lockDir: lockDir,
                logFile: logs.appendingPathComponent("serve.log"))
            c.executableSearch = exe.tried
            c.executableProblem = exe.problem
            c.isolated = true
            c.allowDefaultRoot = true
            return c
        }
    }

    /// Every case carries the serve.log path, so the text always says where to look.
    public enum ServeError: Error, CustomStringConvertible {
        case homeInsideDefaultRoot(String, log: String)
        case binaryNotFound(tried: [String], log: String)
        /// The named executable exists but cannot be used as given (relative path, a directory, not executable).
        case invalidBinary(path: String, reason: String, log: String)
        case untrustedBinary(path: String, reason: String, log: String)
        case launchFailed(String, log: String)
        case exitedBeforeReady(Int32, log: String)
        case readyTimeout(log: String)
        public var description: String {
            switch self {
            case .homeInsideDefaultRoot(let p, let log):
                return "HERMES_HOME \(p) is inside ~/.hermes and would share its shared-state.db (log: \(log))"
            case .binaryNotFound(let tried, let log):
                return "hermes executable not found; tried \(tried.joined(separator: ", ")). "
                    + "Set HERMES_BOT_APP_HERMES_BIN to its full path (log: \(log))"
            case .invalidBinary(let path, let reason, let log):
                return "cannot run \(path): \(reason). Set HERMES_BOT_APP_HERMES_BIN to the full path of the "
                    + "hermes executable (log: \(log))"
            case .untrustedBinary(let path, let reason, let log):
                return "refusing to run \(path): \(reason). Fix its permissions or set HERMES_BOT_APP_HERMES_BIN "
                    + "to a trusted copy (log: \(log))"
            case .launchFailed(let why, let log): return "could not launch hermes serve: \(why) (log: \(log))"
            case .exitedBeforeReady(let c, let log): return "hermes serve exited (status \(c)) before READY; see \(log)"
            case .readyTimeout(let log): return "hermes serve did not print HERMES_BACKEND_READY in time; see \(log)"
            }
        }
    }

    /// Regular file (symlinks followed: the target is what runs) that this process may execute.
    static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }

    /// Why a binary with this mode/owner must not be launched, or nil.
    static func binaryTrustProblem(mode: mode_t, owner: uid_t, me: uid_t = getuid()) -> String? {
        if mode & 0o022 != 0 { return "it is group- or world-writable (mode \(String(mode & 0o7777, radix: 8)))" }
        if owner != me && owner != 0 { return "it is owned by uid \(owner), neither you (uid \(me)) nor root" }
        return nil
    }

    /// Why the binary's directory makes it replaceable by others (group/world-writable without the
    /// sticky bit: anyone with write access can rename another file over it), or nil.
    static func directoryTrustProblem(mode: mode_t, path: String) -> String? {
        guard mode & 0o022 != 0, mode & S_ISVTX == 0 else { return nil }
        return "its directory \(path) is group- or world-writable without the sticky bit (mode \(String(mode & 0o7777, radix: 8)))"
    }

    /// `path` must already be resolved (`resolvedPath`): the checks apply to what actually runs.
    static func binaryTrustProblem(path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return "it cannot be inspected" }
        if let why = binaryTrustProblem(mode: st.st_mode, owner: st.st_uid) { return why }
        let dir = (path as NSString).deletingLastPathComponent
        guard stat(dir, &st) == 0 else { return "its directory \(dir) cannot be inspected" }
        return directoryTrustProblem(mode: st.st_mode, path: dir)
    }

    /// Symlinks resolved (`realpath`), or nil when the path does not exist.
    static func resolvedPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Why a binary named explicitly (`HERMES_BOT_APP_HERMES_BIN` or `hermesExecutable`) is unusable even
    /// though something exists at that path, or nil (fine, or missing: `binaryNotFound`).
    static func explicitBinaryProblem(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return isExecutableFile(path) ? nil : "it is not a regular executable file"
    }

    public let configuration: Configuration
    public private(set) var port: Int?
    /// Session token for `?token=` on /api/ws. Never logged.
    public let sessionToken: String
    private let process = Process()
    private var logHandle: FileHandle?
    private var pipes: [Pipe] = []
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
        let logPath = configuration.logFile.path
        if !configuration.allowDefaultRoot && (home == defaultRoot || home.hasPrefix(defaultRoot + "/")) {
            throw ServeError.homeInsideDefaultRoot(home, log: logPath)
        }
        if let lockDir = configuration.lockDir {
            try fm.createDirectory(at: lockDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.createDirectory(at: configuration.logFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
        }
        let handle = try FileHandle(forWritingTo: configuration.logFile)
        _ = try? handle.seekToEnd()
        lock.withLock { logHandle = handle }
        appendLog(Data("--- ServeProcess start \(Date()) ---\n".utf8))

        // Checked before Process.run(), so a missing binary never surfaces as a raw NSCocoaErrorDomain error.
        let exe = configuration.hermesExecutable.path
        let search = configuration.executableSearch
        if let why = configuration.executableProblem {
            throw failBeforeLaunch(.invalidBinary(path: search.first ?? exe, reason: why, log: logPath))
        }
        guard Self.isExecutableFile(exe), let resolved = Self.resolvedPath(exe) else {
            // A path named on its own (override or given) that exists is wrong, not missing.
            if search.count <= 1, let why = Self.explicitBinaryProblem(exe) {
                throw failBeforeLaunch(.invalidBinary(path: exe, reason: why, log: logPath))
            }
            throw failBeforeLaunch(.binaryNotFound(tried: search.contains(exe) ? search : [exe], log: logPath))
        }
        if let why = Self.binaryTrustProblem(path: resolved) {
            throw failBeforeLaunch(.untrustedBinary(path: exe, reason: resolved == exe ? why : "\(why) (it resolves to \(resolved))",
                                                    log: logPath))
        }

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

        process.executableURL = URL(fileURLWithPath: resolved)  // exactly the file the trust checks passed
        process.arguments = ["serve", "--host", configuration.host, "--port", String(configuration.port)]
            + (configuration.isolated ? ["--isolated"] : [])
        process.environment = env
        process.currentDirectoryURL = configuration.hermesHome
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        lock.withLock { pipes = [out, err] }

        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.appendLog(d) }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.consumeStdout(d) }
        }
        process.terminationHandler = { [weak self] p in
            self?.resolveReady(.failure(ServeError.exitedBeforeReady(p.terminationStatus, log: logPath)))
        }

        // Cancelled (the app quits mid-connect): fail the wait, so the caller's `stop()` ends the child.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock(); readyContinuation = cont; lock.unlock()
                if Task.isCancelled { resolveReady(.failure(CancellationError())); return }
                launch(logPath: logPath)
            }
        } onCancel: { [weak self] in
            self?.resolveReady(.failure(CancellationError()))
        }
    }

    private func failBeforeLaunch(_ e: ServeError) -> ServeError {
        appendLog(Data("\(e)\n".utf8))
        return e
    }

    private func launch(logPath: String) {
        do { try process.run() } catch {
            let ns = error as NSError
            resolveReady(.failure(ServeError.launchFailed("\(ns.domain) \(ns.code): \(ns.localizedDescription)",
                                                          log: logPath)))
            return
        }
        let timeout = configuration.readyTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolveReady(.failure(ServeError.readyTimeout(log: logPath)))
        }
    }

    /// SIGTERM, then SIGKILL after `grace` seconds. Only ever touches the child this object spawned.
    /// Always detaches the pipe readers and closes the log, so a late chunk can never hit a closed handle.
    public func stop(grace: TimeInterval = 10) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(grace)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        lock.lock(); defer { lock.unlock() }
        for p in pipes { p.fileHandleForReading.readabilityHandler = nil }
        pipes = []
        try? logHandle?.close()
        logHandle = nil
    }

    /// No-op once `stop()` closed the log.
    private func appendLog(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        try? logHandle?.write(contentsOf: d)
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
