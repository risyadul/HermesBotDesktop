import Foundation

/// E4 / D17: Hermes Desktop's own group chats, read once and kept as a read-only archive.
///
/// Desktop runs its group chats client-side (not the backend's hosted `groups.*` rooms). Besides its plugin
/// storage it publishes a bounded, display-only copy of every room into the DEFAULT profile's
/// `ui_meta["hermes-bots-groups"]` (`apps/desktop/src/plugins/hermes-bots/group-chat.ts`,
/// `groupChatSyncSnapshot`), which `profiles.list` returns. That projection (v3) is:
///
///     { version: 3, updatedAt, rooms: { "<id:roomId | name:name>": {
///         name, roomId?, revision?, omitted?, holdDetection?, image?,
///         members: [{name, handle?, connectionId?, connectionKind?, connectionLabel?, sourceScoped?}],
///         log: [{id?, from: {kind: "member"|"user", name, source?}, text, at (ms), thread?, truncated?}] } },
///       deleted?: { "<key>": revision } }
///
/// with the last 16 messages per room, 1200 characters per message, ~48 KB in all. v1/v2 snapshots key rooms
/// by name. This parser only reads: it never writes `ui_meta` and never creates rooms. The input is another
/// app's data, so every field is checked and capped again here (`parse`), whatever Desktop promised.
public struct DesktopArchiveMember: Sendable, Hashable, Codable {
    /// The member's profile name on the Desktop that seated it.
    public let name: String
    public let handle: String?
    /// Desktop's label for the member's connection (a remote gateway), display-only.
    public let connectionLabel: String?

    public init(name: String, handle: String? = nil, connectionLabel: String? = nil) {
        self.name = name; self.handle = handle; self.connectionLabel = connectionLabel
    }
}

public struct DesktopArchiveMessage: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let fromUser: Bool
    public let author: String
    public let text: String
    public let at: Date?
    public let thread: String?
    /// Cut to the sync budget, by Desktop or by this parser.
    public let truncated: Bool

    public init(id: String, fromUser: Bool, author: String, text: String, at: Date?, thread: String? = nil,
                truncated: Bool = false) {
        self.id = id; self.fromUser = fromUser; self.author = author; self.text = text; self.at = at
        self.thread = thread; self.truncated = truncated
    }
}

public struct DesktopArchiveRoom: Sendable, Hashable, Codable, Identifiable {
    /// The projection's room key (`id:<roomId>` or `name:<name>`): stable across renames on Desktop.
    public let id: String
    public let name: String
    public let members: [DesktopArchiveMember]
    public let messages: [DesktopArchiveMessage]
    /// At least this many earlier messages exist that the projection does not carry.
    public let omitted: Int

    public var lastAt: Date? { messages.last?.at }

    public init(id: String, name: String, members: [DesktopArchiveMember], messages: [DesktopArchiveMessage], omitted: Int) {
        self.id = id; self.name = name; self.members = members; self.messages = messages; self.omitted = omitted
    }
}

public enum DesktopGroupArchive {
    public static let metaKey = "hermes-bots-groups"
    public static let maxRooms = 64
    public static let maxMessages = 16
    public static let maxTextChars = 1200
    public static let maxMembers = 6
    public static let truncationMark = "… [truncated]"
    public static let maxNameChars = 64
    static let maxLabelChars = 128
    static let maxIdChars = 160
    /// A `ui_meta` value delivered as a JSON string is decoded only up to this size.
    static let maxEncodedBytes = 256 * 1024
    /// Timestamps outside 1970…3000 are treated as unknown.
    static let maxMillis: Double = 32_503_680_000_000

    public typealias Call = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// `profiles.list` (read-only) → the default profile's Desktop group chats.
    public static func load(call: Call) async throws -> [DesktopArchiveRoom] {
        rooms(profilesList: try await call("profiles.list", ["include_sessions": false]))
    }

    /// The default profile's row (`is_default`, else the one named `default`) → its parsed rooms.
    public static func rooms(profilesList: JSONValue) -> [DesktopArchiveRoom] {
        let rows = SchemaLog.array(profilesList, "profiles", method: "profiles.list")
        let row = rows.first(where: { $0["is_default"]?.bool == true }) ?? rows.first(where: { $0["name"]?.string == "default" })
        return parse(row?["ui_meta"]?[metaKey])
    }

