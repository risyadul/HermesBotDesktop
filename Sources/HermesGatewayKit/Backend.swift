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
    private let router = EventRouter()

    /// Internal (not private) so tests can wrap a client connected to a local fake gateway.
    init(mode: Mode, client: GatewayClient, ready: JSONValue, verdicts: [HostRendezvous.Verdict], owned: ServeProcess?) {
        self.mode = mode; self.client = client; self.ready = ready; self.verdicts = verdicts; self.owned = owned
        client.onEvent = { [router] type, payload, raw in router.dispatch(type: type, payload: payload, raw: raw) }
        client.onDisconnect = { [router] reason in router.disconnected(reason) }
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
                return Backend(mode: .attached(found), client: client, ready: ready, verdicts: verdicts, owned: nil)
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
            return Backend(mode: .spawned(pid: serve.pid, port: port), client: client, ready: ready,
                           verdicts: verdicts, owned: serve)
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
    @discardableResult
    public func subscribe(sessionId: String, _ handler: @escaping EventRouter.Handler) -> UUID {
        router.add(sessionId: sessionId, handler)
    }

    public func unsubscribe(_ token: UUID) { router.remove(token) }

    /// Called once when the gateway socket is gone (token-free reason). No reconnect in M1.
    @discardableResult
    public func onDisconnect(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        router.addDisconnect(handler)
    }

    /// Taps every event (evidence logging).
    public func tapAll(_ handler: @escaping EventRouter.Handler) { router.tap = handler }
}

public final class EventRouter: @unchecked Sendable {
    public typealias Handler = @Sendable (_ type: String, _ payload: JSONValue?, _ raw: JSONValue) -> Void
    private let lock = NSLock()
    private var handlers: [UUID: (String, Handler)] = [:]
    private var disconnectHandlers: [UUID: @Sendable (String) -> Void] = [:]
    private var tapHandler: Handler?
    /// Taps every event. Guarded by `lock`: it can be set while events are being routed.
    public var tap: Handler? {
        get { lock.withLock { tapHandler } }
        set { lock.withLock { tapHandler = newValue } }
    }

    func addDisconnect(_ h: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { disconnectHandlers[id] = h }
        return id
    }

    func disconnected(_ reason: String) {
        let targets = lock.withLock { Array(disconnectHandlers.values) }
        targets.forEach { $0(reason) }
    }

    func add(sessionId: String, _ h: @escaping Handler) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = (sessionId, h) }
        return id
    }

    func remove(_ id: UUID) {
        lock.withLock { _ = handlers.removeValue(forKey: id); _ = disconnectHandlers.removeValue(forKey: id) }
    }

    func dispatch(type: String, payload: JSONValue?, raw: JSONValue) {
        let sid = raw["params"]?["session_id"]?.string ?? ""
        let (tap, targets) = lock.withLock { (tapHandler, handlers.values.filter { $0.0 == sid }.map(\.1)) }
        tap?(type, payload, raw)
        targets.forEach { $0(type, payload, raw) }
    }
}
