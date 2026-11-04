import Foundation
import Network
import XCTest
@testable import HermesGatewayKit

/// BLOCK-001 of review run300: no error text that leaves the kit may carry the WS token.
/// Runs against an in-process fake gateway on 127.0.0.1 (never the user's backend).
final class TokenLeakTests: XCTestCase {
    private let secret = "hbaTestSecret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private func assertClean(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains(secret), "\(what) leaks the token: \(text.replacingOccurrences(of: secret, with: "<SECRET>"))",
                       file: file, line: line)
        XCTAssertFalse(text.contains("token=" + secret.prefix(6)), "\(what) leaks a token query", file: file, line: line)
    }

    /// Every text form a consumer could produce from an error.
    private func assertClean(error: Error, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = error as NSError
        for (form, text) in [("interpolation", "\(error)"), ("reflecting", String(reflecting: error)),
                             ("localizedDescription", error.localizedDescription),
                             ("userInfo", "\(ns.userInfo)"), ("Redaction.describe", Redaction.describe(error))] {
            assertClean(text, "\(what) [\(form)]", file: file, line: line)
        }
    }

    private func wsURL(port: UInt16) -> URL {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: secret)]
        return c.url!
    }

    // MARK: - scrubber

    func testRedactionOfSyntheticURLError() {
        let url = wsURL(port: 9)
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            NSLocalizedDescriptionKey: "The network connection was lost.",
        ])
        XCTAssertTrue("\(e)".contains(secret), "precondition: raw interpolation of the NSError carries the token")
        assertClean(Redaction.describe(e), "describe(NSError)")
        let sanitized = GatewayClient(url: url).sanitize(e)
        assertClean(error: sanitized, "GatewayClient.sanitize")
        XCTAssertEqual(Redaction.scrub("GET /api/ws?token=abc123&x=1 Authorization: Bearer zzz.yyy"),
                       "GET /api/ws?token=[REDACTED]&x=1 Authorization: Bearer [REDACTED]")
    }

    // MARK: - real URLSession failures through GatewayClient

    func testConnectRefusedHasNoToken() async throws {
        let port = try FakeGateway.closedPort()
        let client = GatewayClient(url: wsURL(port: port))
        do {
            try await client.connect(timeout: 10)
            XCTFail("connect to a closed port succeeded")
        } catch {
            assertClean(error: error, "connect failure")
            guard case GatewayClient.ClientError.transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
    }

    func testCloseAndDeleteAfterClientCloseHaveNoToken() async throws {
        // Reviewer repro: open a session, close only the client socket, then close(deleteStored:).
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, chat) = try await openChat(gw)
        backend.client.close()
        let notes = await chat.close(deleteStored: true)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.allSatisfy { $0.contains("failed") }, "\(notes)")
        notes.forEach { assertClean($0, "cleanup note") }
        do { _ = try await chat.send("after close"); XCTFail("send succeeded") } catch { assertClean(error: error, "send after close") }
    }

    func testCallsAfterServerDropHaveNoTokenAndTurnIsTold() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let (backend, chat) = try await openChat(gw)
        let events = EventBox()
        chat.onEvent { events.add($0) }
        gw.dropAll()
        try await waitUntil { events.disconnectReason != nil }
        assertClean(events.disconnectReason ?? "", "disconnect reason")
        do { _ = try await chat.send("after drop"); XCTFail("send succeeded") } catch { assertClean(error: error, "send after drop") }
        let notes = await chat.close(deleteStored: true)
        notes.forEach { assertClean($0, "cleanup note after drop") }
        do { _ = try await backend.client.call("profiles.list", timeout: 5); XCTFail("call succeeded") }
        catch { assertClean(error: error, "call after drop") }
    }

    // MARK: - helpers

    private func openChat(_ gw: FakeGateway) async throws -> (Backend, BotChatSession) {
        let client = GatewayClient(url: wsURL(port: gw.port))
        let ready = try await client.connect(timeout: 10)
        let backend = Backend(mode: .spawned(pid: 0, port: Int(gw.port)), client: client, ready: ready, verdicts: [], owned: nil)
        let bot = try XCTUnwrap(Bot(["name": "fake"]))
        let chat = try await BotChatSession.open(backend, bot: bot, title: "hba-test")
        XCTAssertEqual(chat.sessionId, "rt-1")
        return (backend, chat)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met in \(timeout)s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatEvent] = []
    func add(_ e: ChatEvent) { lock.withLock { events.append(e) } }
    var disconnectReason: String? {
        lock.withLock { events.compactMap { if case .disconnected(let r) = $0 { return r }; return nil }.first }
    }
}

