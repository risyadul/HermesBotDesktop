import Foundation

/// M1 connection layer: attach-first to a running backend, spawn-if-absent otherwise.
///
/// Order (docs/gateway-contract.md §1):
/// 1. `HostRendezvous.discover` over the per-user lock dir: `host-serve` then `host-desktop-serve`.
///    The first record that proves itself (uid, protocol, pid+start time, token fingerprint, TCP,
///    `/api/host/identity`) is attached to: WS `/api/ws?token=<0600 token>`. Nothing is spawned and the
///    attached backend is never stopped by this app.
/// 2. No acceptable record → spawn `hermes serve --host 127.0.0.1 --port 0 --isolated` on `~/.hermes`
///    (`ServeProcess.Configuration.sameHomeDefault`) with `HERMES_PARENT_PID`, and connect to it. Only
///    this owned child is ever stopped (SIGTERM, SIGKILL after a grace period).
public final class Backend: @unchecked Sendable {
    public enum Mode: Sendable, CustomStringConvertible {
        case attached(HostRendezvous.Attachment)
        case spawned(pid: Int32, port: Int)
        public var description: String {
            switch self {
            case .attached(let a): return "attached \(a.description)"
            case .spawned(let pid, let port): return "spawned pid=\(pid) port=\(port) (--isolated)"
            }
        }
        public var isAttached: Bool { if case .attached = self { return true }; return false }
    }

    public struct Options: Sendable {
        /// Lock dir to discover in. Default: the per-user rendezvous dir.
        public var lockDir: URL = HostRendezvous.lockDir()
        /// Spawn config for the fallback. `lockDir` nil there = the child uses the real default dir.
        public var spawn: ServeProcess.Configuration = .sameHomeDefault()
        /// Skip discovery (testing the fallback while another backend is alive).
        public var forceSpawn = false
        public var allowSpawn = true
        public init() {}

        /// Env overrides used by the app and the harness:
        /// - `HERMES_BOT_APP_LOCK_DIR`: discover in (and hand the spawned child) this lock dir instead
        ///   of the real one. An empty dir simulates "no backend running" without touching Electron.
        /// - `HERMES_BOT_APP_FORCE_SPAWN=1`, `HERMES_BOT_APP_NO_SPAWN=1`.
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Options {
            var o = Options()
            if let d = env["HERMES_BOT_APP_LOCK_DIR"], !d.isEmpty {
                let url = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
                o.lockDir = url
                o.spawn.lockDir = url
            }
            o.forceSpawn = env["HERMES_BOT_APP_FORCE_SPAWN"] == "1"
            o.allowSpawn = env["HERMES_BOT_APP_NO_SPAWN"] != "1"
            return o
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noBackend([HostRendezvous.Verdict])
        public var description: String {
            if case .noBackend(let v) = self { return "no running backend and spawn disabled: \(v)" }
            return ""
        }
    }

    public let mode: Mode
    public let client: GatewayClient
    public let ready: JSONValue
    public let verdicts: [HostRendezvous.Verdict]
    public private(set) var owned: ServeProcess?
    let router: EventRouter
    let requests: ServerRequestRouter

    /// Internal (not private) so tests can wrap a client connected to a local fake gateway. `holdWindow`:
    /// how long a session-scoped event or request nobody routes yet is kept for a subscriber that is about
    /// to attach (`EventRouter`); tests shorten it.
    init(mode: Mode, client: GatewayClient, ready: JSONValue, verdicts: [HostRendezvous.Verdict], owned: ServeProcess?,
         holdWindow: TimeInterval = UnroutedHold.window) {
        self.mode = mode; self.client = client; self.ready = ready; self.verdicts = verdicts; self.owned = owned
        router = EventRouter(window: holdWindow)
        requests = ServerRequestRouter(window: holdWindow)
        client.onEvent = { [router] type, payload, raw in router.dispatch(type: type, payload: payload, raw: raw) }
        client.onDisconnect = { [router, requests] reason in
            requests.disconnected()
            router.disconnected(reason)
        }
        client.onRequest = { [requests, weak client] id, method, params in
            guard let client else { return }
            requests.route(ServerRequest(wireId: id, method: method, params: params), client: client)
        }
    }

    /// Wraps a connected client and advertises `client.capabilities {server_requests: true}` once, right
    /// after `gateway.ready` (`contracts/liveness.py:29-48`, handler `methods_voice.py:442-450`). Without it
    /// every approval/clarify/sudo request fails fast for this connection (`server_requests.py:120-157`).
    /// Handlers are installed before the call, so no request can arrive unrouted. A backend without the
    /// method (older build) is logged and tolerated.
    static func make(mode: Mode, client: GatewayClient, ready: JSONValue, verdicts: [HostRendezvous.Verdict],
                     owned: ServeProcess?, holdWindow: TimeInterval = UnroutedHold.window,
                     log: @Sendable (String) -> Void = { _ in }) async -> Backend {
        let b = Backend(mode: mode, client: client, ready: ready, verdicts: verdicts, owned: owned, holdWindow: holdWindow)
        await b.advertiseCapabilities(log: log)
        return b
    }

