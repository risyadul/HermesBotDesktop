# Fake Hermes backend for scripts/sigint-regression.sh. Never touches a real Hermes home.
# Speaks just enough of /api/ws JSON-RPC for one Bot Chat turn and its cleanup.
#   attach: fake_backend.py attach <lockdir> <calls.log>   (writes host-serve rendezvous record)
#   spawn:  fake_backend.py serve --host H --port 0 [...]  (calls log from HBA_FAKE_CALLS)
import base64, hashlib, json, os, signal, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = sys.argv[1]
if mode == "attach":
    lock, calls_path = sys.argv[2], sys.argv[3]
else:
    # ServeProcess gives the child a clean env; the generated fake `hermes` wrapper sets this.
    lock, calls_path = None, os.environ["HBA_FAKE_CALLS"]
wlock = threading.Lock()

def record(s):
    with wlock, open(calls_path, "a") as f:
        f.write(f"{time.time():.6f} pid={os.getpid()} pgid={os.getpgrp()} {s}\n")

def on_signal(sig, _):
    record(f"SIGNAL {signal.Signals(sig).name}")
    if sig in (signal.SIGTERM, signal.SIGINT):
        os._exit(0)
signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def frame(self, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        if len(data) < 126: head = bytes([0x81, len(data)])
        else: head = b"\x81\x7e" + struct.pack("!H", len(data))
        with self.server.send_lock:
            self.wfile.write(head + data); self.wfile.flush()
    def event(self, typ, sid, payload):
        self.frame({"jsonrpc": "2.0", "method": "event", "params": {"type": typ, "session_id": sid, "payload": payload}})
    def do_GET(self):
        if self.path.startswith("/api/ws"):
            self.server.send_lock = threading.Lock()
            key = self.headers["Sec-WebSocket-Key"]
            acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
            proto = self.headers.get("Sec-WebSocket-Protocol")
            if proto: self.send_header("Sec-WebSocket-Protocol", proto.split(",")[0].strip())
            self.send_header("Sec-WebSocket-Accept", acc); self.end_headers()
            self.event("gateway.ready", None, {})
            n_sess = 0
            try:
                while True:
                    h = self.rfile.read(2)
                    if len(h) < 2: break
                    op, n = h[0] & 15, h[1] & 127
                    if n == 126: n = struct.unpack("!H", self.rfile.read(2))[0]
                    elif n == 127: n = struct.unpack("!Q", self.rfile.read(8))[0]
                    mask = self.rfile.read(4) if h[1] & 128 else None
                    data = self.rfile.read(n)
                    if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
                    if op == 8: break
                    if op != 1: continue
                    v = json.loads(data); m = v.get("method"); p = v.get("params") or {}
                    record(f"RPC {m} {json.dumps(p.get('session_id'))}")
                    res = {}
                    if m == "profiles.list": res = {"profiles": [{"name": "fixture", "model": "fixture"}]}
                    elif m == "groups.list": res = {"rooms": [], "has_more": False}
                    elif m == "session.create":
                        n_sess += 1
                        res = {"session_id": f"live-{n_sess}", "stored_session_id": f"stored-{n_sess}"}
                    elif m == "session.close":
                        # slow close: the runner sends its 2nd Ctrl+C while this is in flight
                        time.sleep(1.5); record("CLOSE_DONE"); res = {"closed": True}
                    elif m == "session.delete": res = {"deleted": p.get("session_id")}
                    elif m == "prompt.submit":
                        sid = p.get("session_id")
                        self.frame({"jsonrpc": "2.0", "id": v["id"], "result": {"status": "accepted"}})
                        def stream(sid=sid):
                            time.sleep(0.2); self.event("message.start", sid, {})
                            for w in ["synthetic ", "fixture ", "reply"]:
                                time.sleep(0.1); self.event("message.delta", sid, {"text": w})
                            self.event("message.complete", sid, {"text": "synthetic fixture reply", "status": "complete"})
                        threading.Thread(target=stream, daemon=True).start()
                        continue
                    self.frame({"jsonrpc": "2.0", "id": v["id"], "result": res})
            except (OSError, ValueError):
                pass
            self.close_connection = True
            return
        if self.path.startswith("/api/host/identity"):
            data = json.dumps({"pid": os.getpid(), "role": "serve"}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
record(f"START mode={mode}")
if mode == "attach":
    token = "synthetic-test-fixture"
    rec = {"role": "serve", "pid": os.getpid(), "port": server.server_port, "host": "127.0.0.1", "protocolVersion": 1,
           "tokenFingerprint": hashlib.sha256(token.encode()).hexdigest()[:16]}
    tp = os.path.join(lock, "host-serve.token")
    with open(tp, "w") as f: f.write(token)
    os.chmod(tp, 0o600)
    with open(os.path.join(lock, "host-serve.json"), "w") as f: json.dump(rec, f)
    print("READY", flush=True)
else:
    print(f"HERMES_BACKEND_READY port={server.server_port}", flush=True)
server.serve_forever()
