import Foundation

// Cleanup of the hidden member sessions of test rooms (review BLOCK-003).
//
// Each room member runs in a hidden session of its own profile (`source=bot_room`), created by the
// room driver with the title `Group: <room_id>` (`tui_gateway/hosted_room_driver.py:877-885,905-907`,
// `hosted_room_server_rpc.py:59-62`). That title is NOT a reliable identity while the first turn runs:
// `session.create` only queues it as `pending_title`; at turn start the agent writes an instant
// `derived` title from the first line of the prompt (`agent/title_generator.py:343-354,621-636`,
// ≤48 chars + "…"), possibly upgraded by the title model (`llm`); `pending_title` is written with `user`
// authority only after a `complete` turn (`prompt_turn.py:384-409`). A live row reports the DB title
// first and `pending_title` only as a fallback (`server.py:3055-3059`). So during (and after a stopped)
// first turn the stored and live title can be `[Discussion: "<room name>"] You are…`, an LLM title, or
// empty.
//
// Ownership is therefore proven from the stored row itself, never from a generic prefix:
//  - `title == "Group: <room_id>"` for a room of the manifest (the driver's own identity), with the row's
//    profile a member of that room, or
//  - the row's first user message (`preview`, head of the first user message, ≤60 chars,
//    `hermes_state_common.py:26-31,148-166`) or its derived title is a prefix of the exact opening the
//    driver builds for that room and member (`gateway/hosted_room_discussion.py:518-530`):
//    `[Discussion: "<name>"] You are @<handle>, one participant with <peers> and the user.`
//    with the whole quoted name visible, the row's profile equal to that member's profile, the row
//    started after the room was created, and no other room (manifest or live) with the same name;
//  - and nothing on the row points elsewhere (another room's `Group:` title or opening, or a preview that
//    is no room opening → `conflicting_provenance`).
// A member profile's bot_room row from the test window with no positive proof either way (empty, or an
// llm/user title that names no room, `agent/title_generator.py:642-687`) is `unresolved`, not absent.
// Live runtimes (`session.active_list`: no profile/source) are owned only through the `session_key` of
// an owned stored row, and only when exactly one runtime holds it, the live title agrees, and an EXACT
// per-profile lookup of that id (`RoomSessionGateway.storedIdPresence`, no listing filters) proves it is
// stored in the owning profile and in no other profile of the install (`server.py:3090-3097`: stored ids
// repeat across profiles). `session.list` is a filtered human listing (denied sources, archived, children,
// window), so a row missing from it proves nothing about uniqueness.
// Anything that cannot be proven is `unresolved`: never touched, and it makes the cleanup fail.

/// What a test run recorded about one room it created: enough to recognise the room's member sessions
/// after the room is disbanded (`groups.list` no longer shows it then).
public struct RoomManifestEntry: Sendable, Equatable {
    public let roomId: String
    public let name: String
    public let createdAt: Double
    public let members: [RoomMember]

    public init(roomId: String, name: String, createdAt: Double, members: [RoomMember]) {
        self.roomId = roomId; self.name = name; self.createdAt = createdAt; self.members = members
    }

    public init(room: RoomSummary) {
        self.init(roomId: room.roomId, name: room.name, createdAt: room.createdAt, members: room.members)
    }

    public init?(_ v: JSONValue) {
        guard let id = v["room_id"]?.string, let name = v["name"]?.string else { return nil }
        self.init(roomId: id, name: name, createdAt: v["created_at"]?.double ?? 0,
                  members: (v["members"]?.array ?? []).compactMap(RoomMember.init))
    }

    public var json: JSONValue {
        ["room_id": .string(roomId), "name": .string(name), "created_at": .number(createdAt),
         "members": .array(members.map(\.json))]
    }

    public var canonicalTitle: String { "Group: \(roomId)" }

    /// `[Discussion: "<name>"]` — the part of the opening that names the room.
    public var namePrefix: String { "[Discussion: \"\(name)\"]" }

    /// First line of every prompt the driver sends to `member` in this room
    /// (`hosted_room_discussion.py:_build_prompt`, peers in roster order).
    public func opening(for member: RoomMember) -> String {
        let peers = members.filter { $0.memberId != member.memberId }.map { "@\($0.handle)" }.joined(separator: ", ")
        return "[Discussion: \"\(name)\"] You are @\(member.handle), one participant with \(peers.isEmpty ? "no other members" : peers) and the user."
    }

    /// The opening plus the next line, as one whitespace-collapsed string (what a preview can show).
    func openingText(for member: RoomMember) -> String {
        RoomSessionClassifier.collapse(opening(for: member) + "\n\nNew messages in this thread since your last turn (oldest first):")
    }
}

