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
        return SchemaLog.array(r, "profiles", method: "profiles.list").compactMap(Bot.init)
    }
}

/// A 1:1 chat with one bot over the gateway session API. The app opens the bot's canonical "Bot Chat"
/// (`openCanonical`, CanonicalBotChat.swift: resume or create, never closed or deleted, teardown is
/// `detach()`); `open` (a throwaway titled session, `close(deleteStored:)` on teardown) is kept for the
/// harnesses. Events, server→client requests and the socket drop reach the ONE consumer set with
/// `onEvent` (single-consumer: a second `onEvent` is a programming error, asserted in debug); anything
/// that arrives between `attach()` and that call is buffered and flushed in order.
/// A dropped socket is reported as `ChatEvent.disconnected` (no reconnect).
public final class BotChatSession: @unchecked Sendable {
    public let backend: Backend
    public let bot: Bot
    /// The RUNTIME id events, requests and RPCs use. It changes only when the backend reclaimed the runtime
    /// and the canonical chat was resumed again (`session.reclaimed`, see `rebind`).
    public var sessionId: String { lock.withLock { _sessionId } }
    /// The stored (DB) id. Compression rotates it mid-conversation (`session_compression.py`
    /// `_sync_session_key_after_compress`); `session.info {stored_session_id}` reports the new one.
    public var storedSessionId: String { lock.withLock { _storedSessionId } }
    public let createInfo: JSONValue
    private var _sessionId: String
    private var _storedSessionId: String
    private var subscription: UUID?
    private var disconnectSubscription: UUID?
    /// Session-less broadcasts (`session.reclaimed` carries the runtime id in its payload only).
    private var globalSubscription: UUID?
    private var detached = false
    private var recovering = false
    /// `cols` the canonical chat was opened with (reused by the re-resume after a reclaim).
    var resumeCols = 100
    let lock = NSLock()
    private var handler: (@Sendable (ChatEvent) -> Void)?
    /// Events and requests that arrived before the first `onEvent` (flushed to it in order).
    private var buffered: [ChatEvent] = []
    private var consumerSet = false

    /// True for the profile's canonical "Bot Chat" (`openCanonical`): never closed, deleted or renamed.
    public let isCanonical: Bool
    /// Past messages returned when the session was opened (canonical resume); empty for a new session.
    public let history: [ChatHistoryMessage]
    /// Requests still waiting on this session when it was resumed (`open_requests`): show them as if just received.
    public let openRequests: [ServerRequest]
    /// The turn running when the chat was resumed (`running` / `status` / `inflight`), nil when idle.
    public let inflight: InflightTurn?
    private var requestSubscription: UUID?

    init(backend: Backend, bot: Bot, result: JSONValue, method: String = "session.create",
         canonical: Bool = false, storedFallback: String = "") throws {
        guard let sid = result["session_id"]?.string, !sid.isEmpty else {
            throw GatewayClient.ClientError.badFrame("\(method): no session_id")
        }
        self.backend = backend
        self.bot = bot
        _sessionId = sid
        // Optional: the stored row is lazy (created by the first prompt or `session.title`).
        _storedSessionId = result["stored_session_id"]?.string ?? storedFallback
        createInfo = result["info"] ?? .null
        isCanonical = canonical
        history = ChatHistoryMessage.decode(result["messages"])
        openRequests = (result["open_requests"]?.array ?? []).compactMap(ServerRequest.init(openRequest:))
        inflight = InflightTurn(resume: result)
    }

    /// Routes this session's events, server→client requests and the socket drop to `onEvent`. Frames the
    /// backend sent for this runtime before the open reply arrived are replayed first (`UnroutedHold`).
    func attach() {
        subscribeRuntime(sessionId)
        let drop = backend.onDisconnect { [weak self] reason in self?.emit(.disconnected(reason)) }
        let global = backend.subscribe(sessionId: "") { [weak self] type, payload, _ in
            guard type == "session.reclaimed" else { return }
            self?.reclaimed(payload)
        }
        let kept = lock.withLock { () -> Bool in
            guard !detached else { return false }
            disconnectSubscription = drop; globalSubscription = global
            return true
        }
        if !kept { [drop, global].forEach(backend.unsubscribe) }  // detached meanwhile: route nothing
    }

    /// Events and server→client requests keyed by the runtime id `sid`.
    private func subscribeRuntime(_ sid: String) {
        let fresh = subscribeTokens(sid)
        let kept = lock.withLock { () -> Bool in
            guard !detached else { return false }
            subscription = fresh[0]; requestSubscription = fresh[1]
            return true
        }
        if !kept { fresh.forEach(backend.unsubscribe) }  // detached meanwhile: route nothing
    }

    private func subscribeTokens(_ sid: String) -> [UUID] {
        let events = backend.subscribe(sessionId: sid) { [weak self] type, payload, _ in
            self?.deliver(type: type, payload: payload)
        }
        let requests = backend.onServerRequest(sessionId: sid) { [weak self] req in self?.emit(.request(req)) }
        return [events, requests]
    }

