import Foundation

/// Duplicate a bot the way Hermes Desktop does (`profile-ops.ts` `duplicateBot`): a new profile named
/// `<name>-2`, `-3`, … (the first name the live roster does not hold; the base is cut, never the suffix, so
/// a 64-character name still gets its suffix) created with `profiles.create {name, clone_from, description}`
/// (config, skills, SOUL and memory come from the clone), then the same look: the source's
/// `ui_meta["hermes-bots"]` minus `chat` and `created` (they belong to the original), its title with
/// " (copy)", and its avatar image (`profiles.get_asset` → `profiles.set_asset`).
public enum BotDuplicate {
    public static let maxNameLength = 64
    static let droppedKeys: Set<String> = ["chat", "created"]

    public enum Step: Sendable, Equatable {
        case creating(String)
        case copyingLook
        case copyingAvatar
    }

    public struct Result: Sendable, Equatable {
        public let name: String
        public let path: String
        /// Parts of the look that could not be copied (the profile itself exists).
        public let warnings: [String]
    }

    public struct Failure: Error, RedactionSafeError, Equatable {
        public let description: String
    }

    /// `<base>-n` for n in 2..<100, the first one not in `taken`.
    public static func name(for base: String, taken: Set<String>) -> String? {
        for n in 2..<100 {
            let suffix = "-\(n)"
            let candidate = String(base.prefix(maxNameLength - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
        }
        return nil
    }

    /// The look to copy from a source `profiles.list` row; nil when it has no `hermes-bots` namespace.
    public static func look(row: JSONValue) -> [String: JSONValue]? {
        guard let ns = row["ui_meta"]?[BotMetaSync.namespace]?.object, !ns.isEmpty else { return nil }
        var look = ns.filter { !droppedKeys.contains($0.key) }
        let title = ns["title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        look["title"] = .string(title.isEmpty ? "" : "\(title) (copy)")
        return look
    }

    public static func run(source: String, description: String, api: BotProfileAPI, call: @escaping BotMetaSync.Call,
                           progress: @Sendable (Step) async -> Void = { _ in }) async throws -> Result {
        let roster = try await api.roster()
        guard let name = name(for: source, taken: Set(roster.names)) else {
            throw Failure(description: "No free name for the duplicate.")
        }
        let sourceRow = roster.row(source)
        await progress(.creating(name))
        let path = try await api.create(name, cloneFrom: source, description: description)
        var warnings: [String] = []
        if let row = sourceRow, let look = look(row: row) {
            await progress(.copyingLook)
            do {
                if case .persisted = try await BotMetaSync.save(name: name, patch: look, call: call) {} else {
                    warnings.append("The title and look were not copied.")
                }
            } catch { warnings.append("The title and look were not copied: \(Redaction.describe(error))") }
        }
        if sourceRow?["has_avatar"]?.bool == true {
            await progress(.copyingAvatar)
            do {
                if let data = try await api.avatar(source) { try await api.setAvatar(name, image: data) }
            } catch { warnings.append("The avatar was not copied: \(Redaction.describe(error))") }
        }
        return Result(name: name, path: path, warnings: warnings)
    }
}
