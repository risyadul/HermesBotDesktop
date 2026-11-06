import Darwin
import Foundation
import XCTest
@testable import HermesGatewayKit

/// Records commands and answers them from a script. Never runs anything.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let arguments: [String]; let environment: [String: String]? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private let answer: @Sendable (String, [String]) -> CommandResult

    init(_ answer: @escaping @Sendable (String, [String]) -> CommandResult = { _, _ in CommandResult(status: 0, output: "") }) {
        self.answer = answer
    }

    var calls: [Call] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { _calls.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        return answer(executable, arguments)
    }
}

/// Mutable "is the job loaded / running" flags shared with a fake launchctl.
final class LaunchdState: @unchecked Sendable {
    private let lock = NSLock()
    private var _loaded: Bool
    private var _running = true
    init(loaded: Bool) { _loaded = loaded }
    var loaded: Bool { get { lock.withLock { _loaded } } set { lock.withLock { _loaded = newValue } } }
    /// While loaded: does `launchctl print` report `state = running`?
    var running: Bool { get { lock.withLock { _running } } set { lock.withLock { _running = newValue } } }

    /// What `launchctl print` would say (trimmed shape of the real output).
    var printOutput: String {
        running
            ? "gui/501/io.github.risyadul.hermesbot.serve = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tendpoints = {\n\t\tstate = waiting\n\t}\n}\n"
            : "gui/501/io.github.risyadul.hermesbot.serve = {\n\tactive count = 0\n\tstate = not running\n\tlast exit code = 1\n}\n"
    }
}

enum TempFS {
    /// A fresh temp dir (0700) with a fake, trusted `hermes` executable inside `bin/`.
    static func home() throws -> (home: URL, hermes: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("hba-test-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        chmod(home.path, 0o700)
        let hermes = home.appendingPathComponent("bin/hermes")
        XCTAssertTrue(fm.createFile(atPath: hermes.path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755]))
        chmod(hermes.path, 0o755)
        return (home, hermes)
    }

    static func real(_ url: URL) -> String { ServeProcess.resolvedPath(url.path) ?? url.path }
}

