import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Pre-release hardening: link policy for model Markdown, roster-unique monograms, the room sync error
/// classifier, and backend loss → `.failed` → Try Again through the real `AppModel.connect()`.
final class LinkPolicyTests: XCTestCase {
    func testOnlyWebLinksOpen() throws {
        for s in ["https://example.com/a?b=c", "http://example.com", "HTTPS://EXAMPLE.COM/x"] {
            XCTAssertTrue(MessageBody.opensLink(try XCTUnwrap(URL(string: s))), s)
        }
        for s in ["file:///etc/passwd", "smb://host/share", "x-hermes://run?cmd=rm", "javascript:alert(1)",
                  "mailto:a@example.com", "ftp://example.com/f", "vnc://host", "https:relative", "/local/path"] {
            XCTAssertFalse(MessageBody.opensLink(try XCTUnwrap(URL(string: s))), s)
        }
    }
}

final class MonogramTests: XCTestCase {
    func testCollidingBasesBecomeDistinct() {
        let m = Monogram.assign([("reviewer", "reviewer"), ("researcher", "researcher"), ("coder", "coder")])
        XCTAssertEqual(m["reviewer"], "RV")
        XCTAssertEqual(m["researcher"], "RS")
        XCTAssertEqual(m["coder"], "CO", "a bot without a collision keeps its own two letters")
    }

    func testUniqueAndDeterministicAcrossOrder() {
        let bots = [("reviewer", "Reviewer"), ("researcher", "Researcher"), ("rev", "Rev"), ("re", "Re"),
                    ("code-reviewer", "Code Reviewer"), ("content-reviewer", "Content Reviewer"), ("rs", "RS Bot")]
        let a = Monogram.assign(bots.map { (profile: $0.0, title: $0.1) })
        let b = Monogram.assign(bots.reversed().map { (profile: $0.0, title: $0.1) })
        XCTAssertEqual(a, b, "server order must not change monograms")
        XCTAssertEqual(Set(a.values).count, bots.count, "monograms collide: \(a)")
        XCTAssertTrue(a.values.allSatisfy { $0.count == 2 }, "\(a)")
        XCTAssertEqual(a["rs"], "RB", "a two-word title keeps its own base when it does not collide")
    }

    func testBaseUsesOnlyLettersAndDigitsAndIsTwoCharacters() {
        XCTAssertEqual(Monogram.base("🤖 Helper"), "HE", "symbols are not part of a word")
        XCTAssertEqual(Monogram.base("A.I. Bot"), "AI")
        XCTAssertEqual(Monogram.base("x-1"), "X1")
        XCTAssertEqual(Monogram.base("(beta)"), "BE")
        XCTAssertEqual(Monogram.base("R"), "RR", "a one-character title still gives two characters")
        XCTAssertEqual(Monogram.base("7"), "77")
        XCTAssertEqual(Monogram.base("ß"), "SS")
        XCTAssertEqual(Monogram.base("ßeta"), "SE", "ß uppercases to SS but stays one monogram character")
        XCTAssertEqual(Monogram.base("Straße Bot"), "SB")
        XCTAssertEqual(Monogram.base("--"), "?", "no letters or digits at all")
        for t in ["ß", "ßß", "ﬁx", "Ǆemal", "é", "e\u{301}t", "Ⅻ legion", "日本"] {
            XCTAssertEqual(Monogram.base(t).count, 2, t)
        }
    }

    func testOddTitlesStayUniqueAndTwoCharacters() {
        let bots = [("r1", "R"), ("r2", "R"), ("rr", "rr"), ("strasse", "Straße"), ("ss", "ß"), ("sym", "🤖 Robo"),
                    ("ro", "Ro")]
        let a = Monogram.assign(bots.map { (profile: $0.0, title: $0.1) })
        let b = Monogram.assign(bots.reversed().map { (profile: $0.0, title: $0.1) })
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.values).count, bots.count, "monograms collide: \(a)")
        XCTAssertTrue(a.values.allSatisfy { $0.count == 2 }, "\(a)")
    }

    func testIdentityUsesRosterMonogram() {
        let id = BotIdentity(profile: "reviewer", title: "reviewer", slot: 0, uniqueMonogram: "RV")
        XCTAssertEqual(id.monogram, "RV")
        XCTAssertEqual(BotIdentity(profile: "x", title: "Code Reviewer", slot: 0).monogram, "CR")
    }
}

