import Foundation

/// One session summary a `profiles.list {include_sessions: true}` row carries (`methods_profiles.py`
/// `_profile_session_fields`: `last_session`, `canonical_session`, `worker_session`). Times are epoch seconds.
public struct BotSessionSummary: Sendable, Equatable {
    public let id: String
    /// `canonical_session.resolved_id`: the live compression tip of the Bot Chat (nil for the other two).
    public let resolvedId: String?
    public let title: String
    public let preview: String
    public let lastActive: Double

    public init(id: String, resolvedId: String? = nil, title: String = "", preview: String = "", lastActive: Double = 0) {
        self.id = id; self.resolvedId = resolvedId; self.title = title; self.preview = preview; self.lastActive = lastActive
    }

    init?(_ v: JSONValue?) {
        guard let v, let id = v["id"]?.string?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        self.init(id: id, resolvedId: v["resolved_id"]?.string, title: v["title"]?.string ?? "",
                  preview: v["preview"]?.string ?? "",
                  lastActive: v["last_active"]?.double ?? v["started_at"]?.double ?? 0)
    }
}

/// What a bot's sidebar row knows about its conversations (A4, A17), read from ONE `profiles.list
/// {include_sessions: true}` call for every bot at once, never by opening a chat. The rules are Hermes
/// Desktop's, so both apps order, preview and badge a bot the same way:
/// - activity: the newer of the canonical Bot Chat and the newest listed session (`botActivitySession`);
/// - preview: the Bot Chat's, else the newest session's (`bot-row.tsx`: preview identity = click identity);
/// - age: the newest of that activity and a kanban/tool worker run (`rowAgeTs`);
/// - recent session: the newest listed session, which never is the Bot Chat (`recent-session.ts`).
public struct BotRosterActivity: Sendable, Equatable {
    public let canonical: BotSessionSummary?
    public let last: BotSessionSummary?
    public let worker: BotSessionSummary?

    public init(canonical: BotSessionSummary? = nil, last: BotSessionSummary? = nil, worker: BotSessionSummary? = nil) {
        self.canonical = canonical; self.last = last; self.worker = worker
    }

    public init(row: JSONValue) {
        self.init(canonical: BotSessionSummary(row["canonical_session"]), last: BotSessionSummary(row["last_session"]),
                  worker: BotSessionSummary(row["worker_session"]))
    }

    /// Desktop `botActivitySession`: the Bot Chat or the newest listed session, whichever moved last.
    public var activitySession: BotSessionSummary? {
        guard let canonical, let last else { return canonical ?? last }
        return canonical.lastActive >= last.lastActive ? canonical : last
    }

    /// When the bot last had a message in any of its conversations (seconds; 0 = never). The unread
    /// watermark and the sort follow this.
    public var lastActive: Double { activitySession?.lastActive ?? 0 }

    /// The row's age stamp: the last time the bot did anything, a worker run included (seconds; 0 = never).
    public var ageStamp: Double { max(lastActive, worker?.lastActive ?? 0) }

    /// The row's last-message line, or nil when there is none yet.
    public var preview: BotPreview? { BotPreview((canonical ?? last)?.preview ?? "") }

    /// "Open Recent Session": the newest listed session. The canonical Bot Chat is hidden from that listing
    /// server-side; a row that still names it (an older gateway) is refused here, so the item never reopens
    /// the chat the row click already opens.
    public var recentSession: BotSessionSummary? {
        guard let last else { return nil }
        if let canonical, last.id == canonical.id || last.id == canonical.resolvedId { return nil }
        return last
    }

    /// Desktop's roster order key (`sortRosterBots`): the newest of the bot's creation (ms, from `ui_meta`)
    /// and its last message, in milliseconds.
    public static func sortKey(lastActive: Double, created: Double?) -> Double {
        max(created ?? 0, lastActive * 1000)
    }

    /// Every bot's activity by profile name: one `profiles.list {include_sessions: true}`.
    public static func fetch(_ call: BotMetaSync.Call) async throws -> [String: BotRosterActivity] {
        let r = try await call("profiles.list", ["include_sessions": true])
        var out: [String: BotRosterActivity] = [:]
        for row in r["profiles"]?.array ?? [] {
            guard let name = row["name"]?.string else { continue }
            out[name] = BotRosterActivity(row: row)
        }
        return out
    }
}

/// A row's last-message line: whitespace folded to one line, a bot-to-bot delivery prefix
/// ("Message from 🤖 name (@handle): …" or "Message from agent 'name': …") stripped and its sender kept,
/// like Desktop's `previewKind` / `A2A_PREFIX_RE`, so a DM from another bot reads like a DM.
public struct BotPreview: Sendable, Equatable {
    public let text: String
    /// The profile name of the bot that sent it, when it was a bot-to-bot message.
    public let fromBot: String?

    public static let limit = 140

    public init(text: String, fromBot: String? = nil) { self.text = text; self.fromBot = fromBot }

    public init?(_ raw: String) {
        var flat = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        var sender: String?
        if let m = flat.firstMatch(of: Self.a2a) {
            sender = String(m.output.1 ?? m.output.2 ?? "").lowercased()
            flat = String(flat[m.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if flat.isEmpty { flat = "…" }
        }
        flat = Self.stripMarkdown(flat)
        if flat.count > Self.limit { flat = String(flat.prefix(Self.limit - 1)) + "…" }
        self.init(text: flat, fromBot: sender.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `Message from agent 'name':` or `Message from 🤖 name (@handle):` at the start, case-insensitive
    /// (Desktop `A2A_RE` for the sender, `A2A_PREFIX_RE` for what is stripped).
    static var a2a: Regex<(Substring, Substring?, Substring?)> {
        #/(?i)^Message from (?:agent '([^']+)'|🤖\s*([^\s(@:]+)[^:]*):\s*/#
    }

    /// Inline emphasis, code ticks and heading marks: a one-line preview shows the words, not the syntax.
    static func stripMarkdown(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        while out.hasPrefix("#") { out.removeFirst() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
