import Foundation
import XCTest
@testable import HermesGatewayKit

/// A13 / A14 wire shapes (`SkillsHub`, `MCPServers`) and the OAuth flow against the scripted fake gateway and a
/// fake browser: no skill or server is installed and no sign-in page is opened.
final class SkillsMcpAPITests: XCTestCase {
    typealias FakeGateway = BotProfileManagementTests.FakeGateway

    // MARK: skills.manage

    func testSkillsHubParamsAndReplies() {
        XCTAssertEqual(SkillsHub.searchParams(" pdf "), ["action": "search", "query": "pdf"])
        XCTAssertEqual(SkillsHub.installParams("owner/pdf-tools", profile: "alpha"),
                       ["action": "install", "query": "owner/pdf-tools", "profile": "alpha"])
        XCTAssertEqual(SkillsHub.results(["results": [["name": "pdf", "description": "PDFs"], ["description": "nameless"]]]),
                       [.init(name: "pdf", description: "PDFs")])
        XCTAssertTrue(SkillsHub.isInstallable("owner/pdf-tools.v2"))
        XCTAssertFalse(SkillsHub.isInstallable("-rf"))
        XCTAssertFalse(SkillsHub.isInstallable("a b"))
        XCTAssertFalse(SkillsHub.isInstallable("a;b"))
        XCTAssertTrue(SkillsHub.installed(["installed": true, "name": "pdf"]))
        XCTAssertFalse(SkillsHub.installed(["name": "pdf"]))
    }

    // MARK: mcp.servers.*

    func testListAddKeyAndTestCarryTheProfile() async throws {
        let gw = FakeGateway()
        gw.on("mcp.servers.list") { _ in ["servers": [
            ["name": "jira", "transport": "http", "url": "https://j/mcp", "args": [], "env": [], "auth": "oauth",
             "oauth_tokens_present": false, "enabled": true],
            ["name": "fs", "transport": "stdio", "command": "npx", "args": ["-y", "fs"], "env": ["FS_TOKEN"], "auth": .null, "enabled": false],
            ["transport": "stdio"],
        ]] }
        gw.on("mcp.servers.add") { _ in ["ok": true, "name": "web"] }
        gw.on("mcp.servers.set_api_key") { _ in ["ok": true, "name": "jira", "env_var": "MCP_JIRA_API_KEY"] }
        gw.on("mcp.servers.test") { _ in ["ok": true, "tools": [["name": "a"], ["name": "b"]], "oauth_needed": false] }
        let api = MCPServers(call: gw.call)

        let servers = try await api.list(profile: "alpha")
        XCTAssertEqual(servers.map(\.name), ["jira", "fs"])
        XCTAssertTrue(servers[0].canSignIn)
        XCTAssertFalse(servers[1].canSignIn)
        XCTAssertEqual(servers[1].env, ["FS_TOKEN"])
        XCTAssertFalse(servers[1].enabled)
        XCTAssertFalse(MCPServers.Server(name: "h", transport: "http", url: "https://h", auth: "header").canSignIn)

        try await api.add(profile: "alpha", .init(name: "web", transport: .url("https://example.com/mcp")))
        try await api.add(profile: "alpha", .init(name: "fs2", transport: .command("npx", args: ["-y", "x"], env: [:])))
        let env = try await api.setAPIKey(profile: "alpha", name: "jira", envVar: nil, value: "sk-123")
        XCTAssertEqual(env, "MCP_JIRA_API_KEY")
        let tested = try await api.test(profile: "alpha", name: "jira")
        XCTAssertEqual(tested, .init(ok: true, tools: 2))

        XCTAssertEqual(gw.params("mcp.servers.list"), [["profile": "alpha"]])
        XCTAssertEqual(gw.params("mcp.servers.add"), [
            ["name": "web", "config": ["url": "https://example.com/mcp"], "profile": "alpha"],
            ["name": "fs2", "config": ["command": "npx", "args": ["-y", "x"]], "profile": "alpha"],
        ])
        XCTAssertEqual(gw.params("mcp.servers.set_api_key"), [["profile": "alpha", "name": "jira", "value": "sk-123"]])
        XCTAssertEqual(try MCPServers.apiKeyParams(profile: "a", name: "b", envVar: " TOKEN ", value: "v"),
                       ["profile": "a", "name": "b", "value": "v", "env_var": "TOKEN"])
        XCTAssertEqual(gw.params("mcp.servers.test"), [["profile": "alpha", "name": "jira"]])
    }

