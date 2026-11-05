import Foundation

/// A bot's roster presentation state that the app reads and writes: Pin to top and Hide, stored in the
/// profile's `ui_meta["hermes-bots"]` exactly as Hermes Desktop stores them (`types.ts` `BotMeta.pinned` /
/// `.hidden`), so both apps show the same roster. Hiding is display-only: a hidden bot keeps working,
/// stays mentionable and keeps its chats.
public struct BotUIMeta: Sendable, Hashable {
    public var pinned: Bool
    public var hidden: Bool

    public init(pinned: Bool = false, hidden: Bool = false) {
        self.pinned = pinned; self.hidden = hidden
    }

    /// From one `profiles.list` row (`ui_meta["hermes-bots"]`); anything else is "not pinned, not hidden".
    public init(row: JSONValue) {
        let ns = row["ui_meta"]?[BotMetaSync.namespace]
        pinned = ns?["pinned"]?.bool ?? false
        hidden = ns?["hidden"]?.bool ?? false
    }
}

/// Writes `ui_meta["hermes-bots"]` the way Hermes Desktop does (`data.ts` `persistBotMetaPatch`):
/// read the profile's CURRENT namespace from `profiles.list`, lay the patch over it, and send only the
/// `hermes-bots` key with `profiles.configure {name, ui_meta, ui_meta_expected_revisions}`. The gateway
/// merges `ui_meta` key-wise (`methods_profiles.py` `_configure_ui_meta`), so other `ui_meta` keys are never
/// touched; the per-key revision makes a concurrent writer's newer value a re-read instead of an overwrite.
/// Up to `attempts` reads on a conflict, like Desktop's `BOT_META_CAS_ATTEMPTS`.
public enum BotMetaSync {
    public static let namespace = "hermes-bots"
    public static let attempts = 3
    /// Desktop drops a stale `chat` pointer from the namespace on every write (`data.ts`).
    static let droppedKeys: Set<String> = ["chat"]

    public typealias Call = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    public enum Outcome: Sendable, Equatable {
        /// The gateway confirmed `applied.ui_meta == true`; `meta` is what was written.
        case persisted(BotUIMeta)
        /// The gateway speaks the contract and the write did not apply (or every CAS attempt conflicted).
        case failed
        /// An older gateway: no `applied` in the reply. Nothing is known to be saved.
        case unsupported
        /// `profiles.list` no longer lists the profile.
        case notFound
    }

    /// The profile's namespace as the backend holds it now, and its CAS revision (nil on a gateway that
    /// predates `ui_meta_revisions`: then no expected revision is sent).
    public struct ServerMeta: Sendable, Equatable {
        public let fields: [String: JSONValue]
        public let revision: Int?
    }

    public static func serverMeta(row: JSONValue) -> ServerMeta {
        let fields = row["ui_meta"]?[namespace]?.object ?? [:]
        var revision: Int?
        if let revisions = row["ui_meta_revisions"]?.object {
            revision = max(0, revisions[namespace]?.int ?? 0)
        }
        return ServerMeta(fields: fields, revision: revision)
    }

    /// The namespace to write: the server's current fields minus the dropped keys, with `patch` on top.
    public static func merged(_ base: [String: JSONValue], patch: [String: JSONValue]) -> [String: JSONValue] {
        var out = base.filter { !droppedKeys.contains($0.key) }
        for (k, v) in patch { out[k] = v }
        return out
    }

    /// `profiles.configure` params for one write.
    public static func configureParams(name: String, fields: [String: JSONValue], revision: Int?) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(name), "ui_meta": .object([namespace: .object(fields)])]
        if let revision { params["ui_meta_expected_revisions"] = .object([namespace: .number(Double(revision))]) }
        return .object(params)
    }

    /// Saves `patch` (e.g. `["pinned": true]`) onto profile `name`'s namespace.
    public static func save(name: String, patch: [String: JSONValue], call: Call) async throws -> Outcome {
        for _ in 0..<attempts {
            let list = try await call("profiles.list", ["include_sessions": false])
            guard let row = (list["profiles"]?.array ?? []).first(where: { $0["name"]?.string == name }) else {
                return .notFound
            }
            let server = serverMeta(row: row)
            let fields = merged(server.fields, patch: patch)
            let result = try await call("profiles.configure", configureParams(name: name, fields: fields, revision: server.revision))
            if let conflicts = result["applied"]?["ui_meta_conflicts"], conflicts != .null { continue }
            guard let applied = result["applied"], applied.object != nil else { return .unsupported }
            guard applied["ui_meta"]?.bool == true else { return .failed }
            return .persisted(BotUIMeta(row: ["ui_meta": .object([namespace: .object(fields)])]))
        }
        return .failed
    }
}