    func advertiseCapabilities(log: @Sendable (String) -> Void = { _ in }) async {
        do {
            let r = try await client.call("client.capabilities", ["server_requests": true], timeout: 20)
            let methods = (r["server_requests"]?.array ?? []).compactMap(\.string)
            requests.declinesNotShown = r["declines_not_shown"]?.bool ?? false
            log("client.capabilities → \(methods.count) server request methods, declines_not_shown=\(requests.declinesNotShown)")
        } catch {
            requests.declinesNotShown = false
            log("client.capabilities failed: \(Redaction.describe(error))")
        }
    }

    /// `log` receives token-free lines only.
    public static func connect(_ options: Options = .fromEnvironment(),
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Backend {
        var verdicts: [HostRendezvous.Verdict] = []
        if !options.forceSpawn {
            log("discovering backend in \(options.lockDir.path)")
            let (found, v) = await HostRendezvous.discover(lockDir: options.lockDir)
            verdicts = v
            v.forEach { log("  rendezvous \($0)") }
            if let found {
                let client = GatewayClient(url: found.wsURL)
                let ready = try await client.connect()
                log("attached: \(found) — gateway.ready received")
                return await make(mode: .attached(found), client: client, ready: ready, verdicts: verdicts, owned: nil, log: log)
            }
        } else {
            log("discovery skipped (forceSpawn)")
        }
        guard options.allowSpawn else { throw Failure.noBackend(verdicts) }
        let serve = ServeProcess(configuration: options.spawn)
        log("no live backend: spawning \(options.spawn.hermesExecutable.path) serve --host 127.0.0.1 --port 0"
            + (options.spawn.isolated ? " --isolated" : "")
            + " (HERMES_HOME=\(options.spawn.hermesHome.path), lock dir=\(options.spawn.lockDir?.path ?? "<default>"))")
        let port: Int
        do { port = try await serve.start() } catch { serve.stop(); throw error }
        log("spawned serve READY pid=\(serve.pid) port=\(port)")
        guard let url = serve.wsURL else { serve.stop(); throw GatewayClient.ClientError.notConnected }
        let client = GatewayClient(url: url)
        do {
            let ready = try await client.connect()
            log("connected to owned backend — gateway.ready received")
            return await make(mode: .spawned(pid: serve.pid, port: port), client: client, ready: ready,
                              verdicts: verdicts, owned: serve, log: log)
        } catch {
            serve.stop(); throw error
        }
    }

    /// Read-only REST access to the same backend (exact session lookups for cleanup). Token stays in memory.
    public var sessionREST: SessionRESTAccess? {
        switch mode {
        case .attached(let a): return SessionRESTAccess(base: a.httpBase, token: a.token)
        case .spawned(_, let port):
            guard let owned, let base = URL(string: "http://\(owned.configuration.host):\(port)") else { return nil }
            return SessionRESTAccess(base: base, token: owned.sessionToken)
        }
    }

    /// Closes the socket. Stops the backend ONLY when this app spawned it.
    public func shutdown(grace: TimeInterval = 10) {
        client.close()
        owned?.stop(grace: grace)
    }

    // MARK: - events

    /// Subscribe to events whose `params.session_id` equals `sessionId` ("" = session-less broadcasts).
    /// Events of that session that arrived unrouted within the hold window are replayed first, in order.
    @discardableResult
    public func subscribe(sessionId: String, _ handler: @escaping EventRouter.Handler) -> UUID {
        router.add(sessionId: sessionId, handler)
    }

    public func unsubscribe(_ token: UUID) { router.remove(token); requests.remove(token) }

    /// Routes server→client requests whose `params.session_id` equals `sessionId` to `handler`; requests of
    /// that session still held unrouted are handed over first, in order. Remove with `unsubscribe`.
    @discardableResult
    public func onServerRequest(sessionId: String, _ handler: @escaping @Sendable (ServerRequest) -> Void) -> UUID {
        requests.add(sessionId: sessionId, handler)
    }

    /// Called once when the gateway socket is gone (token-free reason). No reconnect in M1.
    @discardableResult
    public func onDisconnect(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        router.addDisconnect(handler)
    }

    /// Taps every event (evidence logging).
    public func tapAll(_ handler: @escaping EventRouter.Handler) { router.tap = handler }
}