final class BackgroundServeTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func make(loaded: Bool = false, failing: String? = nil) throws -> (BackgroundServe, FakeCommandRunner, LaunchdState, URL) {
        let (home, hermes) = try TempFS.home()
        cleanup.append(home)
        let state = LaunchdState(loaded: loaded)
        let runner = FakeCommandRunner { _, args in
            let verb = args.first ?? ""
            if verb == failing { return CommandResult(status: 5, output: "Bootstrap failed: 5: Input/output error") }
            switch verb {
            case "print": return CommandResult(status: state.loaded ? 0 : 113, output: state.loaded ? state.printOutput : "")
            case "bootstrap": state.loaded = true; state.running = true
            case "kickstart": state.running = true
            case "bootout": state.loaded = false
            default: break
            }
            return CommandResult(status: 0, output: "")
        }
        let serve = BackgroundServe(home: home, uid: 501, environment: ["HERMES_BOT_APP_HERMES_BIN": hermes.path], runner: runner)
        return (serve, runner, state, hermes)
    }

    func testPlistContent() throws {
        let data = try BackgroundServe.plistData(hermes: "/opt/h/venv/bin/hermes", hermesHome: "/Users/u/.hermes",
                                                 logFile: "/Users/u/Library/Logs/HermesBotApp/background-serve.log", home: "/Users/u")
        let p = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(p["Label"] as? String, "io.github.risyadul.hermesbot.serve")
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/opt/h/venv/bin/hermes", "serve", "--host", "127.0.0.1", "--port", "0"])
        let env = try XCTUnwrap(p["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["HERMES_HOME"], "/Users/u/.hermes")
        XCTAssertNil(env["HERMES_PARENT_PID"], "the agent must outlive the app")
        XCTAssertNil(env["HERMES_DASHBOARD_SESSION_TOKEN"], "no secret in a world-readable plist")
        XCTAssertNil(env["HERMES_GATEWAY_LOCK_DIR"], "default lock dir, so discovery finds it")
        XCTAssertEqual(env["PATH"], "/opt/h/venv/bin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(p["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(p["ThrottleInterval"] as? Int, 30)
        XCTAssertEqual(p["StandardOutPath"] as? String, "/Users/u/Library/Logs/HermesBotApp/background-serve.log")
        XCTAssertEqual(p["StandardErrorPath"] as? String, p["StandardOutPath"] as? String)
        XCTAssertEqual(p["WorkingDirectory"] as? String, "/Users/u/.hermes")
        XCTAssertFalse((p["ProgramArguments"] as? [String] ?? []).contains("--isolated"))
    }

    func testPlistRefusesRelativePaths() {
        XCTAssertThrowsError(try BackgroundServe.plistData(hermes: "hermes", hermesHome: "/h", logFile: "/l", home: "/u"))
        XCTAssertThrowsError(try BackgroundServe.plistData(hermes: "/h", hermesHome: "rel", logFile: "/l", home: "/u"))
    }

    func testInstallWritesPlistAndBootstraps() async throws {
        let (serve, runner, _, hermes) = try make()
        let before = await serve.status()
        XCTAssertEqual(before, .notInstalled)
        try await serve.install()
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["print", "gui/501/io.github.risyadul.hermesbot.serve"],
            ["bootstrap", "gui/501", serve.plistURL.path],
        ])
        XCTAssertTrue(runner.calls.allSatisfy { $0.executable == "/bin/launchctl" })
        var st = stat()
        XCTAssertEqual(lstat(serve.plistURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o644)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG)
        let p = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: serve.plistURL), format: nil) as? [String: Any])
        XCTAssertEqual((p["ProgramArguments"] as? [String])?.first, TempFS.real(hermes))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serve.logFile.deletingLastPathComponent().path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: serve.plistURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["io.github.risyadul.hermesbot.serve.plist"], "no temp file left behind")
        let after = await serve.status()
        XCTAssertEqual(after, .loaded(executable: TempFS.real(hermes)))
    }

    func testReinstallBootsOutFirst() async throws {
        let (serve, runner, _, _) = try make(loaded: true)
        try await serve.install()
        XCTAssertEqual(runner.calls.map { $0.arguments.first ?? "" }, ["print", "bootout", "bootstrap"])
        XCTAssertEqual(runner.calls[1].arguments, ["bootout", "gui/501/io.github.risyadul.hermesbot.serve"])
    }

    func testBootstrapFailureIsReported() async throws {
        let (serve, _, _, _) = try make(failing: "bootstrap")
        do { try await serve.install(); XCTFail("expected failure") } catch {
            guard case .launchctl("bootstrap", 5, let out)? = error as? BackgroundServe.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(out.contains("Input/output error"))
        }
    }

    func testUntrustedHermesIsRefusedBeforeLaunchd() async throws {
        let (serve, runner, _, hermes) = try make()
        chmod(hermes.path, 0o777)  // world-writable: anyone could replace what launchd runs
        do { try await serve.install(); XCTFail("expected refusal") } catch {
            guard case .hermes(let m)? = error as? BackgroundServe.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("group- or world-writable"), m)
        }
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: serve.plistURL.path))
    }

    func testRelativeHermesOverrideIsRefused() async throws {
        let (home, _) = try TempFS.home()
        cleanup.append(home)
        let runner = FakeCommandRunner()
        let serve = BackgroundServe(home: home, uid: 501, environment: ["HERMES_BOT_APP_HERMES_BIN": "bin/hermes"], runner: runner)
        do { try await serve.install(); XCTFail("expected refusal") } catch {
            guard case .hermes(let m)? = error as? BackgroundServe.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("must be an absolute path"), m)
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUninstallBootsOutAndDeletes() async throws {
        let (serve, runner, state, _) = try make()
        try await serve.install()
        try await serve.uninstall()
        XCTAssertEqual(Array(runner.calls.map { $0.arguments.first ?? "" }.suffix(2)), ["print", "bootout"])
        XCTAssertFalse(state.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: serve.plistURL.path))
        let s = await serve.status()
        XCTAssertEqual(s, .notInstalled)
        try await serve.uninstall()  // idempotent
    }

    func testStatusVariants() async throws {
        let (serve, _, state, hermes) = try make()
        try await serve.install()
        state.loaded = false
        let notLoaded = await serve.status()
        XCTAssertEqual(notLoaded, .installedNotLoaded(executable: TempFS.real(hermes)))
        let recorded = TempFS.real(hermes)
        try FileManager.default.removeItem(at: hermes)
        let missing = await serve.status()
        XCTAssertEqual(missing, .binaryMissing(path: recorded))
        try Data("<plist><dict><key>Label</key><string>other</string></dict></plist>".utf8).write(to: serve.plistURL)
        guard case .unreadable = await serve.status() else { return XCTFail("a foreign plist must not read as ours") }
    }

    func testStatusRefusesSymlinkedPlist() async throws {
        let (serve, _, _, _) = try make()
        try FileManager.default.createDirectory(at: serve.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let real = serve.home.appendingPathComponent("elsewhere.plist")
        try BackgroundServe.plistData(hermes: "/bin/sh", hermesHome: "/h", logFile: "/l", home: "/u").write(to: real)
        try FileManager.default.createSymbolicLink(at: serve.plistURL, withDestinationURL: real)
        guard case .unreadable = await serve.status() else { return XCTFail("a symlinked plist must not be followed") }
    }
    // MARK: launchctl print parsing, start, log permissions, confirmed path

    func testParseJobReadsTopLevelStateAndPid() {
        XCTAssertEqual(BackgroundServe.parseJob("x = {\n\tstate = running\n\tpid = 77\n\tendpoints = {\n\t\tstate = waiting\n\t}\n}"),
                       .running(pid: 77))
        XCTAssertEqual(BackgroundServe.parseJob("x = {\n\tendpoints = {\n\t\tstate = running\n\t}\n\tstate = not running\n}"),
                       .loadedNotRunning, "a nested state never wins over the job's own")
        XCTAssertEqual(BackgroundServe.parseJob("x = {\n\tstate = spawn scheduled\n}"), .loadedNotRunning)
        XCTAssertEqual(BackgroundServe.parseJob("x = {\n\tpid = 12\n}"), .running(pid: 12), "a pid alone means it runs")
        XCTAssertEqual(BackgroundServe.parseJob(""), .loadedNotRunning, "exit 0 alone is not running")
        XCTAssertEqual(BackgroundServe.parseJob("\tstate = running\n"), .running(pid: nil))
    }

    func testLoadedButNotRunningIsItsOwnStatusAndStartKickstarts() async throws {
        let (serve, runner, state, hermes) = try make()
        try await serve.install()
        let pid = await serve.jobPID()
        XCTAssertEqual(pid, 4242)
        state.running = false
        let st = await serve.status()
        XCTAssertEqual(st, .loadedNotRunning(executable: TempFS.real(hermes)))
        let noPid = await serve.jobPID()
        XCTAssertNil(noPid)
        try await serve.start()
        XCTAssertEqual(runner.calls.last?.arguments, ["kickstart", "gui/501/io.github.risyadul.hermesbot.serve"])
        let after = await serve.status()
        XCTAssertEqual(after, .loaded(executable: TempFS.real(hermes)))
    }

    func testStartBootstrapsTheWrittenPlistWithoutANewLookup() async throws {
        let (serve, runner, state, hermes) = try make()
        try await serve.install()
        state.loaded = false
        try FileManager.default.removeItem(at: hermes)  // a new lookup would fail: start must not do one
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sh"), to: hermes)
        try await serve.start()
        XCTAssertEqual(runner.calls.last?.arguments, ["bootstrap", "gui/501", serve.plistURL.path])
        let n = runner.calls.count
        try await serve.start()  // running: nothing to do
        XCTAssertEqual(runner.calls.count, n + 1, "only the print")
    }

    func testStartRefusesWithoutAPlist() async throws {
        let (serve, runner, _, _) = try make()
        do { try await serve.start(); XCTFail("expected refusal") } catch {}
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInstallWithoutBootstrapOnlyWritesThePlist() async throws {
        let (serve, runner, state, hermes) = try make()
        try await serve.install(bootstrap: false)
        XCTAssertEqual(runner.calls.map { $0.arguments.first ?? "" }, ["print"])
        XCTAssertFalse(state.loaded)
        let st = await serve.status()
        XCTAssertEqual(st, .installedNotLoaded(executable: TempFS.real(hermes)))
    }

    func testInstallRefusesWhenTheConfirmedPathDiffers() async throws {
        let (serve, runner, _, hermes) = try make()
        do { try await serve.install(expecting: "/somewhere/else/hermes"); XCTFail("expected refusal") } catch {
            guard case .hermes(let m)? = error as? BackgroundServe.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("not the one you confirmed"), m)
        }
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: serve.plistURL.path))
        try await serve.install(expecting: TempFS.real(hermes))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serve.plistURL.path))
    }

    func testResolveHermesSaysWhenTheEnvironmentChoseIt() throws {
        let (serve, _, _, hermes) = try make()
        XCTAssertEqual(try serve.resolveHermes(), .init(path: TempFS.real(hermes), fromEnvironment: true))
        let (home, _) = try TempFS.home()
        cleanup.append(home)
        let searched = BackgroundServe(home: home, uid: 501, environment: ["PATH": hermes.deletingLastPathComponent().path],
                                       runner: FakeCommandRunner())
        XCTAssertEqual(try searched.resolveHermes(), .init(path: TempFS.real(hermes), fromEnvironment: false))
    }

    func testLogDirAndFileAreOwnerOnly() async throws {
        let (serve, _, _, _) = try make()
        let logDir = serve.logFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        chmod(logDir.path, 0o755)  // a pre-existing, too-open dir
        try await serve.install()
        var st = stat()
        XCTAssertEqual(stat(logDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(serve.logFile.path, &st), 0, "log pre-created")
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG)
    }
}
