import Foundation

/// One bot = one Hermes profile, as listed by `profiles.list` (`tui_gateway/methods_profiles.py:281-303`).
public struct Bot: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let displayName: String?
    public let description: String?
    public let model: String?
    public let provider: String?
    public let isDefault: Bool
    public let skillCount: Int?

    public var title: String { (displayName?.isEmpty == false ? displayName : nil) ?? name }

    init?(_ v: JSONValue) {
        guard let name = v["name"]?.string else { return nil }
        self.name = name
        displayName = v["display_name"]?.string
        description = v["description"]?.string
        model = v["model"]?.string
        provider = v["provider"]?.string
        isDefault = v["is_default"]?.bool ?? false
        skillCount = v["skill_count"]?.int
    }

    /// `profiles.list {include_sessions: false}` → bots in server order.
    public static func list(_ backend: Backend) async throws -> [Bot] {
        let r = try await backend.client.call("profiles.list", ["include_sessions": false])
        return (r["profiles"]?.array ?? []).compactMap(Bot.init)
    }
}

/// Streaming events of one 1:1 turn, decoded from `{"method":"event","params":{"type","session_id","payload"}}`
/// frames (`tui_gateway/server.py:701-711`, payload models `tui_gateway/contracts/events.py:113-213`).
public enum ChatEvent: Sendable, Equatable {
    case started                                   // message.start (no payload)
    case delta(String)                             // message.delta {text, rendered?}
    case reasoning(String)                         // reasoning.delta / thinking.delta {text}
    case interim(String, alreadyStreamed: Bool)    // message.interim {text, already_streamed}
    case status(kind: String, text: String)        // status.update {kind, text}
    case completed(ChatCompletion)                 // message.complete
    case error(String)                             // error {message}
    case disconnected(String)                      // client-side: the socket is gone (token-free reason)
    case other(String)                             // anything else for this session_id
}

/// The `message.complete` fields the transcript needs to settle a turn
/// (`MessageCompletePayload`, `tui_gateway/contracts/events.py:189-213`; producer
/// `prompt_turn.py:930-975`).
public struct ChatCompletion: Sendable, Equatable {
    /// Final reply text: `payload.text` when it is a string, else `payload.rendered`, else nil (the
    /// streamed buffer is then the answer). `text` is `str | JsonValue` on the wire; this mirrors the
    /// TUI (`ui-tui/src/app/turnController.ts` `recordMessageComplete`).
    public var text: String?
    /// `complete | error | interrupted`; nil is treated as complete.
    public var status: String?
    public var error: String?
    /// The final text is the response already published as an interim (`prompt_turn.py:952-958`).
    public var responsePreviewed: Bool
    /// The final text is a response this turn already delivered; it adds no text (`events.py:200-201`).
    public var responseReused: Bool
    /// An output hook rewrote the final after streaming: it is the authoritative replacement even
    /// without a prefix relationship to what streamed (`prompt_turn.py:962-965`).
    public var responseTransformed: Bool

    public init(text: String?, status: String? = "complete", error: String? = nil,
                responsePreviewed: Bool = false, responseReused: Bool = false, responseTransformed: Bool = false) {
        self.text = text; self.status = status; self.error = error
        self.responsePreviewed = responsePreviewed; self.responseReused = responseReused
        self.responseTransformed = responseTransformed
    }

    init(payload p: JSONValue?) {
        self.init(text: p?["text"]?.string ?? p?["rendered"]?.string,
                  status: p?["status"]?.string, error: p?["error"]?.string,
                  responsePreviewed: p?["response_previewed"]?.bool ?? false,
                  responseReused: p?["response_reused"]?.bool ?? false,
                  responseTransformed: p?["response_transformed"]?.bool ?? false)
    }
}

/// A 1:1 chat with one bot over the gateway session API:
/// `session.create {profile, close_on_disconnect}` → `session.title` → `prompt.submit {session_id, text}`
/// → events routed to the creating socket → `session.close` + `session.delete` on teardown.
/// A dropped socket is reported as `ChatEvent.disconnected` (no reconnect in M1).
public final class BotChatSession: @unchecked Sendable {
    public let backend: Backend
    public let bot: Bot
    public let sessionId: String
    public let storedSessionId: String
    public let createInfo: JSONValue
    private var subscription: UUID?
    private var disconnectSubscription: UUID?
    private let lock = NSLock()
    private var handler: (@Sendable (ChatEvent) -> Void)?

    private init(backend: Backend, bot: Bot, result: JSONValue) {
        self.backend = backend
        self.bot = bot
        sessionId = result["session_id"]?.string ?? ""
        storedSessionId = result["stored_session_id"]?.string ?? ""
        createInfo = result["info"] ?? .null
    }