/// JSON-lines manifest file (one `RoomManifestEntry.json` per line; later lines win per room id).
public enum RoomManifest {
    public static func append(_ entry: RoomManifestEntry, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((entry.json.compactJSON() + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    public static func load(_ url: URL) throws -> [RoomManifestEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var byId: [String: RoomManifestEntry] = [:], order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let e = RoomManifestEntry(v) else { continue }
            if byId[e.roomId] == nil { order.append(e.roomId) }
            byId[e.roomId] = e
        }
        return order.compactMap { byId[$0] }
    }
}

/// One `session.list {profile, include_hidden: true}` row.
public struct StoredSessionRow: Sendable, Equatable {
    public let profile: String
    public let id: String
    public let title: String
    public let preview: String
    public let source: String
    public let startedAt: Double

    public init(profile: String, id: String, title: String = "", preview: String = "", source: String = "bot_room", startedAt: Double = 0) {
        self.profile = profile; self.id = id; self.title = title; self.preview = preview; self.source = source; self.startedAt = startedAt
    }

    public init?(profile: String, _ v: JSONValue) {
        guard let id = v["id"]?.string else { return nil }
        self.init(profile: profile, id: id, title: v["title"]?.string ?? "", preview: v["preview"]?.string ?? "",
                  source: v["source"]?.string ?? "", startedAt: v["started_at"]?.double ?? 0)
    }

    public var key: String { "\(profile):\(id)" }
}

/// One `session.active_list` row of the attached backend (`server.py:3062-3083`).
public struct LiveSessionRow: Sendable, Equatable {
    public let runtimeId: String
    public let sessionKey: String
    public let title: String
    public let status: String

    public init(runtimeId: String, sessionKey: String, title: String = "", status: String = "idle") {
        self.runtimeId = runtimeId; self.sessionKey = sessionKey; self.title = title; self.status = status
    }

    public init?(_ v: JSONValue) {
        guard let id = v["id"]?.string else { return nil }
        self.init(runtimeId: id, sessionKey: v["session_key"]?.string ?? "", title: v["title"]?.string ?? "",
                  status: v["status"]?.string ?? "")
    }
}

/// The result of one discovery pass.
public struct RoomSessionDiscovery: Sendable, Equatable {
    public struct OwnedStored: Sendable, Equatable {
        public let roomId: String, memberId: String?, row: StoredSessionRow, evidence: String
        public var json: JSONValue {
            ["room_id": .string(roomId), "member_id": memberId.map(JSONValue.string) ?? .null, "profile": .string(row.profile),
             "id": .string(row.id), "evidence": .string(evidence), "title": .string(row.title)]
        }
    }
    public struct OwnedLive: Sendable, Equatable {
        public let roomId: String, row: LiveSessionRow, storedKey: String
        public var json: JSONValue {
            ["room_id": .string(roomId), "runtime_id": .string(row.runtimeId), "session_key": .string(row.sessionKey),
             "status": .string(row.status), "title": .string(row.title), "stored": .string(storedKey)]
        }
    }
    public struct Unresolved: Sendable, Equatable {
        public let kind: String, ref: String, detail: String
        public var json: JSONValue { ["kind": .string(kind), "ref": .string(ref), "detail": .string(detail)] }
    }

    /// A ledger-proven key (deleted earlier) that is stored again in its profile in the exact shape of the
    /// title-accounting placeholder (`source=unknown`, `message_count=0`): a delete candidate again.
    public struct LedgerRecreated: Sendable, Equatable {
        public let entry: SessionLedgerEntry, presence: StoredIdPresence
        public var json: JSONValue {
            ["key": .string(entry.key), "room_id": .string(entry.roomId), "evidence": .string(entry.evidence),
             "presence": .string(presence.description)]
        }
    }

    public var ownedStored: [OwnedStored] = []
    public var ownedLive: [OwnedLive] = []
    public var unresolved: [Unresolved] = []
    public var ledgerRecreated: [LedgerRecreated] = []
    /// Exact readback of every ledger key that is not an owned row of this pass: `profile:id` → presence.
    public var ledgerReadback: [String: StoredIdPresence] = [:]
    /// `hba`-looking rows that provably belong to no manifest room (reported, never touched).
    public var foreign: [String] = []
    /// Every live runtime seen (`[runtime_id, session_key]`), owned or not: a stored row is never deleted
    /// while ANY runtime holds its id (`session.delete` matches the bare key too, `methods_session.py:1191`).
    public var liveRuntimes: [[String]] = []
    /// Profiles whose stored rows were read (member profiles + every `profiles.list` profile).
    public var scannedProfiles: [String] = []
    /// Exact-id inventory behind each close candidate: `session_key` → profile → presence.
    public var keyInventory: [String: [String: StoredIdPresence]] = [:]

    public var isEmpty: Bool { ownedStored.isEmpty && ownedLive.isEmpty && unresolved.isEmpty && ledgerRecreated.isEmpty }

    /// Identity of what is left (rounds compare it to tell "settled" from "still changing").
    public var fingerprint: [String] {
        (ownedStored.map { "s:\($0.row.key)" } + ownedLive.map { "l:\($0.row.runtimeId):\($0.row.status)" }
         + unresolved.map { "u:\($0.kind):\($0.ref)" } + ledgerRecreated.map { "r:\($0.entry.key)" }).sorted()
    }

    public var json: JSONValue {
        ["owned_stored": .array(ownedStored.map(\.json)), "owned_live": .array(ownedLive.map(\.json)),
         "unresolved": .array(unresolved.map(\.json)), "foreign_not_touched": .array(foreign.map(JSONValue.string)),
         "ledger_recreated": .array(ledgerRecreated.map(\.json)),
         "ledger_readback": .object(ledgerReadback.mapValues { .string($0.description) }),
         "scanned_profiles": .array(scannedProfiles.map(JSONValue.string)),
         "key_inventory": .object(keyInventory.mapValues { .object($0.mapValues { .string($0.description) }) })]
    }
}

public enum RoomSessionClassifier {
    public static let roomSource = "bot_room"
    /// Allowed clock skew between the room's `created_at` and a member session's `started_at`.
    public static let startSkew: Double = 120

    static func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Visible text of a preview (`…[:60] + "..."`) or derived title (`… + "…"`), whitespace-collapsed.
    static func visible(_ s: String) -> String {
        var t = collapse(s)
        if t.hasSuffix("...") { t.removeLast(3) } else if t.hasSuffix("…") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// What one text of a row (its title or its preview) says about the row.
    enum Verdict {
        case none                                          // empty
        case neutral                                       // an arbitrary (llm/user) title: says nothing
        case unknown(String)                               // a preview that is no room opening: no proof either way
        case owned(RoomManifestEntry, RoomMember?, String) // room, member, evidence label
        case foreign(String)                               // positively names another room
        case unresolved(String, String)                    // kind, detail

        var owned: (RoomManifestEntry, RoomMember?, String)? { if case let .owned(e, m, l) = self { return (e, m, l) }; return nil }
        var foreign: String? { if case let .foreign(s) = self { return s }; return nil }
        var unresolved: (String, String)? { if case let .unresolved(k, d) = self { return (k, d) }; return nil }
    }

    struct Context {
        let manifest: [RoomManifestEntry]
        let byTitle: [String: RoomManifestEntry]
        let nameCount: [String: Int]
        let otherRoomNames: Set<String>
        /// Earliest `created_at` of the manifest rooms each member profile is in (the time scope).
        let scopeStart: [String: Double]

        init(manifest: [RoomManifestEntry], otherRoomNames: Set<String>) {
            self.manifest = manifest
            byTitle = Dictionary(manifest.map { ($0.canonicalTitle, $0) }, uniquingKeysWith: { a, _ in a })
            var n: [String: Int] = [:], start: [String: Double] = [:]
            for e in manifest {
                n[e.name, default: 0] += 1
                for m in e.members { start[m.profile] = min(start[m.profile] ?? e.createdAt, e.createdAt) }
            }
            nameCount = n; scopeStart = start
            self.otherRoomNames = otherRoomNames
        }

        /// A `bot_room` row is in scope when its profile is a member of a test room and it did not start
        /// before that profile's first test room (unknown `started_at` counts as in scope).
        func inScope(_ row: StoredSessionRow) -> Bool {
            guard let start = scopeStart[row.profile] else { return false }
            return row.startedAt <= 0 || start <= 0 || row.startedAt >= start - RoomSessionClassifier.startSkew
        }
    }

    /// `[Discussion: "<name>"] You are @<handle>, …` (preview, derived title or live title) against the manifest.
    static func openingVerdict(_ text: String, label: String, profile: String, startedAt: Double, _ c: Context) -> Verdict? {
        guard text.hasPrefix("[Discussion: \"") else { return nil }
        let named = c.manifest.filter { text.hasPrefix($0.namePrefix) }
        if named.isEmpty {
            if c.manifest.contains(where: { $0.namePrefix.hasPrefix(text) }) {
                return .unresolved("truncated_provenance", "\(label) '\(text)' ends inside a test room's name")
            }
            return .foreign("\(label) names another room: \(text.prefix(60))")
        }
        if let n = named.first?.name, c.nameCount[n, default: 0] > 1 || c.otherRoomNames.contains(n) {
            return .unresolved("ambiguous_name", "room name '\(n)' is not unique")
        }
        let matches = named.flatMap { e in
            e.members.filter { $0.profile == profile && e.openingText(for: $0).hasPrefix(text) }.map { (e, $0) }
        }
        guard let (e, m) = matches.first else {
            return .unresolved("member_mismatch", "\(label) names test room '\(named[0].name)' but no member with profile \(profile) has that opening")
        }
        if Set(matches.map(\.0.roomId)).count > 1 { return .unresolved("ambiguous_room", "\(label) matches several test rooms") }
        if startedAt > 0, e.createdAt > 0, startedAt < e.createdAt - startSkew {
            return .unresolved("predates_room", "started before room \(e.roomId) was created")
        }
        return .owned(e, matches.count == 1 ? m : nil, "opening_\(label)")
    }

    static func titleVerdict(_ title: String, profile: String, startedAt: Double, _ c: Context) -> Verdict {
        if title.isEmpty { return .none }
        if let e = c.byTitle[title] {
            guard let m = e.members.first(where: { $0.profile == profile }) else {
                return .unresolved("member_mismatch", "title \(title) but profile \(profile) is not a member of \(e.roomId)")
            }
            return .owned(e, m, "exact_title")
        }
        if title.hasPrefix("Group: ") { return .foreign("title \(title)") }  // another room's canonical title
        return openingVerdict(visible(title), label: "derived_title", profile: profile, startedAt: startedAt, c) ?? .neutral
    }

    static func previewVerdict(_ preview: String, profile: String, startedAt: Double, _ c: Context) -> Verdict {
        let text = visible(preview)
        if text.isEmpty { return .none }
        return openingVerdict(text, label: "preview", profile: profile, startedAt: startedAt, c)
            ?? .unknown("preview '\(text.prefix(48))' is no room opening")
    }

    /// - Parameters:
    ///   - stored: rows of every scanned profile (member profiles are classified; rows of other profiles only
    ///     count when they name a test room, and for `session_key` collisions).
    ///   - otherRoomNames: names of live rooms that are NOT in the manifest (a same-name room makes a
    ///     preview match ambiguous).
    public static func classify(manifest: [RoomManifestEntry], stored: [StoredSessionRow], live: [LiveSessionRow],
                                otherRoomNames: Set<String> = []) -> RoomSessionDiscovery {
        var d = RoomSessionDiscovery()
        let c = Context(manifest: manifest, otherRoomNames: otherRoomNames)
        d.liveRuntimes = live.map { [$0.runtimeId, $0.sessionKey] }

        for row in stored where row.source == roomSource {
            let t = titleVerdict(row.title, profile: row.profile, startedAt: row.startedAt, c)
            let p = previewVerdict(row.preview, profile: row.profile, startedAt: row.startedAt, c)
            if let (kind, detail) = t.unresolved ?? p.unresolved {
                d.unresolved.append(.init(kind: kind, ref: row.key, detail: detail)); continue
            }
            let owned = [t.owned, p.owned].compactMap { $0 }
            let foreign = [t.foreign, p.foreign].compactMap { $0 }
            if let first = owned.first {
                if Set(owned.map(\.0.roomId)).count > 1 {
                    d.unresolved.append(.init(kind: "ambiguous_room", ref: row.key, detail: "title and preview name different test rooms"))
                } else if !foreign.isEmpty || p.isUnknown {
                    d.unresolved.append(.init(kind: "conflicting_provenance", ref: row.key,
                                              detail: "\(first.2) names \(first.0.roomId) but \(foreign.first ?? "the preview is no room opening")"))
                } else {
                    let label = t.owned?.2 == "exact_title" ? "exact_title" : (p.owned ?? first).2
                    d.ownedStored.append(.init(roomId: first.0.roomId, memberId: (t.owned?.1 ?? p.owned?.1)?.memberId, row: row, evidence: label))
                }
                continue
            }
            if !foreign.isEmpty {
                if row.title.hasPrefix("Group: hba-") || [row.title, row.preview].contains(where: { visible($0).hasPrefix("[Discussion: \"hba") }) {
                    d.foreign.append("\(row.key) \(row.title.isEmpty ? visible(row.preview).prefix(60) : row.title.prefix(60))")
                }
                continue
            }
            // No proof either way (empty, an llm/user title, a preview that is no room opening): a member
            // profile's bot_room row from the test window is NOT assumed absent.
            guard c.inScope(row) else { continue }
            if case .none = t, case .none = p {
                d.unresolved.append(.init(kind: "unattributed_empty", ref: row.key,
                                          detail: "bot_room row without title or preview in a member profile, started in the test window"))
            } else {
                d.unresolved.append(.init(kind: "unattributed", ref: row.key,
                                          detail: "bot_room row in a member profile, started in the test window, title '\(row.title.prefix(48))' preview '\(visible(row.preview).prefix(48))' name no room"))
            }
        }

        // Live runtimes carry no profile (`session.active_list`, `server.py:3062-3083`), while stored ids
        // can repeat across profiles (`server.py:3090-3097` matches on (profile_home, key)). A runtime is
        // owned only when its key is an owned row's id in exactly ONE scanned profile, exactly one runtime
        // holds that key, and its live title (the runtime's own DB title, else pending_title,
        // `server.py:3055-3059`) agrees with that row. Anything else is unresolved and never closed.
        var profilesById: [String: [String]] = [:]
        for r in stored { profilesById[r.id, default: []].append(r.profile) }
        var liveByKey: [String: [LiveSessionRow]] = [:]
        for l in live { liveByKey[l.sessionKey, default: []].append(l) }
        var handled = Set<String>()
        var seenIds = Set<String>()
        for s in d.ownedStored where seenIds.insert(s.row.id).inserted {
            let cands = liveByKey[s.row.id] ?? []
            guard !cands.isEmpty else { continue }
            cands.forEach { handled.insert($0.runtimeId) }
            let holders = profilesById[s.row.id] ?? []
            if holders.count > 1 {
                for l in cands {
                    d.unresolved.append(.init(kind: "key_collision", ref: l.runtimeId,
                                              detail: "session_key \(s.row.id) is a stored id in profiles \(holders.sorted()); the runtime's profile is unknown"))
                }
            } else if cands.count > 1 {
                for l in cands {
                    d.unresolved.append(.init(kind: "key_collision", ref: l.runtimeId,
                                              detail: "\(cands.count) live runtimes hold session_key \(s.row.id)"))
                }
            } else if liveTitleAgrees(cands[0].title, with: s, c) {
                d.ownedLive.append(.init(roomId: s.roomId, row: cands[0], storedKey: s.row.key))
            } else {
                d.unresolved.append(.init(kind: "live_title_conflict", ref: cands[0].runtimeId,
                                          detail: "live title '\(cands[0].title.prefix(60))' disagrees with owned row \(s.row.key) ('\(s.row.title.prefix(48))', \(s.roomId))"))
            }
        }
        let unresolvedIds = Set(d.unresolved.compactMap { $0.ref.split(separator: ":", maxSplits: 1).last.map(String.init) })
        for row in live where !handled.contains(row.runtimeId) {
            if unresolvedIds.contains(row.sessionKey) { continue }  // already reported through its stored row
            if let e = c.byTitle[row.title] {
                d.unresolved.append(.init(kind: "title_only_live", ref: row.runtimeId,
                                          detail: "live title \(row.title) but session_key \(row.sessionKey) is no owned bot_room row of \(e.roomId)'s members"))
            } else if let e = manifest.first(where: { visible(row.title).hasPrefix($0.namePrefix) }) {
                d.unresolved.append(.init(kind: "live_unmapped", ref: row.runtimeId,
                                          detail: "live title names test room \(e.roomId) but session_key \(row.sessionKey) is no owned stored row"))
            }
        }
        return d
    }

    /// The live title of the single runtime holding an owned row's key must not point elsewhere: empty
    /// (no DB title, no pending title), the row's own stored title, the room's `Group:` title, or an
    /// opening of the same room for the row's profile (title phases change between the two reads).
    static func liveTitleAgrees(_ title: String, with s: RoomSessionDiscovery.OwnedStored, _ c: Context) -> Bool {
        if title.isEmpty || title == s.row.title { return true }
        if case let .owned(e, _, _) = titleVerdict(title, profile: s.row.profile, startedAt: s.row.startedAt, c) { return e.roomId == s.roomId }
        return false
    }

    /// Second gate for every `ownedLive` (a close candidate): the runtime's `session_key` must be an exact
    /// stored id in the owning profile and in NO other profile of `profiles`, each answer proven by an
    /// exact lookup (`inventory[key][profile]`). A missing/unknown answer, the id in another profile (any
    /// source, archived, outside any listing window), or the id gone from the owning profile moves the
    /// runtime to `unresolved`; it is then never closed, and the owned row's delete stays deferred because
    /// the runtime still holds its id.
    public static func verifyLiveOwnership(_ d: inout RoomSessionDiscovery, inventory: [String: [String: StoredIdPresence]],
                                           profiles: [String]) {
        var kept: [RoomSessionDiscovery.OwnedLive] = []
        for l in d.ownedLive {
            let key = l.row.sessionKey
            let owner = d.ownedStored.first { $0.row.key == l.storedKey }?.row.profile
                ?? String(l.storedKey.split(separator: ":", maxSplits: 1).first ?? "")
            let inv = inventory[key] ?? [:]
            let answers = profiles.map { ($0, inv[$0] ?? .unknown("not checked")) }
            let others = answers.filter { $0.0 != owner && $0.1.isPresent }
            let unknown = answers.filter { $0.1.isUnknown }
            if !others.isEmpty {
                d.unresolved.append(.init(kind: "key_collision", ref: l.row.runtimeId,
                                          detail: "session_key \(key) is also a stored id in \(others.map { "\($0.0) \($0.1)" }.joined(separator: ", ")) (exact lookup); the runtime's profile is unknown"))
            } else if !unknown.isEmpty {
                d.unresolved.append(.init(kind: "key_inventory_unknown", ref: l.row.runtimeId,
                                          detail: "uniqueness of session_key \(key) not proven: \(unknown.map { "\($0.0) \($0.1)" }.joined(separator: ", "))"))
            } else if !(inv[owner]?.isPresent ?? false) {
                d.unresolved.append(.init(kind: "key_inventory_changed", ref: l.row.runtimeId,
                                          detail: "owned row \(l.storedKey) is \(inv[owner]?.description ?? "unchecked") on exact lookup"))
            } else {
                kept.append(l)
            }
        }
        d.ownedLive = kept
        d.keyInventory = inventory
    }

    /// Third gate (BLOCK-003C): every ledger key (proven earlier, maybe deleted) that is not an owned row of
    /// this pass is read back by exact id in its own profile (`answers[profile:id]`), whatever its source or
    /// title — `session.list` + the `bot_room` filter cannot see a row the title accounting re-created as
    /// `source=unknown` (`hermes_state_usage.py:388-391`).
    /// - absent → fine (recorded in `ledgerReadback`);
    /// - present as the placeholder shape (`source == "unknown"`, `message_count == 0`) → `ledgerRecreated`
    ///   (delete it again once no runtime holds the id);
    /// - present in any other shape (another source, messages, no count) → `ledger_key_present`, never
    ///   deleted (unless the same row is already reported unresolved by its listing);
    /// - not provable → `ledger_readback_unknown`.
    /// Each makes the pass non-empty, so a cleanup cannot settle and an audit cannot pass while any
    /// proven key is stored again or unprovable.
    public static func readBackLedger(_ d: inout RoomSessionDiscovery, ledger: [SessionLedgerEntry],
                                      answers: [String: StoredIdPresence]) {
        let owned = Set(d.ownedStored.map(\.row.key))
        let reported = Set(d.unresolved.map(\.ref))
        var seen = Set<String>()
        for e in ledger where !owned.contains(e.key) && seen.insert(e.key).inserted {
            let a = answers[e.key] ?? .unknown("not checked")
            d.ledgerReadback[e.key] = a
            switch a {
            case .absent:
                break
            case .unknown(let why):
                d.unresolved.append(.init(kind: "ledger_readback_unknown", ref: e.key,
                                          detail: "exact readback of ledger key \(e.key) (\(e.roomId)) not proven: \(why)"))
            case .present(let source, let messages):
                if source == "unknown", messages == 0 {
                    d.ledgerRecreated.append(.init(entry: e, presence: a))
                } else if !reported.contains(e.key) {
                    d.unresolved.append(.init(kind: "ledger_key_present", ref: e.key,
                                              detail: "ledger key \(e.key) (\(e.roomId), \(e.evidence)) is stored again as \(a); not the title-accounting placeholder (source=unknown, 0 messages) → not deleted"))
                }
            }
        }
    }
}

private extension RoomSessionClassifier.Verdict {
    var isUnknown: Bool { if case .unknown = self { return true }; return false }
}

/// What the cleanup needs from a backend (the harness adapts `GatewayClient`; tests use a fake).
public protocol RoomSessionGateway: Sendable {
    /// Every profile of the install (`profiles.list`): stored ids are checked for collisions across all
    /// of them, not only the member profiles.
    func profileNames() async throws -> [String]
    /// Candidate rows of one profile (a filtered listing: discovery only, never proof of absence).
    func storedRows(profile: String) async throws -> [StoredSessionRow]
    /// Exact stored-id lookup in one profile's store with no listing filter (source, hidden, archived,
    /// children, window). Anything not proven is `.unknown`.
    func storedIdPresence(profile: String, id: String) async -> StoredIdPresence
    func liveRows() async throws -> [LiveSessionRow]
    /// `session.close {session_id: runtime}` → `closed`.
    func close(runtimeId: String) async throws -> Bool
    /// `session.delete {session_id, profile}`; throws `GatewayClient.RPCError` (4007 gone, 4023 live/guarded).
    func delete(profile: String, id: String) async throws
    func sleep(seconds: Double) async throws
}

public struct RoomSessionCleanupReport: Sendable {
    public var ok: Bool
    public var reason: String
    public var rounds: [JSONValue]
    public var closed: [JSONValue]
    public var deleted: [JSONValue]
    /// Re-created placeholders of ledger keys that were deleted again.
    public var redeleted: [JSONValue] = []
    public var final: RoomSessionDiscovery
    public var lastErrors: [String: String]
    /// Every key the ledger held at the end of the run (prior + proven in this run).
    public var ledgerKeys: [SessionLedgerEntry] = []
    /// `false` when no recorder was given (in-memory only: a later run cannot recall this run's keys).
    public var ledgerDurable = false

    public var json: JSONValue {
        ["ok": .bool(ok), "reason": .string(reason), "rounds": .array(rounds), "closed": .array(closed),
         "deleted": .array(deleted), "redeleted": .array(redeleted), "final": final.json,
         "ledger": ["durable": .bool(ledgerDurable), "keys": .array(ledgerKeys.map(\.json))],
         "last_errors": .object(lastErrors.mapValues(JSONValue.string))]
    }
}

/// Bounded, re-discovering cleanup: every round re-reads stored rows and live runtimes, closes owned
/// runtimes that are `idle` (never a working one), deletes owned stored rows whose runtime is gone
/// (4023 → next round), and stops only after `settleRounds` consecutive empty discoveries (rounds are
/// `every` seconds apart). Out of rounds → `ok == false` with what is left and why.
///
/// Ledger (BLOCK-003C): every owned row is recorded as `proven` (scope, profile, exact id, room, evidence)
/// BEFORE its runtime is closed or the row deleted — a record that cannot be written means no close and
/// no delete for that key. Every later round (and `discover` in an audit or a later run that loads the
/// ledger) reads each remembered key back by exact id, independent of source/title/runtime
/// (`RoomSessionClassifier.readBackLedger`). A key re-created as the title-accounting placeholder is
/// deleted again once no runtime holds its id; anything else present or unprovable stays unresolved. An
/// empty pass therefore means: nothing owned, nothing unresolved, and every remembered key absent. The
/// caller chooses `settleRounds × every` longer than the late writer's window (the harness: ≥ 90 s).
public struct RoomSessionCleaner: Sendable {
    public var manifest: [RoomManifestEntry]
    public var otherRoomNames: Set<String>
    public var maxRounds: Int
    public var every: Double
    public var settleRounds: Int
    /// Keys proven earlier (already filtered to this backend's scope by the caller).
    public var ledger: [SessionLedgerEntry]
    /// Scope stamped on new records (which backend/home).
    public var scope: String
    public var recorder: SessionLedgerRecorder?

    public init(manifest: [RoomManifestEntry], otherRoomNames: Set<String> = [], maxRounds: Int = 18, every: Double = 10, settleRounds: Int = 2,
                ledger: [SessionLedgerEntry] = [], scope: String = "", recorder: SessionLedgerRecorder? = nil) {
        self.manifest = manifest; self.otherRoomNames = otherRoomNames
        self.maxRounds = max(1, maxRounds); self.every = every; self.settleRounds = max(1, settleRounds)
        self.ledger = ledger; self.scope = scope; self.recorder = recorder
    }

    public var profiles: [String] {
        var seen = Set<String>()
        return manifest.flatMap { $0.members.map(\.profile) }.filter { seen.insert($0).inserted }
    }

    /// One read-only pass. `ledger` defaults to the cleaner's own (an audit passes the stored ledger).
    public func discover(_ gw: RoomSessionGateway, ledger keys: [SessionLedgerEntry]? = nil) async throws -> RoomSessionDiscovery {
        var scan = profiles
        for p in try await gw.profileNames() where !scan.contains(p) { scan.append(p) }
        var stored: [StoredSessionRow] = []
        for p in scan { stored += try await gw.storedRows(profile: p) }
        let live = try await gw.liveRows()
        var d = RoomSessionClassifier.classify(manifest: manifest, stored: stored, live: live, otherRoomNames: otherRoomNames)
        d.scannedProfiles = scan
        // Close candidates only: prove each key's profile by exact lookup in EVERY scanned profile.
        var inventory: [String: [String: StoredIdPresence]] = [:]
        for key in Set(d.ownedLive.map(\.row.sessionKey)).sorted() {
            for p in scan { inventory[key, default: [:]][p] = await gw.storedIdPresence(profile: p, id: key) }
        }
        RoomSessionClassifier.verifyLiveOwnership(&d, inventory: inventory, profiles: scan)
        // Every remembered key that is not an owned row right now: exact readback in its own profile.
        let owned = Set(d.ownedStored.map(\.row.key))
        var answers: [String: StoredIdPresence] = [:]
        for e in keys ?? ledger where !owned.contains(e.key) && answers[e.key] == nil {
            answers[e.key] = await gw.storedIdPresence(profile: e.profile, id: e.id)
        }
        RoomSessionClassifier.readBackLedger(&d, ledger: keys ?? ledger, answers: answers)
        return d
    }

    public func run(_ gw: RoomSessionGateway, log: @Sendable (String) -> Void = { _ in }) async -> RoomSessionCleanupReport {
        var report = RoomSessionCleanupReport(ok: false, reason: "", rounds: [], closed: [], deleted: [], final: .init(), lastErrors: [:])
        report.ledgerDurable = recorder != nil
        // The run's memory: prior keys + keys proven now, in first-seen order.
        var known: [String: SessionLedgerEntry] = [:]
        var order: [String] = []
        for e in ledger where known[e.key] == nil { known[e.key] = e; order.append(e.key) }
        var ledgerFailures: [String] = []
        func remember(_ e: SessionLedgerEntry) -> Bool {
            do {
                try recorder?.record(e)
                return true
            } catch {
                let msg = Redaction.describe(error)
                report.lastErrors["ledger:\(e.key)"] = msg
                ledgerFailures.append("\(e.event) \(e.key)")
                log("ledger: could not record \(e.event) \(e.key): \(msg)")
                return false
            }
        }
        var emptyStreak = 0
        var lastDiscovery = RoomSessionDiscovery()
        for round in 1...maxRounds {
            let d: RoomSessionDiscovery
            do { d = try await discover(gw, ledger: order.compactMap { known[$0] }) } catch {
                let msg = Redaction.describe(error)
                report.lastErrors["discovery"] = msg
                report.rounds.append(["round": .number(Double(round)), "discovery_error": .string(msg)])
                log("round \(round): discovery failed: \(msg)")
                emptyStreak = 0
                if round < maxRounds { try? await gw.sleep(seconds: every) }
                continue
            }
            lastDiscovery = d
            var actions: [JSONValue] = []
            if d.isEmpty {
                emptyStreak += 1
                report.rounds.append(["round": .number(Double(round)), "empty": .bool(true), "streak": .number(Double(emptyStreak)),
                                      "foreign_not_touched": .number(Double(d.foreign.count)),
                                      "ledger_absent": .number(Double(d.ledgerReadback.count))])
                log("round \(round): nothing owned or unresolved, \(d.ledgerReadback.count) ledger key(s) absent by exact readback (empty \(emptyStreak)/\(settleRounds))")
                if emptyStreak >= settleRounds {
                    report.final = d
                    report.ledgerKeys = order.compactMap { known[$0] }
                    if ledgerFailures.isEmpty {
                        report.ok = true; report.reason = "settled: \(settleRounds) consecutive empty discoveries"
                    } else {
                        report.reason = "empty, but the ledger could not record: \(ledgerFailures.joined(separator: ", "))"
                    }
                    return report
                }
                if round < maxRounds { try? await gw.sleep(seconds: every) }
                continue
            }
            emptyStreak = 0
            // Remember every owned row before anything is done to it.
            for s in d.ownedStored where known[s.row.key] == nil {
                let e = SessionLedgerEntry(event: "proven", scope: scope, profile: s.row.profile, id: s.row.id, roomId: s.roomId, evidence: s.evidence)
                if remember(e) {
                    known[e.key] = e; order.append(e.key)
                    actions.append(["ledger_proven": .string(e.key)])
                }
            }
            var closedNow = Set<String>()
            for l in d.ownedLive {
                guard known[l.storedKey] != nil else {
                    actions.append(["not_closed": .string(l.row.runtimeId), "why": .string("ledger record of \(l.storedKey) failed")])
                    continue
                }
                guard l.row.status == "idle" else {
                    actions.append(["wait": .string(l.row.runtimeId), "status": .string(l.row.status)])
                    log("round \(round): waiting: runtime \(l.row.runtimeId) (\(l.roomId), stored \(l.storedKey)) is \(l.row.status), title '\(l.row.title.prefix(48))'")
                    continue
                }
                do {
                    let ok = try await gw.close(runtimeId: l.row.runtimeId)
                    if ok { closedNow.insert(l.row.runtimeId) }
                    let entry: JSONValue = ["round": .number(Double(round)), "room_id": .string(l.roomId), "runtime_id": .string(l.row.runtimeId),
                                            "session_key": .string(l.row.sessionKey), "closed": .bool(ok)]
                    report.closed.append(entry); actions.append(["close": entry])
                    log("round \(round): session.close \(l.row.runtimeId) (\(l.roomId), stored \(l.storedKey)) → closed=\(ok)")
                } catch {
                    report.lastErrors["close:\(l.row.runtimeId)"] = Redaction.describe(error)
                    actions.append(["close_failed": .string(l.row.runtimeId), "error": .string(Redaction.describe(error))])
                }
            }
            // Any runtime (owned or not) still holding the id defers the delete: an unresolved one may be this row's.
            let stillLive = Set(d.liveRuntimes.filter { $0.count == 2 && !closedNow.contains($0[0]) }.map { $0[1] })
            for s in d.ownedStored {
                guard let proven = known[s.row.key] else {
                    actions.append(["not_deleted": .string(s.row.key), "why": "ledger record failed"]); continue
                }
                if stillLive.contains(s.row.id) { actions.append(["defer_delete": .string(s.row.key), "why": "a runtime still holds this id"]); continue }
                do {
                    try await gw.delete(profile: s.row.profile, id: s.row.id)
                    let entry: JSONValue = ["round": .number(Double(round)), "room_id": .string(s.roomId), "profile": .string(s.row.profile),
                                            "id": .string(s.row.id), "evidence": .string(s.evidence)]
                    report.deleted.append(entry); actions.append(["delete": entry])
                    report.lastErrors[s.row.key] = nil
                    _ = remember(proven.with(event: "deleted"))
                    log("round \(round): session.delete \(s.row.key) (\(s.roomId), \(s.evidence)) ok")
                } catch let e as GatewayClient.RPCError where e.code == 4007 {
                    actions.append(["gone": .string(s.row.key)])
                    _ = remember(proven.with(event: "deleted"))
                    log("round \(round): session.delete \(s.row.key) → 4007 (already gone)")
                } catch {
                    let msg = Redaction.describe(error)
                    report.lastErrors[s.row.key] = msg
                    actions.append(["delete_failed": .string(s.row.key), "error": .string(msg)])
                    log("round \(round): session.delete \(s.row.key) failed: \(msg)")
                }
            }
            // Remembered keys re-created as the title-accounting placeholder: delete again (same guards).
            for r in d.ledgerRecreated {
                let key = r.entry.key
                log("round \(round): ledger key \(key) (\(r.entry.roomId)) is stored again: \(r.presence)")
                if stillLive.contains(r.entry.id) { actions.append(["defer_redelete": .string(key), "why": "a runtime still holds this id"]); continue }
                do {
                    try await gw.delete(profile: r.entry.profile, id: r.entry.id)
                    let entry: JSONValue = ["round": .number(Double(round)), "room_id": .string(r.entry.roomId), "profile": .string(r.entry.profile),
                                            "id": .string(r.entry.id), "was": .string(r.presence.description)]
                    report.redeleted.append(entry); actions.append(["redelete": entry])
                    report.lastErrors[key] = nil
                    _ = remember(r.entry.with(event: "redeleted"))
                    log("round \(round): session.delete \(key) (re-created placeholder) ok")
                } catch let e as GatewayClient.RPCError where e.code == 4007 {
                    actions.append(["gone": .string(key)])
                } catch {
                    let msg = Redaction.describe(error)
                    report.lastErrors[key] = msg
                    actions.append(["redelete_failed": .string(key), "error": .string(msg)])
                    log("round \(round): session.delete \(key) (re-created placeholder) failed: \(msg)")
                }
            }
            for u in d.unresolved { log("round \(round): unresolved \(u.kind) \(u.ref): \(u.detail)") }
            report.rounds.append(["round": .number(Double(round)), "discovery": d.json, "actions": .array(actions)])
            if round < maxRounds { try? await gw.sleep(seconds: every) }
        }
        // Out of rounds: read back once more and report what is left.
        if let d = try? await discover(gw, ledger: order.compactMap { known[$0] }) { lastDiscovery = d }
        report.final = lastDiscovery
        report.ledgerKeys = order.compactMap { known[$0] }
        report.ok = false
        if lastDiscovery.isEmpty {
            report.reason = "empty on the last read but not stable for \(settleRounds) rounds"
        } else {
            var why: [String] = []
            let working = lastDiscovery.ownedLive.filter { $0.row.status != "idle" }
            if !working.isEmpty { why.append("\(working.count) owned runtime(s) still \(Set(working.map(\.row.status)).sorted().joined(separator: "/"))") }
            if !lastDiscovery.ownedStored.isEmpty { why.append("\(lastDiscovery.ownedStored.count) owned stored row(s) left") }
            if !lastDiscovery.ledgerRecreated.isEmpty { why.append("\(lastDiscovery.ledgerRecreated.count) ledger key(s) re-created after delete") }
            if !lastDiscovery.unresolved.isEmpty { why.append("\(lastDiscovery.unresolved.count) unresolved (\(Set(lastDiscovery.unresolved.map(\.kind)).sorted().joined(separator: ",")))") }
            report.reason = "not clean after \(maxRounds) rounds: " + why.joined(separator: "; ")
        }
        if !ledgerFailures.isEmpty { report.reason += "; ledger could not record: \(ledgerFailures.joined(separator: ", "))" }
        return report
    }
}
