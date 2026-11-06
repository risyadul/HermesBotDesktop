import Foundation
import XCTest
@testable import HermesGatewayKit

/// E2: `setup.runtime_check` → ready / no model / unknown. Fake calls only; no backend.
final class SetupCheckTests: XCTestCase {
    func testInterpretsTheReply() {
        XCTAssertEqual(SetupCheck.interpret(["ok": true, "provider": "openrouter", "model": "m"]), .ready)
        XCTAssertEqual(SetupCheck.interpret(["ok": false, "provider": "openrouter", "model": "claude",
                                             "error": "No usable credentials found for openrouter."]),
                       .noModel(provider: "openrouter", model: "claude", reason: "No usable credentials found for openrouter."))
        XCTAssertEqual(SetupCheck.interpret(["ok": false]), .noModel(provider: nil, model: nil, reason: nil))
        XCTAssertEqual(SetupCheck.interpret(["ok": false, "provider": "  ", "model": .null, "error": 5]),
                       .noModel(provider: nil, model: nil, reason: nil))
        XCTAssertEqual(SetupCheck.interpret([:]), .unknown, "no `ok`: not a clear answer")
        XCTAssertEqual(SetupCheck.interpret(["ok": "false"]), .unknown)
        XCTAssertEqual(SetupCheck.interpret(.null), .unknown)
    }

    func testBackendTextIsCappedAndMadeVisible() {
        let long = String(repeating: "e", count: 1_000)
        guard case .noModel(_, _, let reason?) = SetupCheck.interpret(["ok": false, "error": .string(long)]) else {
            return XCTFail("expected a reason")
        }
        XCTAssertEqual(reason.count, SetupCheck.maxFieldChars + 1)
        guard case .noModel(let provider?, _, _) = SetupCheck.interpret(["ok": false, "provider": "a\u{202E}b"]) else {
            return XCTFail("expected a provider")
        }
        XCTAssertEqual(provider, "a⟨U+202E⟩b")
    }

    func testRunAsksTheReadOnlyMethodWithoutParams() async {
        let calls = CallLog()
        let result = await SetupCheck.run(call: { method, params in
            await calls.add(method, params)
            return ["ok": true]
        }, sleep: { _ in })
        XCTAssertEqual(result, .ready)
        let log = await calls.entries
        XCTAssertEqual(log.map(\.0), ["setup.runtime_check"])
        XCTAssertEqual(log.first?.1, [:], "the launch profile, no provider override")
    }

    func testRetriesWhileTheProbeIsInProgress() async {
        let calls = CallLog()
        let result = await SetupCheck.run(call: { method, params in
            await calls.add(method, params)
            if await calls.entries.count < 3 {
                throw GatewayClient.RPCError(code: SetupCheck.inProgressCode, message: "still in progress", data: nil)
            }
            return ["ok": false, "error": "No Hermes provider is configured."]
        }, sleep: { _ in })
        XCTAssertEqual(result, .noModel(provider: nil, model: nil, reason: "No Hermes provider is configured."))
        let count = await calls.entries.count
        XCTAssertEqual(count, 3)
    }

    func testGivesUpAfterTheLastAttempt() async {
        let calls = CallLog()
        let result = await SetupCheck.run(call: { method, params in
            await calls.add(method, params)
            throw GatewayClient.RPCError(code: SetupCheck.inProgressCode, message: "still in progress", data: nil)
        }, sleep: { _ in })
        XCTAssertEqual(result, .unknown)
        let count = await calls.entries.count
        XCTAssertEqual(count, SetupCheck.attempts)
    }

    func testOtherFailuresAreUnknownWithoutRetry() async {
        for which in 0..<2 {  // an older Hermes without the method; a timeout
            let calls = CallLog()
            let result = await SetupCheck.run(call: { method, params in
                await calls.add(method, params)
                if which == 0 { throw GatewayClient.RPCError(code: -32601, message: "method not found", data: nil) }
                throw GatewayClient.ClientError.timeout("setup.runtime_check")
            }, sleep: { _ in })
            XCTAssertEqual(result, .unknown)
            let count = await calls.entries.count
            XCTAssertEqual(count, 1)
        }
    }

    func testCancelledWaitIsUnknown() async {
        let result = await SetupCheck.run(call: { _, _ in
            throw GatewayClient.RPCError(code: SetupCheck.inProgressCode, message: "still in progress", data: nil)
        }, sleep: { _ in throw CancellationError() })
        XCTAssertEqual(result, .unknown)
    }
}
