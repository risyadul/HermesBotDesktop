import Foundation

/// The bot's one forever chat: the session titled exactly "Bot Chat" on its profile, shared with Hermes
/// Desktop (`.omc/research/wire-parity.md` §1; Desktop `plugins/hermes-bots/canonical-chat.ts`).
///
/// Identity is the TITLE (`hermes_state.py:1610`, DB `UNIQUE(title)`), never a pinned id. Open =
/// 1. `session.list {profile, title:"Bot Chat", include_hidden:true, limit:200}` — exact, window-free
///    lookup (`methods_session.py:522-555`). A failed lookup fails closed (`canonical-chat.ts:282-319`).
/// 2. Found → cold `session.resume {session_id: resolved_id||id, profile, cols, source:"desktop",
///    close_on_disconnect:false, inline_images:false}` (`contracts/sessions.py:183-195`); the reply's
///    `session_id` is the runtime id and `messages` the history. 4007/4009 ("retry resume") retry once.
/// 3. Empty → confirm absence against `profiles.list` `canonical_session` (`methods_profiles.py:160-193`;
///    Desktop fails closed the same way, `canonical-chat.ts:328-338`), then
///    `session.create {profile, title:"Bot Chat", hidden:true, follow_profile_config:true,
///    close_on_disconnect:false, source:"desktop", cols}` and at once `session.title {session_id, title}`
///    to materialize the row (`canonical-chat.ts:468-511`). 4022 "already in use" → look up again and
///    adopt the winner; the stray lazy session is abandoned (pruned by the backend).
///    `source:"desktop"` keeps the DB row alive through automatic cleanup (`session_lifecycle.py:60,363-367`).
/// No kickoff prompt; teardown is `detach()` (never `session.close` / `session.delete` / rename).
extension BotChatSession {
    public static let canonicalTitle = "Bot Chat"
    static let lookupLimit = 200
    static let titleInUseCode = 4022
    static let retryResumeCodes: Set<Int> = [4007, 4009]

    /// Opens (resumes or, only when confirmed absent, creates) `bot`'s canonical Bot Chat. Concurrent
    /// opens for the same backend + profile share one flight, so a double click cannot mint twice.
    public static func openCanonical(_ backend: Backend, bot: Bot, cols: Int = 100) async throws -> BotChatSession {
        try await CanonicalFlight.shared.run(key: CanonicalFlight.Key(backend: ObjectIdentifier(backend), profile: bot.name)) {
            try await openCanonicalOnce(backend, bot: bot, cols: cols)
        }
    }

    private static func openCanonicalOnce(_ backend: Backend, bot: Bot, cols: Int) async throws -> BotChatSession {
        if let row = try await lookupCanonical(backend, profile: bot.name) {
            return try await resumeCanonical(backend, bot: bot, row: row, cols: cols)
        }
        try await confirmAbsent(backend, bot: bot)
        let created = try await backend.client.call("session.create", [
            "profile": .string(bot.name), "title": .string(canonicalTitle), "hidden": true,
            "follow_profile_config": true, "close_on_disconnect": false, "source": "desktop",
            "cols": .number(Double(cols)),
        ])
        let s = try BotChatSession(backend: backend, bot: bot, result: created, canonical: true)
        s.resumeCols = cols
        do {
            _ = try await backend.client.call("session.title", ["session_id": .string(s.sessionId),
                                                                "title": .string(canonicalTitle)])
        } catch let e as GatewayClient.RPCError
                    where e.code == titleInUseCode || e.message.localizedCaseInsensitiveContains("already in use") {
            // Another writer took the title between our miss and this write: adopt the winner.
            guard let winner = try await lookupCanonical(backend, profile: bot.name) else {
                throw BotChatError.lookupFailed("title in use but no Bot Chat found")
            }
            return try await resumeCanonical(backend, bot: bot, row: winner, cols: cols)
        } catch is GatewayClient.RPCError {
            // Older gateway without the eager title: the first prompt persists the row with `pending_title`.
        }
        s.attach()
        return s
    }

    /// A `session.list` title-lookup row: `id` is the registry identity, `resolved_id` the lineage tip to open.
    struct CanonicalRow: Equatable {
        let id: String
        let resolvedId: String?
        var openId: String { resolvedId.flatMap { $0.isEmpty ? nil : $0 } ?? id }
    }

