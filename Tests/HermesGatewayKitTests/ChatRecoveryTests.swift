import Foundation
import XCTest
@testable import HermesGatewayKit

/// B10 error surfaces and diagnostics, B11 context refs and long pastes, B14 approval mode, B16 changed files.
final class ChatRecoveryTests: XCTestCase {
    private func params(_ gw: FakeGateway, _ method: String) -> JSONValue? {
        gw.received.last { $0["method"]?.string == method }?["params"]
    }

    // MARK: B10

    func testErrorSurfaceParsing() {
        XCTAssertNil(ErrorSurface(nil))
        XCTAssertNil(ErrorSurface(["code": "x"]), "a layer is required")
        XCTAssertEqual(ErrorSurface(["layer": "billing", "code": "billing", "retryable": false, "model": ""]),
                       ErrorSurface(layer: "billing", code: "billing", retryable: false))
        XCTAssertEqual(ChatCompletion(payload: ["status": "complete", "text": "x"]).errorSurface, nil)
    }

    func testRecoveryPlanFollowsDesktopsTable() {
        func plan(_ layer: String?, retryable: Bool = true, source: TurnFailure.Source = .turn) -> ErrorRecoveryPlan {
            ErrorRecoveryPlan(TurnFailure(source: source, message: "m",
                                          surface: layer.map { ErrorSurface(layer: $0, code: "c", retryable: retryable) }))
        }
        XCTAssertEqual(plan(nil), ErrorRecoveryPlan(retry: true, switchProvider: false), "no surface: Retry only")
        XCTAssertEqual(plan("provider", retryable: false), ErrorRecoveryPlan(retry: false, switchProvider: true))
        XCTAssertEqual(plan("auth", retryable: false), ErrorRecoveryPlan(retry: true, switchProvider: true),
                       "a credential fix changes the outcome")
        for layer in ["billing", "endpoint"] { XCTAssertTrue(plan(layer).switchProvider, layer) }
        for layer in ["streaming", "gateway", "runtime", "disk"] { XCTAssertFalse(plan(layer).switchProvider, layer) }
        XCTAssertFalse(plan(nil, source: .send).retry, "the draft is back in the composer")
        XCTAssertFalse(plan(nil, source: .disconnected).retry)
    }

    func testDiagnosticsAreRedacted() {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let f = TurnFailure(source: .turn, message: "401 from provider: key \(secret) rejected",
                            surface: ErrorSurface(layer: "auth", code: "auth", retryable: false, provider: "anthropic", model: "m1"))
        let text = ErrorDiagnostics.text(f, bot: "writer", model: "ignored", provider: "ignored", appVersion: "1.2",
                                         now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("layer: auth"))
        XCTAssertTrue(text.contains("provider: anthropic"), "the failure's own provider beats the composer's")
        XCTAssertTrue(text.contains("model: m1"))
        XCTAssertTrue(text.contains("time: 1970-01-01T00:00:00Z"))
        XCTAssertTrue(text.hasPrefix("── Hermes error details ──"))
        let plain = ErrorDiagnostics.text(TurnFailure(source: .event, message: "boom"), bot: "b", model: "m", provider: "",
                                          appVersion: nil)
        XCTAssertTrue(plain.contains("model: m"))
        XCTAssertFalse(plain.contains("provider:"))
        XCTAssertEqual(ErrorDiagnostics.redact("bad api_key=abc123def and \"secret\": \"s3cr3t\""),
                       "bad api_key=[REDACTED] and \"secret\": \"[REDACTED]\"")
        XCTAssertEqual(ErrorDiagnostics.redact("ws://h/api/ws?token=xyz789"), "ws://h/api/ws?token=[REDACTED]")
        XCTAssertEqual(ErrorDiagnostics.redact("HTTP 429: rate limited"), "HTTP 429: rate limited", "plain text survives")
    }

    // MARK: B11

