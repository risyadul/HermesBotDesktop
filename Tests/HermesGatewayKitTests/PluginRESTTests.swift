import Foundation
import XCTest
@testable import HermesGatewayKit

/// `PluginREST`: auth header, error mapping, token hygiene, redirect and loopback refusal. All against
/// `StubURLProtocol` (no network).
final class PluginRESTTests: XCTestCase {
    private let secret = PluginStub.token

    private func assertNoToken(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let ns = error as NSError
        for text in ["\(error)", String(reflecting: error), error.localizedDescription, "\(ns.userInfo)", Redaction.describe(error)] {
            XCTAssertFalse(text.contains(secret), "error text leaks the token", file: file, line: line)
        }
    }

    private func failure(_ op: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> PluginREST.Failure? {
        do { try await op(); XCTFail("expected a failure", file: file, line: line); return nil } catch {
            assertNoToken(error, file: file, line: line)
            guard let f = error as? PluginREST.Failure else { XCTFail("not a PluginREST.Failure: \(error)", file: file, line: line); return nil }
            return f
        }
    }

    func testSendsSessionTokenHeaderOnlyAndBuildsPluginPath() async throws {
        let port = PluginStub.routes(["GET /api/plugins/kanban/boards": .init(json: #"{"boards":[],"current":"default"}"#)])
        let r = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards", query: [.init(name: "include_archived", value: "true")])
        XCTAssertEqual(r["current"]?.string, "default")
        let seen = try XCTUnwrap(StubURLProtocol.requests(port: port).first)
        XCTAssertEqual(seen.headers["X-Hermes-Session-Token"], secret)
        XCTAssertNil(seen.headers["Authorization"])
        XCTAssertNil(seen.headers["X-Hermes-Token"])
        XCTAssertFalse(seen.url.absoluteString.contains(secret), "token must never be in the URL")
        XCTAssertEqual(seen.url.path, "/api/plugins/kanban/boards")
        XCTAssertEqual(PluginStub.query(seen), ["include_archived": "true"])
    }

    func testPostSendsJSONBody() async throws {
        let port = PluginStub.routes(["POST /api/plugins/kanban/tasks": .init(json: #"{"task":null}"#)])
        _ = try await PluginStub.rest(port: port, plugin: "kanban").post("/tasks", body: ["title": "x", "priority": 2])
        let seen = try XCTUnwrap(StubURLProtocol.requests(port: port).first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.headers["Content-Type"], "application/json")
        XCTAssertEqual(seen.body, ["title": "x", "priority": 2])
    }

    func testUnauthorizedMapsTo401And403() async {
        for status in [401, 403] {
            let port = StubURLProtocol.serve { _ in .init(status: status, json: #"{"detail":"Unauthorized"}"#) }
            let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
            XCTAssertEqual(f, .unauthorized(status: status))
        }
    }

    func testPluginUnavailable404Variants() async {
        for detail in ["Plugin not found", "Not Found", "plugin 'bot-activity' is not enabled in this profile"] {
            let port = StubURLProtocol.serve { _ in .init(status: 404, json: #"{"detail":"\#(detail)"}"#) }
            let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "bot-activity").get("/activity") }
            XCTAssertEqual(f, .pluginUnavailable(plugin: "bot-activity"), detail)
        }
    }

    func testRoute404StaysHTTPWithDetail() async {
        let port = StubURLProtocol.serve { _ in .init(status: 404, json: #"{"detail":"task t_1 not found"}"#) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/tasks/t_1") }
        XCTAssertEqual(f, .http(status: 404, detail: "task t_1 not found"))
    }

    func testValidationDetailListIsJoined() async {
        let port = StubURLProtocol.serve { _ in
            .init(status: 422, json: #"{"detail":[{"loc":["body","title"],"msg":"Field required","type":"missing"}]}"#)
        }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").post("/tasks", body: [:]) }
        XCTAssertEqual(f, .http(status: 422, detail: "Field required"))
    }

    func testDetailEchoingTheTokenIsScrubbed() async {
        let port = StubURLProtocol.serve { [secret] _ in .init(status: 500, json: #"{"detail":"boom X-Hermes-Session-Token: \#(secret) end"}"#) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/board") }
        guard case .http(500, let d) = f else { return XCTFail("expected http 500, got \(String(describing: f))") }
        XCTAssertTrue(d.contains(Redaction.mask), d)
    }

    func testRedirectIsRefusedAndNotFollowed() async {
        let target = StubURLProtocol.serve { _ in .init(json: #"{"followed":true}"#) }
        let port = StubURLProtocol.serve { _ in .init(redirectTo: URL(string: "http://127.0.0.1:\(target)/elsewhere")!) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
        XCTAssertEqual(f, .http(status: 302, detail: "redirect refused"))
        XCTAssertTrue(StubURLProtocol.requests(port: target).isEmpty, "the redirect (and its token header) was followed")
    }

    func testNonLoopbackBaseIsRefusedBeforeSending() async {
        for host in ["example.com", "10.0.0.5", "192.168.1.2"] {
            let port = StubURLProtocol.serve { _ in .init(json: "{}") }
            let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban", host: host).get("/boards") }
            guard case .refused = f else { return XCTFail("\(host): expected .refused, got \(String(describing: f))") }
            XCTAssertTrue(StubURLProtocol.requests(port: port).isEmpty, "\(host): a request was sent")
        }
    }

    func testBadPathsAndPluginNamesAreRefused() async {
        let port = StubURLProtocol.serve { _ in .init(json: "{}") }
        for path in ["boards", "/../x", "/a/./b", "/a?token=1", "/a#f", "//evil"] {
            let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get(path) }
            guard case .refused = f else { return XCTFail("\(path): expected .refused, got \(String(describing: f))") }
        }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "../kanban").get("/boards") }
        guard case .refused = f else { return XCTFail("expected .refused for a bad plugin name") }
        XCTAssertTrue(StubURLProtocol.requests(port: port).isEmpty)
    }

    func testTransportFailureHasNoToken() async {
        // No handler registered for this port: the stub fails the load like a refused connection.
        let f = await failure { _ = try await PluginStub.rest(port: 1, plugin: "kanban").get("/boards") }
        guard case .transport = f else { return XCTFail("expected .transport, got \(String(describing: f))") }
    }

    func testNonJSONBodyIsDecodeError() async {
        let port = StubURLProtocol.serve { _ in .init(json: "<html>") }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
        XCTAssertEqual(f, .decode("response is not JSON"))
    }

    func testSegmentEncodesPathCharacters() {
        XCTAssertEqual(PluginREST.segment("t_1"), "t_1")
        XCTAssertEqual(PluginREST.segment("a/b c?"), "a%2Fb%20c%3F")
    }
    // MARK: response size cap and query encoding

    func testOversizedJSONResponseIsRefusedWhileStreaming() async {
        let big = Data(repeating: UInt8(ascii: " "), count: PluginREST.maxResponseBytes + 1)
        let port = StubURLProtocol.serve { _ in .init(data: big) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
        XCTAssertEqual(f, .refused("response too large"))
    }

    func testOversizedContentLengthIsRefusedBeforeReading() async {
        let port = StubURLProtocol.serve { _ in .init(json: "{}", headers: ["Content-Length": "\(PluginREST.maxResponseBytes + 1)"]) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
        XCTAssertEqual(f, .refused("response too large"))
    }

    func testOversizedErrorBodyIsRefusedToo() async {
        let big = Data(repeating: UInt8(ascii: "x"), count: PluginREST.maxResponseBytes + 1)
        let port = StubURLProtocol.serve { _ in .init(status: 500, data: big) }
        let f = await failure { _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards") }
        XCTAssertEqual(f, .refused("response too large"))
    }

    func testResponseAtTheCapIsAccepted() async throws {
        var json = Data("{\"a\":1}".utf8)
        json.append(Data(repeating: UInt8(ascii: " "), count: PluginREST.maxResponseBytes - json.count))
        let body = json
        let port = StubURLProtocol.serve { _ in .init(data: body) }
        let r = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards")
        XCTAssertEqual(r["a"]?.intValue, 1)
    }

    func testPlusInQueryValuesIsPercentEncoded() async throws {
        let port = StubURLProtocol.serve { _ in .init(json: "{}") }
        _ = try await PluginStub.rest(port: port, plugin: "kanban").get("/boards", query: [.init(name: "q", value: "c++ a+b c")])
        let seen = try XCTUnwrap(StubURLProtocol.requests(port: port).first)
        let raw = try XCTUnwrap(URLComponents(url: seen.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertFalse(raw.contains("+"), raw)
        XCTAssertEqual(raw, "q=c%2B%2B%20a%2Bb%20c")
        XCTAssertEqual(PluginStub.query(seen)["q"], "c++ a+b c", "decodes back to the literal value")
    }
}