final class RoomSyncFailureTests: XCTestCase {
    func testOnlyRPC4114DisbandsTheRoom() {
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.RPCError(code: 4114, message: "hosted room not found", data: nil)), .roomGone)
        // The text alone never disbands: another error that mentions "not found" or "4114" is transient.
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.RPCError(code: 4007, message: "session not found", data: nil)), .transient)
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.RPCError(code: 5000, message: "upstream said 4114", data: nil)), .transient)
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.ClientError.timeout("groups.log 4114 not found")), .transient)
    }

    func testDeadSocketStopsPolling() {
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.ClientError.closed("code=1006")), .connectionLost)
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.ClientError.notConnected), .connectionLost)
        XCTAssertEqual(RoomModel.syncFailure(GatewayClient.ClientError.transport(domain: "NSURLErrorDomain", code: -1005, message: "lost")),
                       .connectionLost)
    }
}

/// The backend dies after a successful connect: the app must notice (`Backend.onDisconnect`), show
/// `.failed`, keep no connection, and reconnect on Try Again. The first fake answers no `groups.*`
/// (an older Hermes Agent), so Group Chat is off while Bot Chat loads; the second one has Group Chat.
/// Same python fake approach as `AppModelRetryTests` (skipped without python3; never a real backend).
@MainActor
final class BackendLossTests: XCTestCase {
    /// `AppModel.shared` is process-wide: start from a clean model, so a failure elsewhere cannot cascade.
    override func setUp() async throws {
        let model = AppModel.shared
        await model.shutdown()
        model.selection = nil
        model.chats = [:]
        model.rooms = []
        model.roomModels = [:]
        model.bots = []
        model.modeText = ""
        model.phase = .connecting
        XCTAssertNil(model.backend)
    }

    /// Reads the fake backend's stdout until a whole line (or EOF): one read may return a partial line.
    private static func firstLine(_ h: FileHandle) -> String {
        var buf = Data()
        while !buf.contains(0x0A) {
            let d = h.availableData
            if d.isEmpty { break }
            buf.append(d)
        }
        return String(decoding: buf.prefix { $0 != 0x0A }, as: UTF8.self)
    }

    func testLostBackendFailsThenTryAgainReconnects() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("python3 not available") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-loss-\(UUID().uuidString.prefix(8))")
        let lock = dir.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake_backend.py")
        try Self.fakeBackend.write(to: script, atomically: true, encoding: .utf8)
        let calls = dir.appendingPathComponent("calls.json")

        func launch(_ groups: String) throws -> Process {
            let server = Process()
            server.executableURL = URL(fileURLWithPath: python)
            server.arguments = ["-I", script.path, lock.path, calls.path, groups]
            let out = Pipe()
            server.standardOutput = out
            try server.run()
            let ready = Self.firstLine(out.fileHandleForReading)
            XCTAssertEqual(ready, "READY", "fake backend did not start")
            return server
        }

        setenv("HERMES_BOT_APP_LOCK_DIR", lock.path, 1)
        setenv("HERMES_BOT_APP_NO_SPAWN", "1", 1)
        defer { unsetenv("HERMES_BOT_APP_LOCK_DIR"); unsetenv("HERMES_BOT_APP_NO_SPAWN") }

