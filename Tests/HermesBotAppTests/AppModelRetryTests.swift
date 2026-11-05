import XCTest
@testable import HermesBotApp

/// Try Again end to end through the real `AppModel.connect()` (the Try Again action): a local fake
/// backend that the app attaches to via the rendezvous lock dir answers the first `profiles.list` with an
/// RPC error and the second with one bot. Before the fix the second `connect()` returned at once and the
/// server only ever saw one `profiles.list`.
///
/// The fake is a small Python HTTP + WebSocket server (python3 from the Xcode command line tools); the
/// test is skipped where python3 is missing. It never touches a real Hermes backend: discovery is pointed
/// at a temporary lock dir and spawning is disabled.
@MainActor
final class AppModelRetryTests: XCTestCase {
    func testTryAgainAfterTransientProfilesFailureReconnects() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("python3 not available") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-retry-\(UUID().uuidString.prefix(8))")
        let lock = dir.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake_backend.py")
        try Self.fakeBackend.write(to: script, atomically: true, encoding: .utf8)
        let calls = dir.appendingPathComponent("calls.json")

        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["-I", script.path, lock.path, calls.path]
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertTrue(ready.contains("READY"), "fake backend did not start: \(ready)")

        setenv("HERMES_BOT_APP_LOCK_DIR", lock.path, 1)
        setenv("HERMES_BOT_APP_NO_SPAWN", "1", 1)
        defer { unsetenv("HERMES_BOT_APP_LOCK_DIR"); unsetenv("HERMES_BOT_APP_NO_SPAWN") }

        let model = AppModel.shared
        await model.connect()
        guard case .failed = model.phase else { return XCTFail("first attempt should fail, got \(model.phase)") }
        XCTAssertNil(model.backend, "the failed attempt keeps no connection")
        XCTAssertTrue(model.bots.isEmpty)

        await model.connect()  // exactly what the Try Again button runs
        guard case .connected = model.phase else { return XCTFail("Try Again should connect, got \(model.phase)") }
        XCTAssertEqual(model.bots.map(\.name), ["fixture"])
        XCTAssertNotNil(model.backend)

        await model.connect()  // connected: no-op

        await model.stopOwnedBackend(reason: "test")  // attached, not owned: never stopped
        XCTAssertNotNil(model.backend)
        await model.reconnect(reason: "test", waitForAttach: 2)  // Settings → Background: drop and attach again
        guard case .connected = model.phase else { return XCTFail("reconnect should attach again, got \(model.phase)") }
        XCTAssertEqual(model.bots.map(\.name), ["fixture"])
        await model.shutdown()

        let seen = try JSONSerialization.jsonObject(with: Data(contentsOf: calls)) as? [String] ?? []
        XCTAssertEqual(seen.filter { $0 == "profiles.list" }.count, 3, "calls: \(seen)")
        XCTAssertEqual(seen.filter { $0 == "groups.list" }.count, 2, "rooms load after each successful list")
    }

    /// Identity probe + `/api/ws` JSON-RPC. profiles.list #1 → RPC 5000, #2 → one profile.
    static let fakeBackend = #"""
import base64, hashlib, json, os, struct, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock, calls_path = sys.argv[1], sys.argv[2]
calls = []

def record(method):
    # Written to a temp file and renamed: the test may read the log while a late call (the activity poll
    # of a connection being shut down) is being recorded, and must never see a half-written file.
    calls.append(method)
    tmp = calls_path + ".%d.tmp" % len(calls)
    with open(tmp, "w") as f:
        json.dump(list(calls), f)
    os.replace(tmp, calls_path)

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
                    v = json.loads(data); method = v.get("method")
                    # The sidebar's activity poll (include_sessions: true) is not a roster load.
                    if method == "profiles.list" and (v.get("params") or {}).get("include_sessions") is True:
                        method = "profiles.list+sessions"
                    record(method)
                    if method == "profiles.list+sessions":
                        reply = {"result": {"profiles": [{"name": "fixture", "model": "fixture"}]}}
                    elif method == "profiles.list" and calls.count(method) == 1:
                        reply = {"error": {"code": 5000, "message": "synthetic transient profiles failure"}}
                    elif method == "profiles.list":
                        reply = {"result": {"profiles": [{"name": "fixture", "model": "fixture"}]}}
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
