import Darwin
import Foundation

/// Opt-in per-user LaunchAgent that keeps `hermes serve` running in the background (roadmap E1), so the app
/// attaches to it like to any other backend instead of spawning its own.
///
/// The agent runs `<hermes> serve --host 127.0.0.1 --port 0` with `HERMES_HOME=~/.hermes`:
/// - no `--isolated`: the serve publishes the `serve` host role in the default lock dir
///   (`gateway/host_rendezvous.py`), which `HostRendezvous.discover` reads first;
/// - no `HERMES_PARENT_PID`: it must outlive the app (launchd is its parent);
/// - no `HERMES_DASHBOARD_SESSION_TOKEN`: the serve mints its own token and publishes it 0600 next to its
///   rendezvous record, so no secret is ever written into the world-readable plist;
/// - `KeepAlive {SuccessfulExit: false}` restarts it after a crash but not after a clean exit (e.g. a
///   second serve that found an owner and exited 0); `ThrottleInterval` 30 s bounds a crash loop.
///
/// The hermes executable is found and checked exactly like the spawn fallback (`ServeProcess.trustedExecutable`:
/// `HERMES_BOT_APP_HERMES_BIN` or the search list, regular executable file, trusted owner/mode/directory);
/// the plist records the symlink-resolved path that passed those checks. Never installed by tests: all
/// file system access is under `home` and every launchctl call goes through `runner`.
public struct BackgroundServe: Sendable {
    /// launchd label, also the plist file name. Reverse-DNS of the project (same prefix as the log subsystem).
    public static let label = "io.github.risyadul.hermesbot.serve"
    public static let launchctl = "/bin/launchctl"
    public static let commandTimeout: TimeInterval = 30

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Plist present and the job is known to launchd.
        case loaded(executable: String)
        /// Plist present but launchd does not have the job (e.g. booted out, or not yet logged in again).
        case installedNotLoaded(executable: String)
        /// Plist present but its program is gone or no longer executable (hermes moved/uninstalled).
        case binaryMissing(path: String)
        /// Plist present but not one this app wrote (wrong label/shape) or unreadable.
        case unreadable(String)