    /// Exact title lookup. Throws `lookupFailed` on any error (never read a failure as "no chat").
    static func lookupCanonical(_ backend: Backend, profile: String) async throws -> CanonicalRow? {
        let r: JSONValue
        do {
            r = try await backend.client.call("session.list", [
                "profile": .string(profile), "title": .string(canonicalTitle),
                "include_hidden": true, "limit": .number(Double(lookupLimit)),
            ])
        } catch {
            throw BotChatError.lookupFailed(Redaction.describe(error))
        }
        guard let rows = r["sessions"]?.array else { throw BotChatError.lookupFailed("session.list: no sessions array") }
        // Desktop `isCanonicalBotChatHistory`: the lineage root's title, else the row's title.
        let match = rows.first { row in
            let root = row["root_title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            let title = row["title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return root == canonicalTitle || (root.isEmpty && title == canonicalTitle)
        }
        guard let match else { return nil }
        // A row that matches the title but carries no identity is a malformed reply, not an absence.
        guard let id = match["id"]?.string, !id.isEmpty else {
            throw BotChatError.lookupFailed("session.list: Bot Chat row without an id")
        }
        return CanonicalRow(id: id, resolvedId: match["resolved_id"]?.string)
    }

    /// An empty lookup is only "absent" when the roster lists the bot and does not still report a canonical
    /// chat for it. Fails closed: a missing `profiles` array or bot row throws `lookupFailed`, and a
    /// `canonical_session` that is neither absent/null nor an object with an id is unconfirmed. Only a
    /// missing or null `canonical_session` (older gateways omit it; Desktop reads `canonical_session?.id`)
    /// confirms absence.
    private static func confirmAbsent(_ backend: Backend, bot: Bot) async throws {
        let r: JSONValue
        do { r = try await backend.client.call("profiles.list", ["include_sessions": true]) } catch {
            throw BotChatError.lookupFailed(Redaction.describe(error))
        }
        guard let profiles = r["profiles"]?.array else {
            throw BotChatError.lookupFailed("profiles.list: no profiles array")
        }
        guard let row = profiles.first(where: { $0["name"]?.string == bot.name }) else {
            throw BotChatError.lookupFailed("profiles.list: \(bot.name) is not listed")
        }
        // A listed canonical chat (any id) or a malformed entry: either way absence is not confirmed.
        if let canonical = row["canonical_session"], canonical != .null {
            throw BotChatError.absenceUnconfirmed(bot: bot.title)
        }
    }

    private static func resumeCanonical(_ backend: Backend, bot: Bot, row: CanonicalRow, cols: Int) async throws -> BotChatSession {
        let r = try await resumeCall(backend, bot: bot, row: row, cols: cols)
        let s = try BotChatSession(backend: backend, bot: bot, result: r, method: "session.resume",
                                   canonical: true, storedFallback: row.openId)
        s.resumeCols = cols
        s.attach()
        // Images an earlier submit staged but could not take back before the socket dropped.
        await s.detachStranded()
        return s
    }

    /// Cold `session.resume` of the lineage tip; 4007/4009 ("retry resume") retry once.
    static func resumeCall(_ backend: Backend, bot: Bot, row: CanonicalRow, cols: Int) async throws -> JSONValue {
        let params: JSONValue = [
            "session_id": .string(row.openId), "profile": .string(bot.name), "cols": .number(Double(cols)),
            "source": "desktop", "close_on_disconnect": false, "inline_images": false,
        ]
        do {
            return try await backend.client.call("session.resume", params)
        } catch let e as GatewayClient.RPCError where retryResumeCodes.contains(e.code) {
            try await Task.sleep(nanoseconds: 500_000_000)
            return try await backend.client.call("session.resume", params)
        }
    }
}

/// Single-flight per key: callers that arrive while an open runs await the same result — the SAME
/// `BotChatSession` instance. A session is single-consumer (one `onEvent`, asserted in debug; `detach` ends
/// it for everyone), so the app keeps exactly one consumer per bot: `AppModel.chat(for:)` makes one
/// `ChatModel` per bot and `ChatModel.open` never runs twice concurrently. The flight only guards against
/// minting the chat twice.
actor CanonicalFlight {
    /// The backend object itself (not its hash, which can collide) plus the profile.
    struct Key: Hashable { let backend: ObjectIdentifier; let profile: String }
    static let shared = CanonicalFlight()
    private var inFlight: [Key: Task<BotChatSession, Error>] = [:]

    func run(key: Key, _ body: @escaping @Sendable () async throws -> BotChatSession) async throws -> BotChatSession {
        if let t = inFlight[key] { return try await t.value }
        let t = Task { try await body() }
        inFlight[key] = t
        defer { inFlight[key] = nil }
        return try await t.value
    }
}

/// Typed chat failures with token-free, user-facing text.
public enum BotChatError: Error, RedactionSafeError, Equatable {
    /// `prompt.submit` error 4090 `{reason: "SESSION_NOT_OWNED"}`: another backend process holds the
    /// session's active lease (`methods_prompt.py:774-777`, `session_lifecycle.py:120-136`).
    case sessionNotOwned(bot: String)
    /// The "Bot Chat" registry lookup failed or could not confirm absence: never mint a new chat then.
    case lookupFailed(String)
    /// An empty lookup while the profile roster still reports a canonical chat (Desktop
    /// `canonical-chat.ts:328-338`): unconfirmed absence.
    case absenceUnconfirmed(bot: String)

    static let sessionNotOwnedCode = 4090

    public var description: String {
        switch self {
        case .sessionNotOwned(let bot):
            return "\(bot)'s Bot Chat is running in another Hermes app. Open it in the Hermes app that runs it."
        case .lookupFailed(let why): return "Could not check the Bot Chat registry (\(why)); not starting a new chat. Try again."
        case .absenceUnconfirmed(let bot):
            return "Could not confirm \(bot)'s Bot Chat; not starting a new chat. Try again."
        }
    }
}
