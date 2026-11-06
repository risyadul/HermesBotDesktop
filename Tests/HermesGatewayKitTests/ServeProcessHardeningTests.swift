import Foundation
import XCTest
@testable import HermesGatewayKit

/// `hermes` lookup, binary trust checks, error text and serve.log permissions. Never launches hermes.
final class ServeProcessHardeningTests: XCTestCase {
    private typealias Config = ServeProcess.Configuration
    private let home = URL(fileURLWithPath: "/Users/tester")
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hba-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - lookup order

    func testCandidateOrderWithoutOverride() {
        let env = ["PATH": "/usr/bin:relative/bin:/opt/homebrew/bin:/custom/bin:"]
        XCTAssertEqual(Config.executableCandidates(environment: env, home: home), [
            "/Users/tester/.local/bin/hermes", "/usr/bin/hermes", "/opt/homebrew/bin/hermes",
            "/custom/bin/hermes", "/usr/local/bin/hermes",
        ])
    }

    func testOverrideIsTheOnlyCandidate() {
        let env = ["HERMES_BOT_APP_HERMES_BIN": "/somewhere/hermes", "PATH": "/usr/bin"]
        XCTAssertEqual(Config.executableCandidates(environment: env, home: home), ["/somewhere/hermes"])
        let r = Config.resolveExecutable(environment: env, home: home) { _ in false }
        XCTAssertNil(r.url)
        XCTAssertEqual(r.tried, ["/somewhere/hermes"])
    }

    func testEmptyOverrideIsIgnored() {
        let env = ["HERMES_BOT_APP_HERMES_BIN": ""]
        XCTAssertEqual(Config.executableCandidates(environment: env, home: home).first, "/Users/tester/.local/bin/hermes")
    }

    func testRelativeOverrideIsRejectedNotResolvedAgainstTheWorkingDir() {
        for o in ["hermes", "bin/hermes", "./hermes", "~hermes"] {
            let r = Config.resolveExecutable(environment: ["HERMES_BOT_APP_HERMES_BIN": o], home: home) { _ in true }
            XCTAssertNil(r.url, o)
            XCTAssertEqual(r.tried, [o])
            XCTAssertTrue(r.problem?.contains("must be an absolute path") == true, "\(o): \(r.problem ?? "nil")")
        }
    }

    func testTildeOverrideExpandsToHome() {
        let env = ["HERMES_BOT_APP_HERMES_BIN": "~/bin/hermes", "PATH": "/usr/bin"]
        XCTAssertEqual(Config.executableCandidates(environment: env, home: home), ["/Users/tester/bin/hermes"])
        XCTAssertNil(Config.resolveExecutable(environment: env, home: home) { _ in false }.problem)
    }

    func testResolvePicksFirstExecutable() {
        let env = ["PATH": "/a:/b"]
        let r = Config.resolveExecutable(environment: env, home: home) { $0 == "/b/hermes" || $0 == "/usr/local/bin/hermes" }
        XCTAssertEqual(r.url?.path, "/b/hermes")
        XCTAssertEqual(r.tried.count, 5)
    }

    func testResolveNoneFound() {
        let r = Config.resolveExecutable(environment: [:], home: home) { _ in false }
        XCTAssertNil(r.url)
        XCTAssertEqual(r.tried, ["/Users/tester/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"])
    }