    func testSkillInstallNamesRefuseTraversalAndNestedPaths() {
        XCTAssertTrue(SkillsHub.isInstallable("pdf"))
        XCTAssertTrue(SkillsHub.isInstallable("owner/name..v2"))
        for bad in ["..", "../x", "owner/..", "owner/../x", "a/b/c", "owner/", "/abs", "owner/.hidden", "a//b"] {
            XCTAssertFalse(SkillsHub.isInstallable(bad), bad)
        }
    }

    func testAPIKeyAndEnvNamesCannotInjectEnvLines() async throws {
        for bad in ["sk\nEVIL=1", "sk\rEVIL=1", "sk\r\n", "a\u{0}b"] {
            XCTAssertThrowsError(try MCPServers.apiKeyParams(profile: "a", name: "b", envVar: nil, value: bad), bad.debugDescription)
        }
        for bad in ["1BAD", "A-B", "A B", "A\nB", "A=B", String(repeating: "A", count: 129)] {
            XCTAssertThrowsError(try MCPServers.apiKeyParams(profile: "a", name: "b", envVar: bad, value: "v"), bad.debugDescription)
        }
        XCTAssertNoThrow(try MCPServers.apiKeyParams(profile: "a", name: "b", envVar: "_" + String(repeating: "A", count: 127), value: "v"))
        XCTAssertNoThrow(try MCPServers.apiKeyParams(profile: "a", name: "b", envVar: "  ", value: "v"), "blank uses the default name")
        XCTAssertThrowsError(try MCPServers.environment(String(repeating: "A", count: 129) + "=x"))
        // Nothing reaches the gateway when the key is refused.
        let gw = FakeGateway()
        gw.on("mcp.servers.set_api_key") { _ in ["ok": true, "env_var": "X"] }
        do {
            _ = try await MCPServers(call: gw.call).setAPIKey(profile: "a", name: "b", envVar: nil, value: "x\nY=1")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(gw.params("mcp.servers.set_api_key"), [])
    }

    func testSecretsNeverReachTheWireTap() {
        for method in ["mcp.servers.set_api_key", "mcp.servers.add", "profiles.set_asset"] {
            XCTAssertTrue(GatewayClient.redactedParamMethods.contains(method), method)
        }
    }

    func testAddFormValidation() throws {
        XCTAssertEqual(try MCPServers.newServer(name: " web ", url: " https://x.io/mcp ", command: "", arguments: "", environment: ""),
                       .init(name: "web", transport: .url("https://x.io/mcp")))
        XCTAssertEqual(try MCPServers.newServer(name: "fs", url: nil, command: "npx", arguments: "-y 'a b' \"c d\" e",
                                                environment: "A=1\n\nB_2=x=y\n"),
                       .init(name: "fs", transport: .command("npx", args: ["-y", "a b", "c d", "e"], env: ["A": "1", "B_2": "x=y"])))
        XCTAssertEqual(try MCPServers.arguments("a \"\" b"), ["a", "", "b"])
        XCTAssertThrowsError(try MCPServers.arguments("a \"b"))
        XCTAssertThrowsError(try MCPServers.environment("1BAD=x"))
        XCTAssertThrowsError(try MCPServers.environment("NOEQUALS"))
        XCTAssertThrowsError(try MCPServers.newServer(name: "", url: nil, command: "x", arguments: "", environment: ""))
        XCTAssertThrowsError(try MCPServers.newServer(name: "a/b", url: nil, command: "x", arguments: "", environment: ""))
        XCTAssertThrowsError(try MCPServers.newServer(name: "w", url: "javascript:alert(1)", command: "", arguments: "", environment: ""))
        XCTAssertThrowsError(try MCPServers.newServer(name: "w", url: "https://", command: "", arguments: "", environment: ""))
        XCTAssertThrowsError(try MCPServers.newServer(name: "w", url: nil, command: "  ", arguments: "", environment: ""))
    }

    func testTestResultUnwrapsAndOlderGatewaysAreDetected() {
        XCTAssertEqual(MCPServers.TestResult(["result": ["ok": false, "error": "boom", "oauth_needed": true]]),
                       .init(ok: false, error: "boom", oauthNeeded: true))
        XCTAssertEqual(MCPServers.TestResult(["ok": false]), .init(ok: false))
        XCTAssertTrue(MCPServers.isUnsupported(GatewayClient.RPCError(code: -32601, message: "x", data: nil)))
        XCTAssertTrue(MCPServers.isUnsupported(GatewayClient.RPCError(code: 4000, message: "Unknown method: mcp.servers.list", data: nil)))
        XCTAssertFalse(MCPServers.isUnsupported(GatewayClient.RPCError(code: 5024, message: "boom", data: nil)))
    }

    // MARK: OAuth

    static let authURL = "https://auth.example.com/authorize?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fcallback&state=s"

    final class Browser: @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [URL] = []
        var answer = true
        var opened: [URL] { lock.withLock { _opened } }
        func open(_ url: URL) -> Bool { lock.withLock { _opened.append(url) }; return answer }
    }

