import Foundation

/// A server→client request (`{"jsonrpc":"2.0","id":"srq-…","method":M,"params":{"session_id":sid,…}}`,
/// `tui_gateway/server_requests.py:84-86`; method table `tui_gateway/contracts/server_requests.py`).
/// The agent waits on it until it is answered, declined or cancelled (`request.cancel`).
public struct ServerRequest: Sendable, Equatable, Identifiable {
    /// The request id as text (stable key for UI state). The wire id is `wireId`.
    public let id: String
    /// The id exactly as received (string or number): echoed back unchanged.
    public let wireId: JSONValue
    public let method: String
    /// Runtime session id the request belongs to ("" for app-level requests).
    public let sessionId: String
    public let params: JSONValue
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        case approval(ApprovalPrompt)
        case clarify(ClarifyPrompt)
        case value(ValuePrompt)
        /// Known, but this app has no surface for it: declined with `4404` (window bridges, setup, vault).
        case notShown
        /// Not a method this app knows: answered `-32601`.
        case unknown
    }

    public init(wireId: JSONValue, method: String, params: JSONValue) {
        self.wireId = wireId
        id = wireId.string ?? wireId.compactJSON()
        self.method = method
        self.params = params
        sessionId = params["session_id"]?.string ?? ""
        switch method {
        case "approval": kind = .approval(ApprovalPrompt(params))
        case "clarify": kind = .clarify(ClarifyPrompt(params))
        case "sudo", "secret": kind = .value(ValuePrompt(method: method, params))
        case _ where Self.notShownMethods.contains(method): kind = .notShown
        default: kind = .unknown
        }
    }

    /// `{id, method, params}` rows of `open_requests` on `session.resume` (`server.py:781-794`).
    init?(openRequest v: JSONValue) {
        guard let id = v["id"], id != .null, let method = v["method"]?.string else { return nil }
        self.init(wireId: id, method: method, params: v["params"] ?? [:])
    }

    /// Window-owned bridges (`server_requests.py:107-111`, Desktop `WINDOW_OWNED_REQUESTS`) plus the
    /// requests this app has no UI for (`setup_choose`, vault, display install). A `4404` decline only
    /// settles once every attached client declined, so Hermes Desktop can still answer them.
    public static let notShownMethods: Set<String> = [
        "terminal.read", "preview.read", "preview.act", "window.read", "tour",
        "setup_choose", "vault.unlock_prompt", "vault.save_login", "vault.code", "display.install.sudo",
    ]
    /// `NOT_SHOWN_CODE` (`server_requests.py:111`) and Desktop's text (`gateway-event/server-requests.ts:116`).
    public static let notShownCode = 4404
    public static let notShownMessage = "This window is not showing the session."
    public static let methodNotFoundCode = -32601
    /// Desktop answers a request of an interrupted session with a JSON-RPC internal error.
    public static let interruptedCode = -32603
}

/// `approval` params (`contracts/server_requests.py:100-131`, payload `server.py:765-778`).
public struct ApprovalPrompt: Sendable, Equatable {
    public enum Choice: String, Sendable, CaseIterable { case once, session, always, deny }
    /// Approval QUEUE id (what `approval.respond` / `approval.received` key on), not the request id.
    public let requestId: String?
    /// Already redacted by the backend.
    public let command: String
    public let description: String
    public let choices: [Choice]
    public let toolName: String?

    init(_ p: JSONValue) {
        requestId = p["request_id"]?.string
        command = p["command"]?.string ?? ""
        description = p["description"]?.string ?? ""
        let offered = (p["choices"]?.array ?? []).compactMap { $0.string.flatMap(Choice.init(rawValue:)) }
        choices = offered.isEmpty ? Choice.allCases : offered
        toolName = p["tool_name"]?.string
    }
}

/// `clarify` params: `questions:[{qid, question, choices?, multi_select}]`, `answers?` on replay
/// (`contracts/server_requests.py:34-56`).
public struct ClarifyPrompt: Sendable, Equatable {
    public struct Question: Sendable, Equatable, Identifiable {
        public var id: String { qid }
        public let qid: String
        public let question: String
        public let choices: [String]
        public let multiSelect: Bool
    }
    public let questions: [Question]
    /// Answers already locked (`clarify.lock`) when the request is replayed after a reconnect.
    public let replayAnswers: [String: String?]