    func testIsExecutableFile() throws {
        let f = tmp.appendingPathComponent("tool")
        FileManager.default.createFile(atPath: f.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertFalse(ServeProcess.isExecutableFile(f.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        XCTAssertTrue(ServeProcess.isExecutableFile(f.path))
        XCTAssertFalse(ServeProcess.isExecutableFile(tmp.path), "a directory is not an executable file")
        XCTAssertFalse(ServeProcess.isExecutableFile(tmp.appendingPathComponent("missing").path))
    }

    // MARK: - trust

    func testBinaryTrustProblem() {
        let me: uid_t = 501
        XCTAssertNil(ServeProcess.binaryTrustProblem(mode: 0o100755, owner: me, me: me))
        XCTAssertNil(ServeProcess.binaryTrustProblem(mode: 0o100755, owner: 0, me: me))
        XCTAssertNotNil(ServeProcess.binaryTrustProblem(mode: 0o100775, owner: me, me: me))
        XCTAssertNotNil(ServeProcess.binaryTrustProblem(mode: 0o100757, owner: me, me: me))
        XCTAssertEqual(ServeProcess.binaryTrustProblem(mode: 0o100755, owner: 777, me: me),
                       "it is owned by uid 777, neither you (uid 501) nor root")
    }

    func testDirectoryTrustProblem() {
        XCTAssertNil(ServeProcess.directoryTrustProblem(mode: 0o040755, path: "/d"))
        XCTAssertNil(ServeProcess.directoryTrustProblem(mode: 0o041777, path: "/tmp"), "sticky: others cannot replace our file")
        XCTAssertNil(ServeProcess.directoryTrustProblem(mode: 0o041775, path: "/d"))
        XCTAssertEqual(ServeProcess.directoryTrustProblem(mode: 0o040777, path: "/d"),
                       "its directory /d is group- or world-writable without the sticky bit (mode 777)")
        XCTAssertNotNil(ServeProcess.directoryTrustProblem(mode: 0o040775, path: "/d"))
    }

    // MARK: - start() failures before launch

    private func config(executable: URL) -> Config {
        var c = Config(hermesExecutable: executable, hermesHome: tmp.appendingPathComponent("home"),
                       lockDir: tmp.appendingPathComponent("locks"),
                       logFile: tmp.appendingPathComponent("logs/serve.log"))
        c.readyTimeout = 5
        return c
    }

    func testMissingBinaryFailsWithBinaryNotFoundAndPrivateLog() async throws {
        let missing = tmp.appendingPathComponent("no-such-hermes")
        let serve = ServeProcess(configuration: config(executable: missing))
        do {
            _ = try await serve.start()
            XCTFail("start() must fail")
        } catch let e as ServeProcess.ServeError {
            guard case .binaryNotFound(let tried, _) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(tried, [missing.path])
            XCTAssertTrue(e.description.contains("HERMES_BOT_APP_HERMES_BIN"))
            XCTAssertTrue(e.description.contains(missing.path))
        }
        serve.stop()
        let log = tmp.appendingPathComponent("logs/serve.log")
        let attrs = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: log.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("hermes executable not found"))
    }

    func testWorldWritableBinaryIsRefused() async throws {
        let exe = tmp.appendingPathComponent("hermes")
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: exe.path)
        let serve = ServeProcess(configuration: config(executable: exe))
        do {
            _ = try await serve.start()
            XCTFail("start() must fail")
        } catch let e as ServeProcess.ServeError {
            guard case .untrustedBinary(let path, _, _) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(path, exe.path)
            XCTAssertTrue(e.description.contains("group- or world-writable"), e.description)
        }
        serve.stop()
        XCTAssertFalse(serve.isRunning)
    }

    func testBinaryInWritableDirectoryIsRefused() async throws {
        let open = tmp.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)
        let real = open.appendingPathComponent("hermes")
        FileManager.default.createFile(atPath: real.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        // Named through a symlink in a private dir: the check applies to the directory of the real file.
        let link = tmp.appendingPathComponent("hermes-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for exe in [real, link] {
            let serve = ServeProcess(configuration: config(executable: exe))
            do {
                _ = try await serve.start()
                XCTFail("start() must fail for \(exe.path)")
            } catch let e as ServeProcess.ServeError {
                guard case .untrustedBinary(let path, let reason, _) = e else { return XCTFail("wrong error: \(e)") }
                XCTAssertEqual(path, exe.path)
                XCTAssertTrue(reason.contains("without the sticky bit"), reason)
            }
            serve.stop()
            XCTAssertFalse(serve.isRunning)
        }
    }

    func testDirectoryNamedExplicitlyIsNotAnExecutableFile() async throws {
        for search in [[], [tmp.path]] {  // given directly, or as HERMES_BOT_APP_HERMES_BIN
            var c = config(executable: tmp)
            c.executableSearch = search
            let serve = ServeProcess(configuration: c)
            do {
                _ = try await serve.start()
                XCTFail("start() must fail")
            } catch let e as ServeProcess.ServeError {
                guard case .invalidBinary(let path, let reason, _) = e else { return XCTFail("wrong error: \(e)") }
                XCTAssertEqual(path, tmp.path)
                XCTAssertEqual(reason, "it is not a regular executable file")
            }
            serve.stop()
        }
    }

    func testRelativeOverrideFailsStartWithClearError() async throws {
        let r = Config.resolveExecutable(environment: ["HERMES_BOT_APP_HERMES_BIN": "hermes"], home: home)
        var c = config(executable: tmp.appendingPathComponent("unused"))
        c.executableSearch = r.tried
        c.executableProblem = r.problem
        let serve = ServeProcess(configuration: c)
        do {
            _ = try await serve.start()
            XCTFail("start() must fail")
        } catch let e as ServeProcess.ServeError {
            guard case .invalidBinary(let path, let reason, _) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(path, "hermes")
            XCTAssertTrue(reason.contains("must be an absolute path"), reason)
            XCTAssertTrue(e.description.contains("HERMES_BOT_APP_HERMES_BIN"))
        }
        serve.stop()
    }

    func testStopWithoutStartIsSafe() {
        let serve = ServeProcess(configuration: config(executable: tmp.appendingPathComponent("x")))
        serve.stop()
        serve.stop()
    }

    // MARK: - error text

    func testEveryServeErrorNamesTheLog() {
        let log = "/Users/tester/Library/Logs/HermesBotApp/serve.log"
        let all: [ServeProcess.ServeError] = [
            .homeInsideDefaultRoot("/Users/tester/.hermes/x", log: log),
            .binaryNotFound(tried: ["/a/hermes", "/b/hermes"], log: log),
            .untrustedBinary(path: "/a/hermes", reason: "it is group- or world-writable (mode 777)", log: log),
            .invalidBinary(path: "hermes", reason: "HERMES_BOT_APP_HERMES_BIN (hermes) must be an absolute path", log: log),
            .launchFailed("NSCocoaErrorDomain 4: missing", log: log),
            .exitedBeforeReady(1, log: log),
            .readyTimeout(log: log),
        ]
        for e in all {
            XCTAssertTrue(e.description.contains(log), "\(e) does not name serve.log")
            XCTAssertTrue(Redaction.describe(e).contains(log))
        }
        XCTAssertTrue(all[1].description.contains("/a/hermes, /b/hermes"))
    }
}