    func testAuthURLMustComeBackToTheBackendsLoopback() throws {
        XCTAssertNoThrow(try MCPServers.checkAuthURL(Self.authURL))
        for local in ["http://127.0.0.1:9000/authorize", "http://localhost:9000/authorize", "http://[::1]:9000/authorize"] {
            XCTAssertNoThrow(try MCPServers.checkAuthURL(local + "?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback"), local)
        }
        for bad in [
            "https://a/x?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback",
            "https://a/x?redirect_uri=https%3A%2F%2F127.0.0.1%3A1%2Fcallback",
            "https://a/x?redirect_uri=http%3A%2F%2F127.0.0.1%2Fcallback",
            "https://a/x?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fother",
            "https://a/x?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback%3Fq%3D1",
            "https://a/x?redirect_uri=http%3A%2F%2Fevil.com%3A1%2Fcallback",
            "https://a/x",
            "file:///etc/passwd?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback",
            "http://auth.example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback",
            "http://127.evil.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback",
        ] {
            XCTAssertThrowsError(try MCPServers.checkAuthURL(bad), bad)
        }
    }

    func testSignInOpensTheBrowserOnceAndPollsUntilApproved() async throws {
        let gw = FakeGateway()
        gw.on("mcp.servers.oauth.start") { _ in ["ok": true, "session_id": "sid", "auth_url": .string(Self.authURL), "flow": "pkce"] }
        gw.on("mcp.servers.oauth.poll") { _ in ["ok": true, "status": "pending"] }
        gw.on("mcp.servers.oauth.poll") { _ in throw GatewayClient.ClientError.timeout("poll") }
        gw.on("mcp.servers.oauth.poll") { _ in ["ok": true, "status": "approved", "tools": [["name": "a"]]] }
        let browser = Browser()
        let tools = try await MCPServers(call: gw.call).signIn(profile: "alpha", name: "jira", open: { browser.open($0) }, sleep: { _ in })
        XCTAssertEqual(tools, 1)
        XCTAssertEqual(browser.opened.map(\.absoluteString), [Self.authURL])
        XCTAssertEqual(gw.params("mcp.servers.oauth.start"), [["profile": "alpha", "name": "jira"]])
        XCTAssertEqual(gw.params("mcp.servers.oauth.poll").count, 3, "one poll failure is retried")
        XCTAssertEqual(gw.params("mcp.servers.oauth.poll").first, ["profile": "alpha", "name": "jira", "session_id": "sid"])
        XCTAssertFalse(gw.methods.contains("mcp.servers.oauth.cancel"), "an approved flow is not cancelled")
    }

    func testSignInFailuresCancelTheFlow() async throws {
        func gateway(_ polls: [JSONValue], start: JSONValue? = nil) -> FakeGateway {
            let gw = FakeGateway()
            let s = start ?? ["ok": true, "session_id": "sid", "auth_url": .string(Self.authURL)]
            gw.on("mcp.servers.oauth.start") { _ in s }
            for p in polls { gw.on("mcp.servers.oauth.poll") { _ in p } }
            gw.on("mcp.servers.oauth.cancel") { _ in ["ok": true] }
            return gw
        }
        let browser = Browser()

        let denied = gateway([["ok": true, "status": "error", "error_message": "access_denied"]])
        do {
            try await MCPServers(call: denied.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in })
            XCTFail("no error")
        } catch { XCTAssertEqual(Redaction.describe(error), "access_denied") }
        XCTAssertEqual(denied.params("mcp.servers.oauth.cancel"), [["profile": "a", "name": "j", "session_id": "sid"]])