    /// Moves event + request routing to a new runtime id (the canonical chat was resumed again after the
    /// backend reclaimed the old runtime). The new id is subscribed BEFORE the old one is dropped, so no
    /// request of the new runtime meets an unrouted window. No-op once detached (also mid-rebind).
    func rebind(to sid: String, stored: String) {
        guard lock.withLock({ !detached }) else { return }
        let fresh = subscribeTokens(sid)
        let old = lock.withLock { () -> [UUID]? in
            guard !detached else { return nil }
            let old = [subscription, requestSubscription].compactMap { $0 }
            subscription = fresh[0]; requestSubscription = fresh[1]
            _sessionId = sid
            if !stored.isEmpty { _storedSessionId = stored }
            return old
        }
        (old ?? fresh).forEach(backend.unsubscribe)
    }

    /// Stops routing this session's events and requests to this client. Sends nothing: the session stays
    /// live for other clients and is reaped by the backend's own lifecycle (`session_lifecycle.py:1000-1058`).
    /// Requests buffered for a consumer that never came (`onEvent` not called yet) are declined `4404`
    /// like any request no window here shows (only when the backend advertised `declines_not_shown`).
    public func detach() {
        let (subs, unclaimed) = lock.withLock { () -> ([UUID], [ServerRequest]) in
            detached = true
            handler = nil
            let unclaimed = buffered.compactMap { e -> ServerRequest? in if case .request(let r) = e { return r }; return nil }
            buffered = []
            defer { subscription = nil; disconnectSubscription = nil; requestSubscription = nil; globalSubscription = nil }
            return ([subscription, disconnectSubscription, requestSubscription, globalSubscription].compactMap { $0 }, unclaimed)
        }
        subs.forEach(backend.unsubscribe)
        unclaimed.forEach { backend.requests.declineNotShown($0, client: backend.client) }
    }

    /// `session.reclaimed {session_id, stored_session_id, reason}` (broadcast): the backend reaped a runtime
    /// (idle TTL, LRU cap, orphan reap, `session_lifecycle.py:470-481`). When it is ours, the canonical chat
    /// is resumed at once on a new runtime id and routing moves there (Desktop `plugin.tsx` re-resumes the
    /// open Bot Chat the same way). Reported as `.other("session.reclaimed")`, then `.resumed(history:inflight:)`
    /// or an `.error` when the re-resume failed.
    private func reclaimed(_ payload: JSONValue?) {
        let sid = payload?["session_id"]?.string ?? ""
        let stored = payload?["stored_session_id"]?.string ?? ""
        let start = lock.withLock { () -> Bool in
            let ours = (!sid.isEmpty && sid == _sessionId) || (sid.isEmpty && !stored.isEmpty && stored == _storedSessionId)
            guard ours, !detached, !recovering else { return false }
            recovering = isCanonical
            return true
        }
        guard start else { return }
        emit(.other("session.reclaimed"))
        guard isCanonical else { return }
        Task { [weak self] in await self?.resumeAfterReclaim() }
    }