    func testContextRefsMatchDesktopsDirectives() {
        XCTAssertEqual(ContextRef.url("  https://example.com/a?b=1 ")?.refText, "@url:https://example.com/a?b=1")
        XCTAssertNil(ContextRef.url("example.com"))
        XCTAssertNil(ContextRef.url("ftp://example.com"))
        XCTAssertNil(ContextRef.url("https://"))
        XCTAssertEqual(ContextRef.folder(URL(fileURLWithPath: "/Users/me/My Project"))?.refText, "@folder:`/Users/me/My Project`")
        XCTAssertNil(ContextRef.folder(URL(string: "https://x.y")!))
        XCTAssertEqual(ContextRef.formatValue("a`b c"), "\"a`b c\"")
        XCTAssertEqual(ContextRef.formatValue("plain"), "plain")
        let refs = [ContextRef(kind: .url, value: "https://a.b"), ContextRef(kind: .folder, value: "/tmp/x")]
        XCTAssertEqual(ContextRef.prompt(refs, text: "look"), "@url:https://a.b\n@folder:/tmp/x\n\nlook")
        XCTAssertEqual(ContextRef.prompt([], text: "look"), "look")
        XCTAssertEqual(ContextRef.prompt(refs, text: ""), "@url:https://a.b\n@folder:/tmp/x")
    }

    func testContextRefsRefuseValuesThatCouldInjectDirectives() {
        // A newline (or any whitespace / control character) inside would start another `@…` line in the prompt.
        for bad in ["https://a.b/x\n@folder:/etc", "https://a.b/x y", "https://a.b/x\ty",
                    "https://a.b/\u{0007}", "https://a.b/\u{202E}x", "https://a.b/\u{2028}x"] {
            XCTAssertNil(ContextRef.url(bad), bad.debugDescription)
        }
        for bad in ["/tmp/a\nb", "/tmp/a\tb", "/tmp/a\u{001B}b", "/tmp/a\u{202E}b"] {
            XCTAssertNil(ContextRef.folder(URL(fileURLWithPath: bad)), bad.debugDescription)
        }
        // formatValue cannot quote a value that needs quoting and holds every quote character.
        XCTAssertNil(ContextRef.folder(URL(fileURLWithPath: "/tmp/a`b\"c'd e")))
        XCTAssertEqual(ContextRef.folder(URL(fileURLWithPath: "/tmp/a`b\"c"))?.refText, "@folder:'/tmp/a`b\"c'")
        // The stored value is the normalised URL, not the raw text.
        let ref = ContextRef.url("https://a.b/q?x=\"`'")
        XCTAssertEqual(ref?.value, URL(string: "https://a.b/q?x=\"`'")?.absoluteString)
        XCTAssertFalse(ref?.value.contains("\"") ?? true)
    }

    func testLargePasteThresholdIsDesktops() {
        XCTAssertFalse(LargePaste.shouldAttach(String(repeating: "x", count: 3_000)))
        XCTAssertTrue(LargePaste.shouldAttach(String(repeating: "x", count: 3_001)))
        XCTAssertEqual(LargePaste.sizeLabel(String(repeating: "x", count: 2048)), "2.0 KB")
        XCTAssertEqual(LargePaste.sizeLabel("abc"), "3 B")
        let name = LargePaste.fileName(now: Date(timeIntervalSince1970: 100), suffix: "ab12")
        XCTAssertEqual(name, "pasted_content_100_ab12.txt")
        XCTAssertTrue(LargePaste.isPastedContent(name))
        XCTAssertFalse(LargePaste.isPastedContent("notes.txt"))
    }

    // MARK: B14