        browser.answer = false
        let noBrowser = gateway([])
        do {
            try await MCPServers(call: noBrowser.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in })
            XCTFail("no error")
        } catch { XCTAssertEqual(Redaction.describe(error), "Could not open the sign-in page in your browser.") }
        XCTAssertEqual(noBrowser.params("mcp.servers.oauth.cancel").count, 1)
        browser.answer = true

        let foreign = gateway([], start: ["ok": true, "session_id": "sid",
                                          "auth_url": "https://a/x?redirect_uri=http%3A%2F%2Fevil.com%3A1%2Fcallback"])
        let before = browser.opened.count
        do {
            try await MCPServers(call: foreign.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in })
            XCTFail("no error")
        } catch { XCTAssertEqual(Redaction.describe(error), "The OAuth server did not provide a local loopback callback URL.") }
        XCTAssertEqual(browser.opened.count, before, "a foreign callback is never opened")
        XCTAssertEqual(foreign.params("mcp.servers.oauth.cancel").count, 1)

        let refused = FakeGateway()
        refused.on("mcp.servers.oauth.start") { _ in ["ok": false, "error_message": "stdio servers authenticate via env keys"] }
        do {
            try await MCPServers(call: refused.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in })
            XCTFail("no error")
        } catch { XCTAssertEqual(Redaction.describe(error), "stdio servers authenticate via env keys") }
        XCTAssertFalse(refused.methods.contains("mcp.servers.oauth.cancel"), "no session to cancel")

        let flaky = FakeGateway()
        flaky.on("mcp.servers.oauth.start") { _ in ["ok": true, "session_id": "sid", "auth_url": .string(Self.authURL)] }
        flaky.on("mcp.servers.oauth.poll") { _ in throw GatewayClient.ClientError.timeout("poll") }
        flaky.on("mcp.servers.oauth.cancel") { _ in ["ok": true] }
        do {
            try await MCPServers(call: flaky.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in })
            XCTFail("no error")
        } catch {}
        XCTAssertEqual(flaky.params("mcp.servers.oauth.poll").count, MCPServers.maxPollFailures)
    }

    func testSignInTimesOutAndCanBeCancelled() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var t = Date(timeIntervalSince1970: 0)
            var now: Date { lock.withLock { t } }
            func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        }
        let clock = Clock()
        let gw = FakeGateway()
        gw.on("mcp.servers.oauth.start") { _ in ["ok": true, "session_id": "sid", "auth_url": .string(Self.authURL)] }
        gw.on("mcp.servers.oauth.poll") { _ in ["ok": true, "status": "pending"] }
        gw.on("mcp.servers.oauth.cancel") { _ in ["ok": true] }
        let browser = Browser()
        do {
            try await MCPServers(call: gw.call).signIn(profile: "a", name: "j", open: { browser.open($0) },
                                                       sleep: { clock.advance($0) }, timeout: 5, now: { clock.now })
            XCTFail("no timeout")
        } catch { XCTAssertEqual(Redaction.describe(error), "Timed out waiting for the sign-in to finish.") }
        XCTAssertEqual(gw.params("mcp.servers.oauth.poll").count, 5)
        XCTAssertEqual(gw.params("mcp.servers.oauth.cancel").count, 1)

        let flag = Clock()  // reused as a counter: cancel after two polls
        let cancelling = FakeGateway()
        cancelling.on("mcp.servers.oauth.start") { _ in ["ok": true, "session_id": "sid", "auth_url": .string(Self.authURL)] }
        cancelling.on("mcp.servers.oauth.poll") { _ in flag.advance(1); return ["ok": true, "status": "pending"] }
        cancelling.on("mcp.servers.oauth.cancel") { _ in ["ok": true] }
        do {
            try await MCPServers(call: cancelling.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, sleep: { _ in },
                                                               cancelled: { flag.now.timeIntervalSince1970 >= 2 })
            XCTFail("not cancelled")
        } catch { XCTAssertTrue(error is MCPServers.Cancelled) }
        XCTAssertEqual(cancelling.params("mcp.servers.oauth.cancel").count, 1)

        let early = FakeGateway()
        do {
            try await MCPServers(call: early.call).signIn(profile: "a", name: "j", open: { browser.open($0) }, cancelled: { true })
            XCTFail("not cancelled")
        } catch { XCTAssertTrue(error is MCPServers.Cancelled) }
        XCTAssertTrue(early.methods.isEmpty, "nothing starts once cancelled")
    }
}