    init(_ p: JSONValue) {
        questions = (p["questions"]?.array ?? []).compactMap { q in
            guard let qid = q["qid"]?.string else { return nil }
            return Question(qid: qid, question: q["question"]?.string ?? "",
                            choices: (q["choices"]?.array ?? []).compactMap(\.string),
                            multiSelect: q["multi_select"]?.bool ?? false)
        }
        var answers: [String: String?] = [:]
        for (k, v) in p["answers"]?.object ?? [:] { answers[k] = v.string }
        replayAnswers = answers
    }
}

/// `sudo {command}` / `secret {env_var, prompt}` (`contracts/server_requests.py:140-157`). Answer with
/// a masked field; `""` declines.
public struct ValuePrompt: Sendable, Equatable {
    public enum Kind: String, Sendable { case sudo, secret }
    public let kind: Kind
    public let command: String?
    public let envVar: String?
    public let prompt: String

    init(method: String, _ p: JSONValue) {
        kind = Kind(rawValue: method) ?? .secret
        command = p["command"]?.string
        envVar = p["env_var"]?.string
        prompt = p["prompt"]?.string ?? (kind == .sudo ? "sudo password" : "value")
    }
}

/// A typed answer, encoded as the result object the backend reads.
public enum ServerRequestAnswer: Sendable, Equatable {
    /// `{choice, all}` (`server.py` `_emit_approval_request.on_result`).
    case approval(ApprovalPrompt.Choice, all: Bool = false)
    /// `{answers: {qid: str|null}}`; nil = that question skipped.
    case clarify([String: String?])
    /// `{}`: no `answers` cancels the whole clarify (`server_requests.py` `resolve_response`).
    case clarifyCancel
    /// `{value}`; `""` declines a value prompt.
    case value(String)

    public var result: JSONValue {
        switch self {
        case .approval(let c, let all): return ["choice": .string(c.rawValue), "all": .bool(all)]
        case .clarify(let answers):
            return ["answers": .object(answers.mapValues { $0.map(JSONValue.string) ?? .null })]
        case .clarifyCancel: return [:]
        case .value(let v): return ["value": .string(v)]
        }
    }
}

/// Routes server→client requests to the chat session that owns their `session_id` and declines the
/// rest. Policy (`.omc/research/wire-parity.md` §4, `server_requests.py:107-111, 260-306`):
/// - unknown method → `-32601` (settles as "unanswered").
/// - known but not shown here → `4404` (a decline that only settles once every attached client declined,
///   so another client such as Hermes Desktop can still answer).
/// - a shown kind whose session nobody here routes YET is held (`UnroutedHold`: the backend can send it
///   before the `session.resume` reply that lets us subscribe) and handed to the first subscriber of that
///   session; only when the hold window passes unclaimed is it declined `4404`. Session-less ones are
///   declined at once.
/// Against a backend that did not advertise `declines_not_shown` the first error would settle the
/// request, so no `4404` is sent then (Desktop does the same).
final class ServerRequestRouter: @unchecked Sendable {
    typealias Handler = @Sendable (ServerRequest) -> Void
    private struct Held { let request: ServerRequest; let client: GatewayClient; let at: Date }
    private let lock = NSLock()
    /// Serializes handler calls (same reason as `EventRouter.delivery`).
    private let delivery = NSRecursiveLock()
    private var handlers: [UUID: (String, Handler)] = [:]
    private var held: [Held] = []
    private var _declinesNotShown = true
    private let window: TimeInterval
    private let limit: Int

    init(window: TimeInterval = UnroutedHold.window, limit: Int = UnroutedHold.limit) {
        self.window = window; self.limit = limit
    }

    var declinesNotShown: Bool {
        get { lock.withLock { _declinesNotShown } }
        set { lock.withLock { _declinesNotShown = newValue } }
    }