    /// Opens a live session for `bot` and names it.
    ///
    /// `session.create {profile, close_on_disconnect: true}` mints the live session (no DB row yet:
    /// rows are lazy until the first prompt, `methods_session.py:453-476`). The name is then written
    /// with `session.title {session_id, title}` BEFORE the first prompt: with no row, that persists
    /// the row now with `user` title provenance (`methods_session.py:1226-1254`,
    /// `hermes_state_titles.py:156-159`). Passing `title` to `session.create` instead only queues a
    /// `pending_title` applied after the turn, and the turn-start auto-titler then runs its LLM
    /// upgrade thread, which (observed, evidence/m1/attach-run1) re-created the row ~2 s after
    /// `session.delete`. A `user` title makes that thread return before any write
    /// (`agent/title_generator.py:563-571`, `auto_title_session` `:642-656`).
    /// `close_on_disconnect: true` reaps the live session when the socket drops
    /// (`session_lifecycle.py:1000-1017`).
    public static func open(_ backend: Backend, bot: Bot, title: String?) async throws -> BotChatSession {
        let r = try await backend.client.call("session.create", [
            "profile": .string(bot.name), "close_on_disconnect": true, "cols": 100,
        ])
        let s = BotChatSession(backend: backend, bot: bot, result: r)
        s.subscription = backend.subscribe(sessionId: s.sessionId) { [weak s] type, payload, _ in
            s?.deliver(type: type, payload: payload)
        }
        s.disconnectSubscription = backend.onDisconnect { [weak s] reason in s?.emit(.disconnected(reason)) }
        if let title, !title.isEmpty {
            s.titleResult = try await backend.client.call("session.title",
                                                          ["session_id": .string(s.sessionId), "title": .string(title)])
        }
        return s
    }

    /// `session.title` result when a title was set at open (`{title, pending}`).
    public private(set) var titleResult: JSONValue?

    public func onEvent(_ h: @escaping @Sendable (ChatEvent) -> Void) { lock.withLock { handler = h } }

    /// Returns the submit result (`status: "streaming"` for an idle session; `queued`/`steered`/
    /// `redirected` when a turn is already running, `contracts/prompt_voice.py:62-76`). The reply
    /// itself arrives as events.
    @discardableResult
    public func send(_ text: String) async throws -> JSONValue {
        try await backend.client.call("prompt.submit", ["session_id": .string(sessionId), "text": .string(text)])
    }

    public func interrupt() async throws {
        _ = try await backend.client.call("session.interrupt", ["session_id": .string(sessionId)])
    }

    /// `session.close` tears down the live session; `deleteStored` then removes the stored row and
    /// transcript (`session.delete` takes the STORED id and refuses while live, `methods_session.py:1181-1205`).
    /// Returned notes are token-free (`Redaction.describe`): they are printed and written to evidence.
    @discardableResult
    public func close(deleteStored: Bool) async -> [String] {
        var notes: [String] = []
        if let sub = subscription { backend.unsubscribe(sub); subscription = nil }
        if let sub = disconnectSubscription { backend.unsubscribe(sub); disconnectSubscription = nil }
        do {
            let r = try await backend.client.call("session.close", ["session_id": .string(sessionId)])
            notes.append("session.close → closed=\(r["closed"]?.bool ?? false)")
        } catch { notes.append("session.close failed: \(Redaction.describe(error))") }
        if deleteStored && !storedSessionId.isEmpty {
            do {
                let r = try await backend.client.call("session.delete", ["session_id": .string(storedSessionId),
                                                                         "profile": .string(bot.name)])
                notes.append("session.delete → deleted=\(r["deleted"]?.string ?? "?")")
            } catch { notes.append("session.delete failed: \(Redaction.describe(error))") }
        }
        return notes
    }

    private func deliver(type: String, payload: JSONValue?) {
        let e: ChatEvent
        switch type {
        case "message.start": e = .started
        case "message.delta": e = .delta(payload?["text"]?.string ?? "")
        case "reasoning.delta", "thinking.delta": e = .reasoning(payload?["text"]?.string ?? "")
        case "message.interim": e = .interim(payload?["text"]?.string ?? "", alreadyStreamed: payload?["already_streamed"]?.bool ?? false)
        case "status.update": e = .status(kind: payload?["kind"]?.string ?? "", text: payload?["text"]?.string ?? "")
        case "message.complete": e = .completed(ChatCompletion(payload: payload))
        case "error": e = .error(payload?["message"]?.string ?? "error")
        default: e = .other(type)
        }
        emit(e)
    }

    private func emit(_ e: ChatEvent) {
        let h = lock.withLock { handler }
        h?(e)
    }
}
