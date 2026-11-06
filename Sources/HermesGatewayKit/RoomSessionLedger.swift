import Foundation

// Durable record of the member-session keys a cleanup has PROVEN to be this card's.
//
// Deleting a member row does not end every writer of that id. The model title upgrade of a member's first
// turn runs in a daemon thread (`agent/title_generator.py:642-687`) that `session.close` does not wait for
// (`tui_gateway/session_lifecycle.py:568-584`, it joins the turn thread only). When its LLM call returns
// after the delete, the usage write `record_auxiliary_usage` first re-inserts the missing row as
// `source='unknown'` (`hermes_state_usage.py:388-391`, `_insert_session_row(session_id, "unknown")`), and
// the title persist then names it. The result is the SAME exact id in the same profile, `source=unknown`,
// `message_count=0`, an arbitrary `llm` title — which the `source == bot_room` provenance filter never
// sees again. So a key, once proven, is remembered here (backend scope, profile, exact id, room,
// evidence) and read back by exact id on every later round and audit, whatever its source or title.
//
// One JSON object per line; append-only. Entries are scoped by `scope` (which backend/home the key lives
// in: the rendezvous lock dir), so an isolated home's keys are never read back against the user install.

public struct SessionLedgerEntry: Sendable, Equatable {
    /// `proven` (owned by provenance, written BEFORE any close/delete), `deleted` (`session.delete` ok or
    /// 4007), `redeleted` (a re-created placeholder of a proven key deleted again), `imported_deleted`
    /// (taken from an earlier cleanup report's `deleted` list; `origin` names the report).
    public let event: String
    public let scope: String
    public let profile: String
    public let id: String
    public let roomId: String
    public let evidence: String
    public let origin: String
    public let at: Double

    public init(event: String, scope: String, profile: String, id: String, roomId: String, evidence: String,
                origin: String = "", at: Double = Date().timeIntervalSince1970) {
        self.event = event; self.scope = scope; self.profile = profile; self.id = id; self.roomId = roomId
        self.evidence = evidence; self.origin = origin; self.at = at
    }

    public init?(_ v: JSONValue) {
        guard let event = v["event"]?.string, let scope = v["scope"]?.string, let profile = v["profile"]?.string,
              let id = v["id"]?.string, !profile.isEmpty, !id.isEmpty else { return nil }
        self.init(event: event, scope: scope, profile: profile, id: id, roomId: v["room_id"]?.string ?? "",
                  evidence: v["evidence"]?.string ?? "", origin: v["origin"]?.string ?? "", at: v["at"]?.double ?? 0)
    }

    public var key: String { "\(profile):\(id)" }

    public var json: JSONValue {
        ["event": .string(event), "scope": .string(scope), "profile": .string(profile), "id": .string(id),
         "room_id": .string(roomId), "evidence": .string(evidence), "origin": .string(origin), "at": .number(at)]
    }

    public func with(event: String, at: Double = Date().timeIntervalSince1970) -> SessionLedgerEntry {
        .init(event: event, scope: scope, profile: profile, id: id, roomId: roomId, evidence: evidence, origin: origin, at: at)
    }
}

public enum SessionLedger {
    /// Appends and flushes one line (a failed write must stop the caller from deleting: see the cleaner).
    public static func append(_ entry: SessionLedgerEntry, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((entry.json.compactJSON() + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
        try h.synchronize()
    }

    /// A missing file is an empty ledger; a present but unreadable one throws.
    public static func load(_ url: URL) throws -> [SessionLedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))).flatMap(SessionLedgerEntry.init)
        }
    }

    /// One entry per proven key (its first record) in `scope`, optionally only for `rooms`.
    public static func keys(_ entries: [SessionLedgerEntry], scope: String, rooms: Set<String>? = nil) -> [SessionLedgerEntry] {
        var seen = Set<String>()
        return entries.filter { $0.scope == scope && (rooms?.contains($0.roomId) ?? true) && seen.insert($0.key).inserted }
    }
}

/// Where the cleaner writes ledger records. Throwing means "not recorded": the cleaner then does not
/// delete that key (a deleted key nobody remembers is exactly how a re-created key would be missed).
public protocol SessionLedgerRecorder: Sendable {
    func record(_ entry: SessionLedgerEntry) throws
}

public struct FileSessionLedger: SessionLedgerRecorder {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func record(_ entry: SessionLedgerEntry) throws { try SessionLedger.append(entry, to: url) }
}