    /// Registers `h` for `sessionId`, then hands it that session's held requests (in order).
    func add(sessionId: String, _ h: @escaping Handler) -> UUID {
        let id = UUID()
        delivery.lock(); defer { delivery.unlock() }
        let claimed = lock.withLock { () -> [ServerRequest] in
            handlers[id] = (sessionId, h)
            guard !sessionId.isEmpty else { return [] }
            let mine = held.filter { $0.request.sessionId == sessionId }.map(\.request)
            held.removeAll { $0.request.sessionId == sessionId }
            return mine
        }
        claimed.forEach(h)
        return id
    }

    func remove(_ id: UUID) { lock.withLock { _ = handlers.removeValue(forKey: id) } }

    func route(_ req: ServerRequest, client: GatewayClient) {
        switch req.kind {
        case .unknown:
            reply(client) { try await client.respondError(id: req.wireId, code: ServerRequest.methodNotFoundCode,
                                                          message: "method not found: \(req.method)") }
        case .notShown:
            declineNotShown(req, client: client)
        case .approval, .clarify, .value:
            guard !req.sessionId.isEmpty else { return declineNotShown(req, client: client) }
            delivery.lock(); defer { delivery.unlock() }
            let (target, overflow) = lock.withLock { () -> (Handler?, [Held]) in
                if let t = handlers.values.first(where: { $0.0 == req.sessionId })?.1 { return (t, []) }
                held.append(Held(request: req, client: client, at: Date()))
                let extra = max(0, held.count - limit)
                defer { held.removeFirst(extra) }
                return (nil, Array(held.prefix(extra)))
            }
            overflow.forEach { declineNotShown($0.request, client: $0.client) }
            if let target { return target(req) }
            expire(req, after: window)
        }
    }

    /// Declines `req` with `4404` if it is still held unclaimed after `seconds`. Matched on session and
    /// request id together, so an id the backend reuses in another session never removes the wrong one.
    private func expire(_ req: ServerRequest, after seconds: TimeInterval) {
        let (sessionId, id) = (req.sessionId, req.id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self else { return }
            let gone = self.lock.withLock { () -> Held? in
                guard let i = self.held.firstIndex(where: { $0.request.sessionId == sessionId && $0.request.id == id })
                else { return nil }
                return self.held.remove(at: i)
            }
            if let gone { self.declineNotShown(gone.request, client: gone.client) }
        }
    }

    /// The socket is gone: held requests died with it (the backend withdraws them), so drop them without a
    /// reply instead of declining on a dead socket later.
    func disconnected() { lock.withLock { held.removeAll() } }

    /// `4404` "not shown", unless the backend settles a request on its first error (`declines_not_shown`
    /// not advertised): then nothing is sent so another client can still answer.
    func declineNotShown(_ req: ServerRequest, client: GatewayClient) {
        guard declinesNotShown else { return }
        reply(client) { try await client.respondError(id: req.wireId, code: ServerRequest.notShownCode,
                                                      message: ServerRequest.notShownMessage) }
    }

    /// Number of requests currently held, and of live subscriptions (tests).
    var heldCount: Int { lock.withLock { held.count } }
    var subscriberCount: Int { lock.withLock { handlers.count } }

    /// Best effort: a failed reply means the socket is gone, which the disconnect path reports.
    private func reply(_ client: GatewayClient, _ send: @escaping @Sendable () async throws -> Void) {
        Task { try? await send() }
    }
}

extension BotChatSession {
    /// Answers a request this session received (`ChatEvent.request`), echoing its id.
    public func answer(_ request: ServerRequest, _ answer: ServerRequestAnswer) async throws {
        try await backend.client.respond(id: request.wireId, result: answer.result)
    }

    /// Declines a request (e.g. the user stopped the turn): Desktop replies a JSON-RPC internal error
    /// "session interrupted" rather than dropping it (`gateway-event/server-requests.ts:269-277`).
    public func decline(_ request: ServerRequest, code: Int = ServerRequest.interruptedCode,
                        message: String = "session interrupted") async throws {
        try await backend.client.respondError(id: request.wireId, code: code, message: message)
    }
}