/// Minimal `/api/ws` stand-in: sends `gateway.ready`, answers the session methods the chat uses.
final class FakeGateway: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-gateway")
    private var conns: [NWConnection] = []
    private(set) var port: UInt16 = 0
    private var resolved = false
    private let recLock = NSLock()
    private var frames: [JSONValue] = []
    /// Every request frame received, in order (GroupChatTests checks `groups.*` param shapes).
    var received: [JSONValue] { recLock.withLock { frames } }
    /// Optional per-method answer (`method`, `params`) → result; a result object with `__error`
    /// (`{code, message}`) is sent as a JSON-RPC error. nil → the built-in answers below.
    private var _responder: (@Sendable (String, JSONValue) -> JSONValue?)?
    var responder: (@Sendable (String, JSONValue) -> JSONValue?)? {
        get { recLock.withLock { _responder } }
        set { recLock.withLock { _responder = newValue } }
    }

    private init(listener: NWListener) { self.listener = listener }

    private static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return p
    }

    static func start() async throws -> FakeGateway {
        let gw = FakeGateway(listener: try NWListener(using: parameters()))
        gw.listener.newConnectionHandler = { [weak gw] c in gw?.accept(c) }
        gw.port = try await withCheckedThrowingContinuation { cont in
            // The handler runs on gw.queue (serial), so `resolved` needs no lock.
            gw.listener.stateUpdateHandler = { [weak gw] s in
                guard let gw, !gw.resolved else { return }
                switch s {
                case .ready: gw.resolved = true; cont.resume(returning: gw.listener.port?.rawValue ?? 0)
                case .failed(let e): gw.resolved = true; cont.resume(throwing: e)
                default: break
                }
            }
            gw.listener.start(queue: gw.queue)
        }
        return gw
    }

    /// A loopback port nothing listens on (bound, then released).
    static func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    func dropAll() { queue.sync { conns.forEach { $0.forceCancel() }; conns.removeAll() } }

    func stop() { dropAll(); listener.cancel() }

    private func accept(_ c: NWConnection) {
        conns.append(c)
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, case .ready = s else { return }
            self.send(c, #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
            self.receive(c)
        }
        c.start(queue: queue)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let v = try? JSONDecoder().decode(JSONValue.self, from: data),
               let id = v["id"]?.int, let method = v["method"]?.string {
                if method != "gateway.ping" { self.recLock.withLock { self.frames.append(v) } }
                var result: JSONValue
                if let custom = self.responder?(method, v["params"] ?? [:]) {
                    result = custom
                } else {
                    switch method {
                    case "session.create": result = ["session_id": "rt-1", "stored_session_id": "st-1", "info": [:]]
                    case "session.title": result = ["title": "hba-test", "pending": false]
                    case "groups.stop": result = ["cancelled": 0]
                    default: result = [:]
                    }
                }
                if let err = result["__error"] {
                    self.send(c, (["jsonrpc": "2.0", "id": .number(Double(id)), "error": err] as JSONValue).compactJSON())
                } else {
                    self.send(c, (["jsonrpc": "2.0", "id": .number(Double(id)), "result": result] as JSONValue).compactJSON())
                }
            }
            self.receive(c)
        }
    }

    private func send(_ c: NWConnection, _ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}