        public var isInstalled: Bool { self != .notInstalled }
    }

    public enum Failure: Error, RedactionSafeError, Equatable {
        case hermes(String)
        case filesystem(String)
        case launchctl(command: String, status: Int32, output: String)

        public var description: String {
            switch self {
            case .hermes(let m): return m
            case .filesystem(let m): return "background serve: \(m)"
            case .launchctl(let c, let s, let o):
                return "launchctl \(c) failed (status \(s))" + (o.isEmpty ? "" : ": \(o)")
            }
        }
    }

    /// The user's home (real one in production; a temp dir in tests).
    public let home: URL
    public let uid: uid_t
    let environment: [String: String]
    let runner: any CommandRunner

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, uid: uid_t = getuid(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: any CommandRunner = ProcessCommandRunner()) {
        self.home = home; self.uid = uid; self.environment = environment; self.runner = runner
    }

    public var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    /// Next to the spawned serve's log (`ServeProcess.Configuration.sameHomeDefault`).
    public var logFile: URL { home.appendingPathComponent("Library/Logs/HermesBotApp/background-serve.log") }
    public var hermesHome: URL { home.appendingPathComponent(".hermes") }
    var domain: String { "gui/\(uid)" }
    var serviceTarget: String { "\(domain)/\(Self.label)" }

    // MARK: - plist (pure)

    /// The agent's property list. All paths must be absolute.
    public static func plist(hermes: String, hermesHome: String, logFile: String, home: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [hermes, "serve", "--host", "127.0.0.1", "--port", "0"],
            "EnvironmentVariables": [
                "HERMES_HOME": hermesHome,
                "HOME": home,
                "PATH": path(hermes: hermes, home: home),
            ],
            "WorkingDirectory": hermesHome,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
        ]
    }

    /// The hermes binary's own dir first (its venv tools), then the usual user/Homebrew/system dirs — the
    /// same fixed prefix `ServeProcess` gives a spawned serve, without inheriting the app's PATH.
    static func path(hermes: String, home: String) -> String {
        var dirs = [(hermes as NSString).deletingLastPathComponent, (home as NSString).appendingPathComponent(".local/bin"),
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        dirs = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return dirs.joined(separator: ":")
    }

    public static func plistData(hermes: String, hermesHome: String, logFile: String, home: String) throws -> Data {
        for p in [hermes, hermesHome, logFile, home] where !p.hasPrefix("/") {
            throw Failure.filesystem("path \(p) is not absolute")
        }
        return try PropertyListSerialization.data(fromPropertyList: plist(hermes: hermes, hermesHome: hermesHome, logFile: logFile, home: home),
                                                  format: .xml, options: 0)
    }

    // MARK: - operations

    public func status() async -> Status {
        guard HostRendezvous.lstatInfo(plistURL) != nil else { return .notInstalled }
        guard let (data, _) = HostRendezvous.readNoFollow(plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .unreadable("plist is a symlink, not a regular file, or not a property list")
        }
        guard plist["Label"] as? String == Self.label, let program = (plist["ProgramArguments"] as? [String])?.first,
              program.hasPrefix("/") else {
            return .unreadable("plist was not written by this app")
        }
        guard ServeProcess.isExecutableFile(program) else { return .binaryMissing(path: program) }
        return await isLoaded() ? .loaded(executable: program) : .installedNotLoaded(executable: program)
    }

    /// Writes the plist (atomically, 0644) and bootstraps it into `gui/<uid>`. A job already loaded is booted
    /// out first, so the new plist takes effect. Throws before touching launchd when hermes fails the checks.
    public func install() async throws {
        let hermes: String
        switch ServeProcess.trustedExecutable(environment: environment, home: home, log: logFile.path) {
        case .success(let path): hermes = path
        case .failure(let e): throw Failure.hermes(e.description)
        }
        let data = try Self.plistData(hermes: hermes, hermesHome: hermesHome.path, logFile: logFile.path, home: home.path)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.filesystem("cannot create directories: \(Redaction.describe(error))")
        }
        if await isLoaded() { try await launchctl(["bootout", serviceTarget]) }
        try writeAtomically(data)
        try await launchctl(["bootstrap", domain, plistURL.path])
    }

    /// Boots the job out of launchd (if loaded) and deletes the plist. Not installed: no-op.
    public func uninstall() async throws {
        if await isLoaded() { try await launchctl(["bootout", serviceTarget]) }
        guard HostRendezvous.lstatInfo(plistURL) != nil else { return }
        do { try FileManager.default.removeItem(at: plistURL) } catch {
            throw Failure.filesystem("cannot remove \(plistURL.path): \(Redaction.describe(error))")
        }
    }

    // MARK: - helpers

    /// `launchctl print gui/<uid>/<label>` exits 0 only for a job launchd knows.
    func isLoaded() async -> Bool {
        let r = try? await runner.run(Self.launchctl, ["print", serviceTarget], environment: nil, timeout: Self.commandTimeout)
        return r?.succeeded ?? false
    }

    func launchctl(_ args: [String]) async throws {
        let r: CommandResult
        do { r = try await runner.run(Self.launchctl, args, environment: nil, timeout: Self.commandTimeout) } catch {
            throw Failure.launchctl(command: args.first ?? "", status: -1, output: Redaction.describe(error))
        }
        guard r.succeeded else {
            throw Failure.launchctl(command: args.first ?? "", status: r.status,
                                    output: String(Redaction.scrub(r.output).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))
        }
    }

    /// Temp file in the same dir, 0644, then `rename(2)` over the plist (replaces a symlink itself, never
    /// writes through one).
    func writeAtomically(_ data: Data) throws {
        let tmp = plistURL.deletingLastPathComponent().appendingPathComponent(".\(Self.label).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw Failure.filesystem("cannot write \(tmp.path)")
        }
        // createFile honours the umask for the initial mode; set it explicitly.
        chmod(tmp.path, 0o644)
        guard rename(tmp.path, plistURL.path) == 0 else {
            let err = String(cString: strerror(errno))
            unlink(tmp.path)
            throw Failure.filesystem("cannot move the plist into place: \(err)")
        }
    }
}