        let first = try launch("nogroups")
        defer { if first.isRunning { first.terminate(); first.waitUntilExit() } }
        let model = AppModel.shared
        await model.connect()
        guard case .connected = model.phase else { return XCTFail("connect should succeed, got \(model.phase)") }
        XCTAssertEqual(model.bots.map(\.name), ["fixture"], "Bot Chat still loads without groups.*")
        XCTAssertFalse(model.groupsAvailable)
        let seen = try JSONSerialization.jsonObject(with: Data(contentsOf: calls)) as? [String] ?? []
        XCTAssertFalse(seen.contains("groups.list"), "rooms are not listed when groups.* is missing: \(seen)")

        first.terminate(); first.waitUntilExit()  // the backend goes away under the app
        for _ in 0..<100 {
            if case .failed = model.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .failed = model.phase else { return XCTFail("a lost backend should show .failed, got \(model.phase)") }
        XCTAssertNil(model.backend, "a lost connection is dropped, so Try Again is not refused")
        XCTAssertTrue(model.chats.isEmpty)

        let second = try launch("groups")
        defer { if second.isRunning { second.terminate(); second.waitUntilExit() } }
        await model.connect()  // exactly what the Try Again button runs
        guard case .connected = model.phase else { return XCTFail("Try Again should reconnect, got \(model.phase)") }
        XCTAssertNotNil(model.backend)
        XCTAssertTrue(model.groupsAvailable)
        await model.shutdown()
        XCTAssertNil(model.backend)
    }

    /// Identity probe + `/api/ws` JSON-RPC. argv[3] "nogroups": groups.* → RPC -32601 (method not found).
    static let fakeBackend = #"""
import base64, hashlib, json, os, struct, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock, calls_path, groups = sys.argv[1], sys.argv[2], sys.argv[3] == "groups"
calls = []

def record(method):
    calls.append(method)
    with open(calls_path, "w") as f:
        json.dump(calls, f)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def frame(self, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        head = bytes([0x81, len(data)]) if len(data) < 126 else b"\x81\x7e" + struct.pack("!H", len(data))
        self.wfile.write(head + data); self.wfile.flush()
    def do_GET(self):
        if self.path.startswith("/api/ws"):
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept); self.end_headers()
            self.frame({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}})
            try:
                while True:
                    h = self.rfile.read(2)
                    if len(h) < 2: break
                    opcode, n = h[0] & 15, h[1] & 127
                    if n == 126: n = struct.unpack("!H", self.rfile.read(2))[0]
                    elif n == 127: n = struct.unpack("!Q", self.rfile.read(8))[0]
                    mask = self.rfile.read(4) if h[1] & 128 else None
                    data = self.rfile.read(n)
                    if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
                    if opcode == 8: break
                    if opcode != 1: continue
                    v = json.loads(data); method = v.get("method"); record(method)
                    if method == "profiles.list":
                        reply = {"result": {"profiles": [{"name": "fixture", "model": "fixture"}]}}
                    elif method.startswith("groups.") and not groups:
                        reply = {"error": {"code": -32601, "message": "method not found"}}
                    elif method == "groups.list":
                        reply = {"result": {"rooms": [], "has_more": False}}
                    else:
                        reply = {"result": {}}
                    self.frame({"jsonrpc": "2.0", "id": v["id"], **reply})
            except (OSError, ValueError):
                pass
            self.close_connection = True
            return
        if self.path == "/api/host/identity":
            data = json.dumps({"pid": os.getpid(), "role": "serve"}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
token = "synthetic-test-fixture"
rec = {"role": "serve", "pid": os.getpid(), "port": server.server_port, "host": "127.0.0.1", "protocolVersion": 1,
       "tokenFingerprint": hashlib.sha256(token.encode()).hexdigest()[:16]}
with open(os.path.join(lock, "host-serve.token"), "w") as f: f.write(token)
os.chmod(os.path.join(lock, "host-serve.token"), 0o600)
with open(os.path.join(lock, "host-serve.json"), "w") as f: json.dump(rec, f)
record_init = open(calls_path, "w"); json.dump([], record_init); record_init.close()
print("READY", flush=True)
server.serve_forever()
"""#
}