    private func resumeAfterReclaim() async {
        defer { lock.withLock { recovering = false } }
        do {
            guard let row = try await Self.lookupCanonical(backend, profile: bot.name) else {
                throw BotChatError.lookupFailed("Bot Chat not found")
            }
            let r = try await Self.resumeCall(backend, bot: bot, row: row, cols: resumeCols)
            guard let sid = r["session_id"]?.string, !sid.isEmpty else {
                throw GatewayClient.ClientError.badFrame("session.resume: no session_id")
            }
            rebind(to: sid, stored: r["stored_session_id"]?.string ?? row.openId)
            guard lock.withLock({ !detached }) else { return }
            // The consumer reseeds from the new reply exactly as on open (history, then a running turn).
            emit(.resumed(history: ChatHistoryMessage.decode(r["messages"]), inflight: InflightTurn(resume: r)))
            for req in (r["open_requests"]?.array ?? []).compactMap(ServerRequest.init(openRequest:)) { emit(.request(req)) }
        } catch {
            emit(.error("Hermes closed this Bot Chat's live session and it could not be reopened: \(Redaction.describe(error))"))
        }
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
    /// If anything fails after `session.create`, the created session is closed and deleted (best
    /// effort, token-free notes) before the original error is rethrown, so no session is orphaned.
    public static func open(_ backend: Backend, bot: Bot, title: String?) async throws -> BotChatSession {
        let r = try await backend.client.call("session.create", [
            "profile": .string(bot.name), "close_on_disconnect": true, "cols": 100,
        ])
        let s = try BotChatSession(backend: backend, bot: bot, result: r)
        s.attach()
        if let title, !title.isEmpty {
            do {
                s.titleResult = try await backend.client.call("session.title",
                                                              ["session_id": .string(s.sessionId), "title": .string(title)])
            } catch {
                await s.close(deleteStored: true)
                throw error
            }
        }
        return s
    }

    /// `session.title` result when a title was set at open (`{title, pending}`).
    public private(set) var titleResult: JSONValue?

    /// Sets the one consumer and flushes what arrived since `attach()`, in order, under the lock (so a
    /// concurrent `emit` waits and lands after the flush). `h` must not call back into this session
    /// synchronously; the app's handler only hops to the main queue.
    public func onEvent(_ h: @escaping @Sendable (ChatEvent) -> Void) {
        lock.withLock {
            assert(!consumerSet, "BotChatSession is single-consumer: onEvent was already set")
            consumerSet = true
            guard !detached else { return }
            handler = h
            let pending = buffered
            buffered = []
            pending.forEach(h)
        }
    }

    /// Returns the submit result (`status: "streaming"` for an idle session; `queued`/`steered`/
    /// `redirected` when a turn is already running, `contracts/prompt_voice.py:62-76`). The reply
    /// itself arrives as events.
    @discardableResult
    public func send(_ text: String) async throws -> JSONValue {
        do {
            return try await backend.client.call("prompt.submit", ["session_id": .string(sessionId), "text": .string(text)])
        } catch let e as GatewayClient.RPCError where e.code == BotChatError.sessionNotOwnedCode {
            throw BotChatError.sessionNotOwned(bot: bot.title)
        }
    }

    public func interrupt() async throws {
        _ = try await backend.client.call("session.interrupt", ["session_id": .string(sessionId)])
    }

    /// `approval.received {session_id, request_id}` → `acknowledged`: the approval card is on screen, so the
    /// backend starts its timeout clock (`contracts/prompt_voice.py:305-315`, `methods_prompt.py:1247-1255`).
    /// `requestId` is the approval QUEUE id (`ApprovalPrompt.requestId`), not the request frame id.
    @discardableResult
    public func approvalReceived(requestId: String) async throws -> Bool {
        let r = try await backend.client.call("approval.received", ["session_id": .string(sessionId),
                                                                    "request_id": .string(requestId)])
        return r["acknowledged"]?.bool ?? false
    }

    /// `session.close` tears down the live session; `deleteStored` then removes the stored row and
    /// transcript (`session.delete` takes the STORED id and refuses while live, `methods_session.py:1181-1205`).
    /// Returned notes are token-free (`Redaction.describe`): they are printed and written to evidence.
    /// The canonical Bot Chat is never closed or deleted: for it this only detaches (`session.close` is per
    /// runtime, not per client, and would end the chat for Hermes Desktop too, `methods_session.py:2202-2206`).
    @discardableResult
    public func close(deleteStored: Bool) async -> [String] {
        detach()
        if isCanonical { return ["canonical Bot Chat: detached only (no session.close / session.delete)"] }
        var notes: [String] = []
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
        // `thinking.delta` is spinner and provider-wait text, not reasoning: Desktop keeps it out of the
        // transcript (`message-stream.ts:243-252`), so it is not a Thought here either.
        case "reasoning.delta": e = .reasoning(payload?["text"]?.string ?? "")
        case "reasoning.available": e = .reasoningAvailable(payload?["text"]?.string ?? "")
        case "message.interim": e = .interim(payload?["text"]?.string ?? "", alreadyStreamed: payload?["already_streamed"]?.bool ?? false)
        case "status.update": e = .status(kind: payload?["kind"]?.string ?? "", text: payload?["text"]?.string ?? "")
        case "message.complete": e = .completed(ChatCompletion(payload: payload))
        case "session.info":
            // Compression rotates the stored id while the runtime id stays (`_sync_session_key_after_compress`).
            if let stored = payload?["stored_session_id"]?.string, !stored.isEmpty {
                lock.withLock { _storedSessionId = stored }
            }
            e = payload?["running"]?.bool == false ? .idle : .other(type)
        case "tool.generating": e = .toolGenerating(name: payload?["name"]?.string ?? "")
        case "tool.start": e = .toolStarted(ToolStart(payload: payload))
        case "tool.complete": e = .toolCompleted(ToolCompletion(payload: payload))
        case "request.cancel":
            e = .requestCancelled(id: payload?["id"]?.string ?? payload?["id"]?.compactJSON() ?? "",
                                  reason: payload?["reason"]?.string ?? "")
        case "approval.cancelled":
            e = .approvalsCancelled(requestIds: (payload?["request_ids"]?.array ?? []).compactMap(\.string))
        case "error": e = .error(payload?["message"]?.string ?? "error")
        default: e = .other(type)
        }
        emit(e)
    }

    func emit(_ e: ChatEvent) {
        let h = lock.withLock { () -> (@Sendable (ChatEvent) -> Void)? in
            if handler == nil && !detached && !consumerSet { buffered.append(e) }
            return handler
        }
        h?(e)
    }
}