    /// The projection → rooms, newest activity first. Malformed rooms and messages are skipped; sizes are
    /// capped (rooms, members, messages, characters) so an oversized or hostile value stays bounded.
    public static func parse(_ value: JSONValue?) -> [DesktopArchiveRoom] {
        guard let snapshot = decoded(value), let rooms = snapshot["rooms"]?.object else { return [] }
        let version = snapshot["version"]?.double ?? 0
        let deleted = version >= 3 ? (snapshot["deleted"]?.object ?? [:]) : [:]
        var out: [DesktopArchiveRoom] = []
        for (rawKey, raw) in rooms {
            let key = version >= 3 ? rawKey : "name:\(rawKey)"
            guard let room = raw.object, key.count <= maxIdChars + 5 else { continue }
            let revision = room["revision"]?.double ?? 0
            if let gone = deleted[key]?.double, gone >= revision { continue }  // Desktop's tombstone rule
            let fallbackName = version >= 3 ? (key.hasPrefix("name:") ? String(key.dropFirst(5)) : "") : rawKey
            if let parsed = parseRoom(key: key, room, fallbackName: fallbackName) { out.append(parsed) }
        }
        out.sort { ($0.lastAt ?? .distantPast, $0.id) > ($1.lastAt ?? .distantPast, $1.id) }
        return Array(out.prefix(maxRooms))
    }

    static func decoded(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .object?: return value
        case .string(let s)? where s.utf8.count <= maxEncodedBytes:
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)), v.object != nil else { return nil }
            return v
        default: return nil
        }
    }

    static func parseRoom(key: String, _ room: [String: JSONValue], fallbackName: String) -> DesktopArchiveRoom? {
        guard let log = room["log"]?.array else { return nil }
        var messages: [DesktopArchiveMessage] = []
        var ids = Set<String>()
        for (index, entry) in log.enumerated() {
            guard let m = parseMessage(entry, fallbackId: "\(key)#\(index)") else { continue }
            let id = ids.contains(m.id) ? "\(m.id)#\(index)" : m.id
            ids.insert(id)
            messages.append(DesktopArchiveMessage(id: id, fromUser: m.fromUser, author: m.author, text: m.text,
                                                  at: m.at, thread: m.thread, truncated: m.truncated))
        }
        guard !messages.isEmpty else { return nil }
        let dropped = max(0, messages.count - maxMessages)
        messages = Array(messages.suffix(maxMessages))
        let omitted = max(0, room["omitted"]?.int ?? 0) + dropped
        var seen = Set<String>()
        let members: [DesktopArchiveMember] = (room["members"]?.array ?? []).compactMap { m in
            guard let name = text(m["name"], max: maxLabelChars), seen.insert(name).inserted else { return nil }
            return DesktopArchiveMember(name: name, handle: text(m["handle"], max: maxLabelChars),
                                        connectionLabel: text(m["connectionLabel"], max: maxLabelChars))
        }
        let name = text(room["name"], max: maxNameChars) ?? text(.string(fallbackName), max: maxNameChars) ?? "Untitled group chat"
        return DesktopArchiveRoom(id: key, name: name, members: Array(members.prefix(maxMembers)),
                                  messages: messages, omitted: min(omitted, 1_000_000))
    }

    static func parseMessage(_ entry: JSONValue, fallbackId: String) -> DesktopArchiveMessage? {
        guard entry.object != nil, let raw = entry["text"]?.string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fromUser = entry["from"]?["kind"]?.string != "member"
        let author = text(entry["from"]?["name"], max: maxLabelChars) ?? (fromUser ? "You" : "Bot")
        var body = raw
        var truncated = entry["truncated"]?.bool == true
        if body.count > maxTextChars {
            body = String(body.prefix(maxTextChars - truncationMark.count)) + truncationMark
            truncated = true
        }
        var at: Date?
        if let ms = entry["at"]?.double, ms.isFinite, ms > 0, ms < maxMillis { at = Date(timeIntervalSince1970: ms / 1000) }
        let id = entry["id"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(maxIdChars)) } ?? fallbackId
        return DesktopArchiveMessage(id: id, fromUser: fromUser, author: author, text: body, at: at,
                                     thread: text(entry["thread"], max: maxLabelChars), truncated: truncated)
    }

    /// A short label from another app: trimmed, capped, hidden characters shown (`VisibleText`); nil if empty.
    static func text(_ v: JSONValue?, max: Int) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let line = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return VisibleText.reveal(String(line.prefix(max)))
    }
}