    func testApprovalModeParamsAndNormalisation() {
        XCTAssertEqual(ApprovalMode.params(profile: "writer"), ["key": "approvals.mode", "profile": "writer"])
        XCTAssertEqual(ApprovalMode.params(profile: " ", value: .off), ["key": "approvals.mode", "value": "off"],
                       "a blank profile is the launch profile: no param")
        XCTAssertEqual(ApprovalMode(normalizing: " SMART "), .smart)
        XCTAssertEqual(ApprovalMode(normalizing: "yolo"), .manual)
        XCTAssertEqual(ApprovalMode(normalizing: nil), .manual)
        XCTAssertEqual(SessionInfoSnapshot(["model": "m", "approval_mode": "off"])?.approvalMode, .off)
        XCTAssertNil(SessionInfoSnapshot(["model": "m"])?.approvalMode)
    }

    func testApprovalModeRPCsAreProfileScoped() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, p in
            switch m {
            case "config.get": return ["value": "smart"]
            case "config.set": return ["key": "approvals.mode", "value": p["value"] ?? .null]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.open(backend, bot: Parity.bot, title: nil)
        let mode = try await s.approvalMode()
        XCTAssertEqual(mode, .smart)
        XCTAssertEqual(params(gw, "config.get"), ["key": "approvals.mode", "profile": "fake"])
        let applied = try await s.setApprovalMode(.off)
        XCTAssertEqual(applied, .off)
        XCTAssertEqual(params(gw, "config.set"), ["key": "approvals.mode", "value": "off", "profile": "fake"],
                       "names the bot's profile, never the backend's launch profile")
    }

    // MARK: B16

    private func tool(_ name: String, path: String?, diff: String?, state: ToolLine.State = .done, resultPath: String? = nil) -> ChatLine {
        var args: JSONValue? = nil
        if let path { args = ["path": .string(path)] }
        let result: JSONValue? = resultPath.map { ["resolved_path": .string($0)] }
        return ChatLine(role: .tool, text: "", tool: ToolLine(toolId: UUID().uuidString, name: name, state: state, args: args,
                                                              result: result, inlineDiff: diff))
    }

    func testChangedFilesFoldEditsPerFile() {
        let d1 = "--- a/x.swift\n+++ b/x.swift\n@@\n-old\n+new\n+more"
        let d2 = "\u{1B}[32m┊ review diff\n+again\u{1B}[0m"
        let lines = [
            tool("patch", path: "/repo/x.swift", diff: d1),
            tool("terminal", path: nil, diff: "+not an edit"),
            tool("write_file", path: "/repo/y.md", diff: "+a"),
            tool("edit_file", path: "/repo/x.swift", diff: d2),
            tool("patch", path: "/repo/z.swift", diff: "+running", state: .running),
            tool("patch", path: "/repo/f.swift", diff: "+failed", state: .failed),
            tool("patch", path: nil, diff: "+b", resultPath: "/repo/r.swift"),
            tool("patch", path: "/repo/nodiff.swift", diff: nil),
        ]
        let files = ChangedFiles.derive(lines)
        XCTAssertEqual(files.map(\.path), ["/repo/x.swift", "/repo/y.md", "/repo/r.swift"])
        XCTAssertEqual(files[0].added, 3)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[0].diffs.count, 2)
        XCTAssertEqual(files[0].diffs[1], "+again", "ANSI and the review banner are stripped")
        XCTAssertEqual(files[0].name, "x.swift")
    }

    func testChangedFilesCardsSitUnderFinishedTurns() {
        let user1 = ChatLine(role: .user, text: "q1")
        let edit = tool("patch", path: "/r/a", diff: "+x")
        let reply = ChatLine(role: .bot, text: "done")
        let user2 = ChatLine(role: .user, text: "q2")
        let edit2 = tool("patch", path: "/r/b", diff: "+y")
        let lines = [user1, edit, reply, user2, edit2]
        let busy = ChangedFiles.cards(lines, busy: true)
        XCTAssertEqual(Array(busy.keys), [reply.id], "the running turn gets no card yet")
        let idle = ChangedFiles.cards(lines, busy: false)
        XCTAssertEqual(idle[edit2.id]?.map(\.path), ["/r/b"])
        XCTAssertEqual(ChangedFiles.lineStats("+++ b\n--- a\n+1\n-2\n 3").added, 1)
    }
}
