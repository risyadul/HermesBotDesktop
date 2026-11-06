import Foundation
import XCTest
@testable import HermesGatewayKit

/// `BotActivityProfileSwitch` with a temp home, a fake trusted hermes and `FakeCommandRunner`: nothing runs.
final class BotActivityProfileSwitchTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func make(_ runner: FakeCommandRunner) throws -> (BotActivityProfileSwitch, URL, URL) {
        let (home, hermes) = try TempFS.home()
        cleanup.append(home)
        return (BotActivityProfileSwitch(home: home, environment: ["HERMES_BOT_APP_HERMES_BIN": hermes.path, "HERMES_HOME": "/elsewhere"],
                                         runner: runner), home, hermes)
    }

    func testRunsTheTrustedHermesPerProfileWithoutAShell() async throws {
        let runner = FakeCommandRunner()
        let (sw, home, hermes) = try make(runner)
        try await sw.setEnabled(false, bot: "alice")
        try await sw.setEnabled(true, bot: "default")
        XCTAssertEqual(runner.calls.map(\.arguments), [["-p", "alice", "plugins", "disable", "bot-activity"],
                                                       ["-p", "default", "plugins", "enable", "bot-activity"]])
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, TempFS.real(hermes))
        XCTAssertEqual(call.environment?["HERMES_HOME"], home.appendingPathComponent(".hermes").path, "the app's Hermes root, not inherited")
        XCTAssertNil(call.environment?["HERMES_BOT_APP_HERMES_BIN"], "clean environment")
        XCTAssertGreaterThanOrEqual(BotActivityProfileSwitch.timeout, 60)
    }

    func testRefusesNamesThatAreNotProfiles() async throws {
        let runner = FakeCommandRunner()
        let (sw, _, _) = try make(runner)
        for bad in ["--help", "-p", "Alice", "a b", "../x", "", String(repeating: "a", count: 65)] {
            do { try await sw.setEnabled(false, bot: bad); XCTFail("accepted \(bad)") } catch {
                XCTAssertTrue(error is BotActivityProfileSwitch.Failure)
            }
        }
        XCTAssertTrue(runner.calls.isEmpty, "a bad name never reaches the command line")
        XCTAssertTrue(BotActivityProfileSwitch.isProfileName("my-bot_2"))
    }

    func testFailureIsTheScrubbedLastLineAndTimeoutSaysSo() async throws {
        let failing = FakeCommandRunner { _, _ in
            CommandResult(status: 1, output: "Loading…\nError: Authorization: Bearer abcdefgh12345 rejected\n")
        }
        let (sw, _, _) = try make(failing)
        do { try await sw.setEnabled(false, bot: "bob"); XCTFail("expected failure") } catch {
            let text = Redaction.describe(error)
            XCTAssertTrue(text.contains("rejected"), text)
            XCTAssertFalse(text.contains("abcdefgh12345"), text)
            XCTAssertFalse(text.contains("Loading"), "only the last line: \(text)")
        }
        let slow = FakeCommandRunner { _, _ in CommandResult(status: 15, output: "", timedOut: true) }
        let (sw2, _, _) = try make(slow)
        do { try await sw2.setEnabled(true, bot: "bob"); XCTFail("expected timeout") } catch {
            XCTAssertEqual(error as? BotActivityProfileSwitch.Failure, .init(description: "timed out"))
        }
    }

    func testUntrustedOrMissingHermesNeverRuns() async throws {
        let runner = FakeCommandRunner()
        let (home, _) = try TempFS.home()
        cleanup.append(home)
        let sw = BotActivityProfileSwitch(home: home, environment: ["HERMES_BOT_APP_HERMES_BIN": home.appendingPathComponent("nope").path],
                                          runner: runner)
        do { try await sw.setEnabled(false, bot: "bob"); XCTFail("expected failure") } catch {
            XCTAssertTrue(error is BotActivityProfileSwitch.Failure)
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
