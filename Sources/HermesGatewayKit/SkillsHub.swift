import Foundation

/// A13: the skills hub as Hermes Desktop's search fallback uses it (`skills-hub.tsx`), over `skills.manage`
/// (`tui_gateway/methods_tools.py`):
/// - `{action: "search", query}` searches the shared hub (no profile) → `{results: [{name, description}]}`.
/// - `{action: "install", query: <name>, profile}` installs into that profile's skills folder; a blocked or
///   failed install is an error (5031) whose message is the last line the CLI would have printed.
public enum SkillsHub {
    /// A search can reach GitHub; an install downloads and scans the skill.
    public static let searchTimeout: TimeInterval = 60
    public static let installTimeout: TimeInterval = 300

    public struct Result: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let description: String

        public init(name: String, description: String = "") { self.name = name; self.description = description }
    }

    public static func searchParams(_ query: String) -> JSONValue {
        ["action": "search", "query": .string(query.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    public static func results(_ r: JSONValue) -> [Result] {
        (r["results"]?.array ?? []).compactMap { v in
            guard let name = v["name"]?.string, !name.isEmpty else { return nil }
            return Result(name: name, description: v["description"]?.string ?? "")
        }
    }

    /// Desktop's guard on what may reach `skills.manage install`: a slug or one owner/name path. Each segment
    /// starts with a letter or digit, so `..` (or any dot segment) never reaches the installer, and at most one `/`.
    public static func isInstallable(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$"#, options: .regularExpression) != nil
    }

    public static func installParams(_ name: String, profile: String) -> JSONValue {
        ["action": "install", "query": .string(name), "profile": .string(profile)]
    }

    /// `installed: true` in the reply; anything else is not an install.
    public static func installed(_ r: JSONValue) -> Bool { r["installed"]?.bool == true }
}
