import Foundation
import XCTest
@testable import HermesGatewayKit

/// `ProcessCommandRunner` against `/bin/sh` one-liners only (nothing that changes the system).
final class ProcessCommandRunnerTests: XCTestCase {
    private let runner = ProcessCommandRunner()

    func testCollectsOutputAndStatus() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], environment: nil, timeout: 10)
        XCTAssertEqual(r.status, 3)
        XCTAssertTrue(r.output.contains("out") && r.output.contains("err"), r.output)
        XCTAssertFalse(r.timedOut)
    }

    func testGrandchildHoldingThePipeDoesNotBlockTheResult() async throws {
        // The background `sleep` inherits stdout and keeps the pipe open after the shell exits.
        let started = Date()
        let r = try await runner.run("/bin/sh", ["-c", "sleep 5 & echo hi"], environment: nil, timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("hi"), r.output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "answered within the EOF grace, not when the grandchild exits")
    }

    func testCancellationTerminatesTheProcess() async throws {
        let started = Date()
        let runner = ProcessCommandRunner()
        let task = Task { try await runner.run("/bin/sh", ["-c", "sleep 30"], environment: nil, timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelledBeforeLaunchStillStops() async throws {
        let runner = ProcessCommandRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run("/bin/sh", ["-c", "sleep 30"], environment: nil, timeout: 60)
        }
        do { _ = try await task.value; XCTFail("expected CancellationError") } catch is CancellationError {}
    }

    func testTimeoutMarksTheResult() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "sleep 30"], environment: nil, timeout: 0.3)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.succeeded)
    }

    func testOutputIsCappedToTheTail() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\000' a; echo END"],
                                     environment: nil, timeout: 10)
        XCTAssertEqual(r.output.utf8.count, ProcessCommandRunner.maxOutput)
        XCTAssertTrue(r.output.hasSuffix("END\n"))
    }

    func testRelativeAndMissingExecutablesThrow() async {
        do { _ = try await runner.run("sh", [], environment: nil, timeout: 1); XCTFail("expected throw") } catch {}
        do { _ = try await runner.run("/nonexistent/hba-x", [], environment: nil, timeout: 1); XCTFail("expected throw") } catch {
            XCTAssertTrue(error is ProcessCommandRunner.LaunchError, "\(error)")
        }
    }
}
