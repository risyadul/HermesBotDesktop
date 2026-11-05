import Foundation

/// JSON-RPC 2.0 client for the `hermes serve` gateway at `/api/ws`.
///
/// Wire facts (hermes-agent `tui_gateway/ws.py`, `hermes_cli/web_server_chat.py`):
/// - One JSON-RPC object per WS text message, both directions (`ws.py:397-425`, `190-205`). Requests
///   are sent one per frame (trailing newline allowed); never batch. The receive side still splits
///   on newlines as a client-side tolerance only, not a server guarantee.
/// - Right after accept the server pushes `{"method":"event","params":{"type":"gateway.ready",...}}`.
/// - Server-pushed events are notifications `method:"event"` with `params.type` / `params.payload`.
/// - `gateway.ping` is answered on the read loop even while a handler is busy (heartbeat).
/// - Loopback (non-gated) auth = `?token=<HERMES_DASHBOARD_SESSION_TOKEN>`. In that mode the server
///   accepts WITHOUT selecting a subprotocol; `hermes-gateway-v1` is only echoed on the gated
///   ticket path (`hermes-gateway-ticket.<ticket>`). See docs/groups-contract.md §2.
public final class GatewayClient: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public struct RPCError: Error, CustomStringConvertible {
        public let code: Int
        public let message: String
        public let data: JSONValue?
        public var description: String { "RPC error \(code): \(message)" + (data.map { " data=\($0)" } ?? "") }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case notConnected, closed(String), timeout(String), badFrame(String)
        /// A Foundation transport failure, reduced to token-free fields (see `Redaction`).
        case transport(domain: String, code: Int, message: String)
        public var description: String {
            switch self {
            case .notConnected: return "not connected"
            case .closed(let r): return "socket closed: \(r)"
            case .timeout(let m): return "timeout waiting for \(m)"
            case .badFrame(let f): return "bad frame: \(f)"
            case .transport(let d, let c, let m): return "transport error \(d) \(c): \(m)"
            }
        }
    }

    public typealias EventHandler = @Sendable (_ type: String, _ payload: JSONValue?, _ raw: JSONValue) -> Void

    private let url: URL
    private let offeredProtocols: [String]
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readyContinuation: CheckedContinuation<JSONValue, Error>?
    private var readyPayload: JSONValue?
    private var openContinuation: CheckedContinuation<String?, Error>?
    private var pingTimer: DispatchSourceTimer?
    private var disconnected = false
    /// Set once the socket is gone (failure or `close()`); later calls throw it. A client is single-use.
    private var terminalError: ClientError?
    private var sessionInvalidated = false
    // Handlers are written by consumers and read on URLSession's queue: always under `lock`.
    private var _onEvent: EventHandler?
    private var _onDisconnect: (@Sendable (_ reason: String) -> Void)?
    private var _onWire: (@Sendable (_ outbound: Bool, _ line: String) -> Void)?
    private var _negotiatedProtocol: String?

    public var onEvent: EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }
    /// Called once when the socket is gone (server drop, transport failure or `close()`), with a
    /// token-free reason. Pending calls fail with the same error.
    public var onDisconnect: (@Sendable (_ reason: String) -> Void)? {
        get { lock.withLock { _onDisconnect } }
        set { lock.withLock { _onDisconnect = newValue } }
    }
    /// Optional wire tap (direction, compact JSON) for evidence logs. Tokens never appear in frames.
    public var onWire: (@Sendable (_ outbound: Bool, _ line: String) -> Void)? {
        get { lock.withLock { _onWire } }
        set { lock.withLock { _onWire = newValue } }
    }
    public private(set) var negotiatedProtocol: String? {
        get { lock.withLock { _negotiatedProtocol } }
        set { lock.withLock { _negotiatedProtocol = newValue } }
    }

    public init(url: URL, offeredProtocols: [String] = []) {
        self.url = url
        self.offeredProtocols = offeredProtocols
        super.init()
        self.session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// Opens the socket and waits for `gateway.ready`. Returns the ready payload. A client connects
    /// once: after a failed connect, a drop or `close()` it stays closed (make a new client).
    @discardableResult
    public func connect(timeout: TimeInterval = 20) async throws -> JSONValue {
        do { return try await openAndAwaitReady(timeout: timeout) } catch {
            failAll(error)
            throw error
        }
    }

    private func openAndAwaitReady(timeout: TimeInterval) async throws -> JSONValue {
        // Created under the lock: `close()` may invalidate the session concurrently.
        let t = try lock.withLock { () throws -> URLSessionWebSocketTask in
            if let terminalError { throw terminalError }
            let t = offeredProtocols.isEmpty ? session.webSocketTask(with: url)
                : session.webSocketTask(with: url, protocols: offeredProtocols)
            task = t
            return t
        }
        let proto: String? = try await withCheckedThrowingContinuation { cont in
            lock.lock(); openContinuation = cont; lock.unlock()
            t.resume()
            receiveLoop(t)
            scheduleTimeout(timeout, "socket open") { [weak self] err in self?.failOpen(err) }
        }
        negotiatedProtocol = proto
        let ready: JSONValue = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = readyPayload { lock.unlock(); cont.resume(returning: r); return }
            readyContinuation = cont
            lock.unlock()
            scheduleTimeout(timeout, "gateway.ready") { [weak self] err in self?.failReady(err) }
        }
        startHeartbeat()
        return ready
    }

    /// Closes the socket and invalidates the URLSession (which retains this client as its delegate).
    /// Later `call`s fail fast with `closed` instead of sending on a cancelled task (whose URLSession
    /// error would carry the token URL).
    public func close() {
        let t = lock.withLock { () -> URLSessionWebSocketTask? in defer { task = nil }; return task }
        t?.cancel(with: .normalClosure, reason: nil)
        failAll(ClientError.closed("client close"))
    }

    /// The `?token=` value of our URL, for exact-match scrubbing of anything leaving this client.
    private var secrets: [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "token" }.compactMap(\.value)
    }

    /// Every error that leaves this client goes through here: Foundation errors (which carry the
    /// token URL in userInfo) become `ClientError.transport` with scrubbed text.
    func sanitize(_ e: Error) -> Error {
        switch e {
        case is ClientError, is RPCError: return e
        default:
            let ns = e as NSError
            return ClientError.transport(domain: ns.domain, code: ns.code,
                                         message: Redaction.scrub(ns.localizedDescription, secrets: secrets))
        }
    }

    /// Sends one request and awaits its `result` (throws `RPCError` on an `error` envelope).
    public func call(_ method: String, _ params: JSONValue = [:], timeout: TimeInterval = 120) async throws -> JSONValue {
        let (live, terminal) = lock.withLock { (task, terminalError) }
        if let terminal { throw terminal }
        guard let t = live else { throw ClientError.notConnected }
        let id = lock.withLock { () -> Int in defer { nextId += 1 }; return nextId }
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let line = frame.compactJSON()
        onWire?(true, line)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[id] = cont; lock.unlock()
            t.send(.string(line + "\n")) { [weak self] err in
                if let err, let self { self.resolve(id: id, .failure(self.sanitize(err))) }
            }
            scheduleTimeout(timeout, method) { [weak self] err in self?.resolve(id: id, .failure(err)) }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        lock.lock(); let c = openContinuation; openContinuation = nil; lock.unlock()
        c?.resume(returning: `protocol`)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let r = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        failAll(ClientError.closed("code=\(closeCode.rawValue) \(r)"))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failAll(sanitize(error)) }
    }

    // MARK: - internals

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.failAll(self.sanitize(e))
            case .success(let msg):
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: text = ""
                }
                for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                    self.handle(String(line))
                }
                self.receiveLoop(t)
            }
        }
    }

    private func handle(_ line: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            onWire?(false, "<unparsed> " + line.prefix(200)); return
        }
        if let id = value["id"]?.int, value["method"] == nil {
            onWire?(false, line)
            if let err = value["error"] {
                resolve(id: id, .failure(RPCError(code: err["code"]?.int ?? -1,
                                                  message: err["message"]?.string ?? "", data: err["data"])))
            } else {
                resolve(id: id, .success(value["result"] ?? .null))
            }
            return
        }
        if value["method"]?.string == "event" {
            let type = value["params"]?["type"]?.string ?? "?"
            let payload = value["params"]?["payload"]
            if type == "gateway.ready" {
                onWire?(false, #"{"method":"event","params":{"type":"gateway.ready","payload":<skin omitted>}}"#)
                lock.lock()
                readyPayload = payload ?? .null
                let c = readyContinuation; readyContinuation = nil
                lock.unlock()
                c?.resume(returning: payload ?? .null)
            } else {
                onWire?(false, line.count > 600 ? String(line.prefix(600)) + "…" : line)
            }
            onEvent?(type, payload, value)
            return
        }
        onWire?(false, line)
    }

    private func resolve(id: Int, _ result: Result<JSONValue, Error>) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        c?.resume(with: result)
    }

    private func failOpen(_ e: Error) {
        lock.lock(); let c = openContinuation; openContinuation = nil; lock.unlock()
        c?.resume(throwing: e)
    }

    private func failReady(_ e: Error) {
        lock.lock(); let c = readyContinuation; readyContinuation = nil; lock.unlock()
        c?.resume(throwing: e)
    }

    private func failAll(_ error: Error) {
        let e = sanitize(error)
        lock.lock()
        let all = pending; pending.removeAll()
        let o = openContinuation; openContinuation = nil
        let r = readyContinuation; readyContinuation = nil
        let notify = !disconnected && readyPayload != nil
        if notify { disconnected = true }
        let onDisconnect = _onDisconnect
        // Terminal: drop the task and timer so later calls throw `.closed`, not a stale transport error.
        if terminalError == nil {
            if let c = e as? ClientError, case .closed = c { terminalError = c }
            else { terminalError = .closed(Redaction.describe(e, secrets: secrets)) }
        }
        let t = task; task = nil
        let timer = pingTimer; pingTimer = nil
        let invalidate = !sessionInvalidated
        sessionInvalidated = true
        lock.unlock()
        t?.cancel()
        timer?.cancel()
        // Breaks the session → delegate (self) retain cycle once the cancelled task finishes.
        if invalidate { session.finishTasksAndInvalidate() }
        all.values.forEach { $0.resume(throwing: e) }
        o?.resume(throwing: e)
        r?.resume(throwing: e)
        if notify { onDisconnect?(Redaction.describe(e, secrets: secrets)) }
    }

    private func scheduleTimeout(_ seconds: TimeInterval, _ what: String, _ fire: @escaping @Sendable (Error) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { fire(ClientError.timeout(what)) }
    }

    /// The desktop client pings every 15s; the server's heartbeat deadline is 45s.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.lock.withLock({ self.task }) else { return }
            self.lock.lock(); let id = self.nextId; self.nextId += 1; self.lock.unlock()
            t.send(.string(#"{"jsonrpc":"2.0","id":\#(id),"method":"gateway.ping","params":{}}"# + "\n")) { _ in }
        }
        timer.resume()
        let started = lock.withLock { () -> Bool in
            guard terminalError == nil else { return false }
            pingTimer = timer
            return true
        }
        if !started { timer.cancel() }
    }
}
