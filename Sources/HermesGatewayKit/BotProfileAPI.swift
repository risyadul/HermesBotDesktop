import Foundation

/// The profile editor RPCs Hermes Desktop's Edit Profile dialog uses (`edit-profile-dialog.tsx`,
/// `profile-config.tsx`, `model-picker.tsx`), typed. Gateway side: `tui_gateway/methods_profiles.py`
/// (`profiles.describe` / `.configure` / `.set_asset` / `.get_asset` / `.create`) and
/// `methods_complete.py` (`model.options`). `call` is the gateway connection (a fake in tests).
public struct BotProfileAPI: Sendable {
    public typealias Call = BotMetaSync.Call
    let call: Call

    public init(call: @escaping Call) { self.call = call }

    // MARK: profiles.describe

    /// One toggleable capability (skill, toolset or MCP server) as `profiles.describe` lists it.
    public struct Capability: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public var enabled: Bool
        public let label: String?
        public let detail: String?
        public let toolCount: Int?

        public init(name: String, enabled: Bool, label: String? = nil, detail: String? = nil, toolCount: Int? = nil) {
            self.name = name; self.enabled = enabled; self.label = label; self.detail = detail; self.toolCount = toolCount
        }

        init?(_ v: JSONValue, detailKey: String = "description") {
            guard let name = v["name"]?.string, !name.isEmpty else { return nil }
            self.init(name: name, enabled: v["enabled"]?.bool ?? true, label: v["label"]?.string,
                      detail: v[detailKey]?.string, toolCount: v["tool_count"]?.int)
        }
    }

    /// The editor snapshot (`profiles.describe`): description, SOUL, model pin, skills, toolsets, MCP servers.
    public struct Snapshot: Sendable, Equatable {
        public let description: String
        public let soul: String
        public let provider: String
        public let model: String
        public let skills: [Capability]
        public let toolsets: [Capability]
        public let mcpServers: [Capability]

        public init(description: String = "", soul: String = "", provider: String = "", model: String = "",
                    skills: [Capability] = [], toolsets: [Capability] = [], mcpServers: [Capability] = []) {
            self.description = description; self.soul = soul; self.provider = provider; self.model = model
            self.skills = skills; self.toolsets = toolsets; self.mcpServers = mcpServers
        }

        public init(_ r: JSONValue) {
            description = r["description"]?.string ?? ""
            soul = r["soul"]?.string ?? ""
            provider = r["model"]?["provider"]?.string ?? ""
            model = r["model"]?["default"]?.string ?? ""
            skills = (r["skills"]?.array ?? []).compactMap { Capability($0) }
            toolsets = (r["toolsets"]?.array ?? []).compactMap { Capability($0) }
            // MCP rows carry `transport`, not a description; an absent `enabled` reads as on (Desktop).
            mcpServers = (r["mcp_servers"]?.array ?? []).compactMap { Capability($0, detailKey: "transport") }
        }
    }

    public func describe(_ name: String) async throws -> Snapshot {
        Snapshot(try await call("profiles.describe", ["name": .string(name)]))
    }

    // MARK: model.options

    /// One provider of the `model.options` inventory; `models` are bare slugs (objects on older gateways).
    public struct ModelProvider: Sendable, Hashable, Identifiable {
        public var id: String { slug }
        public let slug: String
        public let name: String?
        public let aliases: [String]
        public let models: [String]

        public init(slug: String, name: String? = nil, aliases: [String] = [], models: [String]) {
            self.slug = slug; self.name = name; self.aliases = aliases; self.models = models
        }

        /// `name (slug)` like Desktop's provider menu, or the slug alone.
        public var label: String { name.map { $0.isEmpty ? slug : "\($0) (\(slug))" } ?? slug }

        /// Desktop's `catalogProviderMatches`: the slug or an alias, ignoring case.
        public func matches(_ provider: String) -> Bool {
            let p = provider.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { return false }
            return slug.lowercased() == p || aliases.contains { $0.lowercased() == p }
        }
    }

    public static func providers(_ r: JSONValue) -> [ModelProvider] {
        (r["providers"]?.array ?? []).compactMap { p in
            guard let slug = p["slug"]?.string, !slug.isEmpty else { return nil }
            let models: [String] = (p["models"]?.array ?? []).compactMap { m in
                if let s = m.string { return s.isEmpty ? nil : s }
                let s = m["id"]?.string ?? m["name"]?.string ?? ""
                return s.isEmpty ? nil : s
            }
            return ModelProvider(slug: slug, name: p["name"]?.string, aliases: (p["aliases"]?.array ?? []).compactMap(\.string),
                                 models: models)
        }
    }

    /// `model.options {include_unconfigured: true, explicit_only: false}` in the bot's profile scope
    /// (Desktop asks the bot's own backend; one `hermes serve` scopes by `profile`).
    public func modelOptions(profile: String) async throws -> [ModelProvider] {
        Self.providers(try await call("model.options", ["include_unconfigured": true, "explicit_only": false,
                                                         "profile": .string(profile)]))
    }

    // MARK: profiles.configure

    /// The `profiles.configure` reply: one boolean per section sent (`applied`), and the expensive-model
    /// gate (`confirm_required` + `confirm_message`: the model section wrote nothing and waits for a resend
    /// with `confirm_expensive_model: true`).
    public struct ConfigureResult: Sendable, Equatable {
        public let applied: [String: Bool]
        public let confirmMessage: String?

        public init(applied: [String: Bool], confirmMessage: String? = nil) {
            self.applied = applied; self.confirmMessage = confirmMessage
        }

        public init(_ r: JSONValue) {
            var a: [String: Bool] = [:]
            for (k, v) in r["applied"]?.object ?? [:] { if let b = v.bool { a[k] = b } }
            applied = a
            confirmMessage = r["confirm_required"]?.bool == true ? (r["confirm_message"]?.string ?? "") : nil
        }

        public var confirmRequired: Bool { confirmMessage != nil }
    }

    /// The editor's dirty sections, as `profiles.configure` params (only what is set is sent).
    public struct Changes: Sendable, Equatable {
        public var description: String?
        public var soul: String?
        /// Both non-empty: pin `provider` / `model`.
        public var model: (provider: String, model: String)?
        public var confirmExpensiveModel = false
        public var disabledSkills: [String]?
        public var enabledToolsets: [String]?
        public var enabledMcpServers: [String]?

        public init() {}

        public var isEmpty: Bool {
            description == nil && soul == nil && model == nil && disabledSkills == nil && enabledToolsets == nil
                && enabledMcpServers == nil
        }

        public static func == (a: Changes, b: Changes) -> Bool {
            a.description == b.description && a.soul == b.soul && a.model?.provider == b.model?.provider
                && a.model?.model == b.model?.model && a.confirmExpensiveModel == b.confirmExpensiveModel
                && a.disabledSkills == b.disabledSkills && a.enabledToolsets == b.enabledToolsets
                && a.enabledMcpServers == b.enabledMcpServers
        }

        public func params(name: String) -> JSONValue {
            var p: [String: JSONValue] = ["name": .string(name)]
            if let description { p["description"] = .string(description) }
            if let soul { p["soul"] = .string(soul) }
            if let model {
                p["model"] = .string(model.model); p["provider"] = .string(model.provider)
                if confirmExpensiveModel { p["confirm_expensive_model"] = true }
            }
            if let disabledSkills { p["disabled_skills"] = .array(disabledSkills.map { .string($0) }) }
            if let enabledToolsets { p["enabled_toolsets"] = .array(enabledToolsets.map { .string($0) }) }
            if let enabledMcpServers { p["enabled_mcp_servers"] = .array(enabledMcpServers.map { .string($0) }) }
            return .object(p)
        }
    }

    public func configure(_ name: String, _ changes: Changes) async throws -> ConfigureResult {
        ConfigureResult(try await call("profiles.configure", changes.params(name: name)))
    }

    /// Desktop's toolset rule: all checked (or none) clears the pin (`[]`); otherwise the checked set.
    public static func enabledToolsets(_ toolsets: [Capability]) -> [String] {
        let on = toolsets.filter(\.enabled)
        return on.count == toolsets.count || on.isEmpty ? [] : on.map(\.name)
    }

    // MARK: assets

    /// `profiles.set_asset {name, asset: "avatar", data}` with PNG or JPEG bytes (sniffed by the gateway).
    public func setAvatar(_ name: String, image data: Data) async throws {
        _ = try await call("profiles.set_asset", ["name": .string(name), "asset": "avatar",
                                                  "data": .string(ProfileAvatar.dataURL(data))])
    }

    /// `profiles.set_asset {name, asset: "avatar", clear: true}`.
    public func clearAvatar(_ name: String) async throws {
        _ = try await call("profiles.set_asset", ["name": .string(name), "asset": "avatar", "clear": true])
    }

    /// `profiles.get_asset`: the avatar's bytes, nil when the profile has none.
    public func avatar(_ name: String) async throws -> Data? {
        let r = try await call("profiles.get_asset", ["name": .string(name), "asset": "avatar"])
        guard r["found"]?.bool == true, let url = r["data"]?.string else { return nil }
        let payload = url.firstIndex(of: ",").map { String(url[url.index(after: $0)...]) } ?? url
        return Data(base64Encoded: payload)
    }

    // MARK: roster

    /// The `profiles.list` envelope the editor needs: every row, and `bot_mode_protocol` (the backend
    /// injects the teammate protocol itself, so SOUL.md must not carry it).
    public struct Roster: Sendable {
        public let rows: [JSONValue]
        public let injectsProtocol: Bool

        public init(_ r: JSONValue) {
            rows = r["profiles"]?.array ?? []
            injectsProtocol = r["bot_mode_protocol"]?.bool ?? false
        }

        public func row(_ name: String) -> JSONValue? { rows.first { $0["name"]?.string == name } }
        public var names: [String] { rows.compactMap { $0["name"]?.string } }
        public var teammates: [SoulProtocol.Teammate] {
            rows.compactMap { r in r["name"]?.string.map { SoulProtocol.Teammate(name: $0, description: r["description"]?.string ?? "") } }
        }
    }

    public func roster() async throws -> Roster {
        Roster(try await call("profiles.list", ["include_sessions": false]))
    }

    // MARK: profiles.create

    /// `profiles.create {name, clone_from, description}` as Desktop's Duplicate sends it; returns the path.
    public func create(_ name: String, cloneFrom: String, description: String) async throws -> String {
        let r = try await call("profiles.create", ["name": .string(name), "clone_from": .string(cloneFrom),
                                                   "description": .string(description)])
        return r["path"]?.string ?? ""
    }
}
