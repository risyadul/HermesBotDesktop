import Foundation

// Bot Chat controls beside the composer (roadmap B7, B8, B9): model and reasoning effort per chat, steering
// the running turn, context usage. Wire shapes follow `tui_gateway` (`methods_config_set.py`,
// `methods_complete.py` `model.options`, `methods_session.py` `session.usage` / `session.context_breakdown`,
// `methods_session_interrupt.py` `session.redirect`) and what Hermes Desktop sends for the same controls.

/// Reasoning effort levels (`@hermes/shared` `REASONING_EFFORTS`, plus `none` = thinking off).
public enum ReasoningEffort {
    /// Every level `config.set {key: "reasoning"}` accepts as an effort, cheapest first. Display words the same
    /// key also takes (`show`, `hide`, …) write global display config, so they are never sent from here.
    public static let levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    /// What an unset effort (`""` = provider default) means (`DEFAULT_REASONING_EFFORT`).
    public static let fallback = "medium"

    public static func isLevel(_ s: String) -> Bool { levels.contains(s) }

    public static func label(_ effort: String) -> String {
        switch effort.isEmpty ? fallback : effort {
        case "none": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort
        }
    }

    /// The levels to offer for a model: thinking off only when the catalog says it can be disabled.
    public static func options(canDisable: Bool) -> [String] {
        canDisable ? levels : levels.filter { $0 != "none" }
    }
}

/// Context-window occupancy (`agent/context_breakdown.py` `context_usage_fields`, plus `compressions`), as
/// carried by `session.info.usage`, `session.usage`, the `session.usage` event and `message.complete.usage`.
/// nil when the payload has no context figures yet (no request made).
public struct ContextUsage: Sendable, Equatable {
    public var used: Int
    public var max: Int
    public var percent: Int
    /// The figure is an estimate (`context_source` other than `provider_usage`): shown with `~`.
    public var estimated: Bool
    public var compressions: Int?

    public init(used: Int, max: Int, percent: Int, estimated: Bool = false, compressions: Int? = nil) {
        self.used = used; self.max = max; self.percent = percent; self.estimated = estimated
        self.compressions = compressions
    }

    public init?(_ v: JSONValue?) {
        guard let v, let max = v["context_max"]?.int, max > 0 else { return nil }
        let used = Swift.max(0, v["context_used"]?.int ?? 0)
        let percent = v["context_percent"]?.int ?? Int((Double(used) / Double(max) * 100).rounded())
        self.init(used: Swift.min(used, max), max: max, percent: Swift.min(100, Swift.max(0, percent)),
                  estimated: v["context_estimated"]?.bool ?? false, compressions: v["compressions"]?.int)
    }
}

/// The `session.info` fields the composer controls show (`server.py` `_session_info`): the model and provider
/// the chat runs (a pick queued mid-turn is reported already), its reasoning effort, the effort the route
/// actually sends, and context usage.
public struct SessionInfoSnapshot: Sendable, Equatable {
    public var model: String
    public var provider: String
    /// `""` = provider default, `none` = thinking off.
    public var reasoningEffort: String
    /// The level the route's clamp sends (`ultra` may send `max`); `""` when unknown or equal.
    public var reasoningEffortWire: String
    public var usage: ContextUsage?

    public init(model: String, provider: String, reasoningEffort: String = "", reasoningEffortWire: String = "",
                usage: ContextUsage? = nil) {
        self.model = model; self.provider = provider; self.reasoningEffort = reasoningEffort
        self.reasoningEffortWire = reasoningEffortWire; self.usage = usage
    }

    /// nil for a payload with no model (an `info: {}` placeholder).
    public init?(_ v: JSONValue?) {
        guard let v, let model = v["model"]?.string, !model.isEmpty else { return nil }
        self.init(model: model, provider: v["provider"]?.string ?? "",
                  reasoningEffort: v["reasoning_effort"]?.string ?? "",
                  reasoningEffortWire: v["reasoning_effort_wire"]?.string ?? "",
                  usage: ContextUsage(v["usage"]))
    }
}

/// `session.context_breakdown`: the context window split by category (empty before the agent is built).
public struct ContextBreakdown: Sendable, Equatable {
    public struct Category: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let tokens: Int
        public init(id: String, label: String, tokens: Int) { self.id = id; self.label = label; self.tokens = tokens }
    }

    public var categories: [Category]
    public var usage: ContextUsage?

    public init(categories: [Category], usage: ContextUsage?) { self.categories = categories; self.usage = usage }

    public init(_ v: JSONValue) {
        categories = (v["categories"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            return Category(id: id, label: c["label"]?.string ?? id, tokens: c["tokens"]?.int ?? 0)
        }
        usage = ContextUsage(v)
    }
}

/// `model.options {session_id, profile, explicit_only: true}`: the picker inventory, as Desktop requests it.
public struct ModelCatalog: Sendable, Equatable {
    public struct Capabilities: Sendable, Equatable {
        public var reasoning: Bool
        public var canDisableReasoning: Bool
        public init(reasoning: Bool, canDisableReasoning: Bool) {
            self.reasoning = reasoning; self.canDisableReasoning = canDisableReasoning
        }
    }

    public struct Provider: Sendable, Equatable, Identifiable {
        public var id: String { slug }
        public let slug: String
        public let name: String
        public let models: [String]
        public let capabilities: [String: Capabilities]
        public init(slug: String, name: String, models: [String], capabilities: [String: Capabilities] = [:]) {
            self.slug = slug; self.name = name; self.models = models; self.capabilities = capabilities
        }
    }

    public var providers: [Provider]
    /// The chat's current pick as the catalog reports it.
    public var model: String
    public var provider: String

    public init(providers: [Provider], model: String = "", provider: String = "") {
        self.providers = providers; self.model = model; self.provider = provider
    }

    public init(_ v: JSONValue) {
        providers = (v["providers"]?.array ?? []).compactMap { p in
            guard let slug = p["slug"]?.string, !slug.isEmpty else { return nil }
            var caps: [String: Capabilities] = [:]
            for (model, c) in p["capabilities"]?.object ?? [:] {
                caps[model] = Capabilities(reasoning: c["reasoning"]?.bool ?? true,
                                           canDisableReasoning: c["can_disable_reasoning"]?.bool ?? false)
            }
            let models = (p["models"]?.array ?? []).compactMap(\.string)
            guard !models.isEmpty else { return nil }
            return Provider(slug: slug, name: p["name"]?.string ?? slug, models: models, capabilities: caps)
        }
        model = v["model"]?.string ?? ""
        provider = v["provider"]?.string ?? ""
    }

    /// The row for `provider`, matched like Desktop's `catalogProviderMatches` (slug, case-insensitive; a
    /// `custom:<key>` pick also finds a bare `<key>` row).
    public func row(for provider: String) -> Provider? {
        let p = provider.lowercased()
        let bare = p.hasPrefix("custom:") ? String(p.dropFirst("custom:".count)) : p
        return providers.first { $0.slug.lowercased() == p } ?? providers.first { $0.slug.lowercased() == bare }
    }

    /// What the catalog says the pick supports; nil while unknown (callers assume reasoning, like Desktop).
    public func capabilities(provider: String, model: String) -> Capabilities? {
        row(for: provider)?.capabilities[model]
    }
}

/// `config.set {key: "model"}` reply (`_cfgset_model_ok` / `_kv`).
public struct ModelSwitchOutcome: Sendable, Equatable {
    public var value: String
    /// The pick is expensive: nothing was applied; resend with `confirm_expensive_model` once the user agrees.
    public var confirmRequired: Bool
    public var confirmMessage: String
    /// Picked during a turn: the gateway applies it at the next turn start (`session.info` reports it).
    public var deferred: Bool
    public var warning: String

    public init(value: String, confirmRequired: Bool = false, confirmMessage: String = "", deferred: Bool = false,
                warning: String = "") {
        self.value = value; self.confirmRequired = confirmRequired; self.confirmMessage = confirmMessage
        self.deferred = deferred; self.warning = warning
    }

    public init(_ v: JSONValue) {
        let message = v["confirm_message"]?.string ?? ""
        self.init(value: v["value"]?.string ?? "", confirmRequired: v["confirm_required"]?.bool ?? !message.isEmpty,
                  confirmMessage: message, deferred: v["deferred"]?.bool ?? false, warning: v["warning"]?.string ?? "")
    }
}

/// Compaction phase from the chat's own events, like Desktop's `store/compaction.ts`: `status.update`
/// `compacting` (auto) / `compressing` (manual `/compress`) starts it; `compacted` / `ready`, the turn's
/// end, an error, `session.info running:false`, or the first model output after it (the turn resumed) ends it.
public enum CompactionPhase {
    /// The phase after `e`, given the phase before it.
    public static func next(_ active: Bool, after e: ChatEvent) -> Bool {
        switch e {
        case .status(let kind, _):
            if kind == "compacting" || kind == "compressing" { return true }
            if kind == "compacted" || kind == "ready" { return false }
            return active
        case .delta, .interim, .reasoning, .reasoningAvailable, .toolStarted, .completed, .error, .disconnected,
             .idle, .resumed:
            return false
        default:
            return active
        }
    }
}

extension BotChatSession {
    /// The session info the chat was opened with (`info` of the resume / create reply).
    public var openInfo: SessionInfoSnapshot? { SessionInfoSnapshot(createInfo) }

    /// `session.redirect {session_id, text}` → `redirected` (the running turn now answers `text`), `queued`
    /// (turn-build window or compression in flight: it runs next) or `rejected`.
    public func redirect(_ text: String) async throws -> String {
        do {
            let r = try await backend.client.call("session.redirect", ["session_id": .string(sessionId), "text": .string(text)])
            return r["status"]?.string ?? "rejected"
        } catch let e as GatewayClient.RPCError where e.code == BotChatError.sessionNotOwnedCode {
            throw BotChatError.sessionNotOwned(bot: bot.title)
        }
    }

    /// `model.options` scoped to this chat (its live provider layered over the bot's profile config).
    public func modelOptions() async throws -> ModelCatalog {
        ModelCatalog(try await backend.client.call("model.options", [
            "session_id": .string(sessionId), "profile": .string(bot.name), "explicit_only": true,
        ]))
    }

    /// The `config.set` model value: always `--session`, so a pick changes this chat only and never writes a
    /// profile's `config.yaml` (`resolve_persist_behavior`: `--session` → never persist).
    public static func modelSwitchValue(model: String, provider: String) -> String {
        "\(model) --provider \(provider) --session"
    }

    /// `config.set {session_id, key: "model", value: "<model> --provider <p> --session"}` (Desktop's
    /// `selectModel`, session scope). `confirmExpensive` answers an earlier `confirm_required`.
    public func switchModel(model: String, provider: String, confirmExpensive: Bool = false) async throws -> ModelSwitchOutcome {
        var p: [String: JSONValue] = [
            "session_id": .string(sessionId), "key": "model",
            "value": .string(Self.modelSwitchValue(model: model, provider: provider)),
        ]
        if confirmExpensive { p["confirm_expensive_model"] = true }
        return ModelSwitchOutcome(try await backend.client.call("config.set", .object(p)))
    }

    /// `config.set {session_id, key: "reasoning", value: <level>}` with no `scope`: session-scoped
    /// (`create_reasoning_override`), exactly what Desktop's effort menu sends. Returns the level applied.
    public func setReasoning(_ effort: String) async throws -> String {
        guard ReasoningEffort.isLevel(effort) else { throw BotChatError.lookupFailed("unknown reasoning level") }
        let r = try await backend.client.call("config.set", [
            "session_id": .string(sessionId), "key": "reasoning", "value": .string(effort),
        ])
        return r["value"]?.string ?? effort
    }

    /// `session.usage`: the chat's context figures (nil before its first request).
    public func usage() async throws -> ContextUsage? {
        ContextUsage(try await backend.client.call("session.usage", ["session_id": .string(sessionId)]))
    }

    /// `session.context_breakdown`.
    public func contextBreakdown() async throws -> ContextBreakdown {
        ContextBreakdown(try await backend.client.call("session.context_breakdown", ["session_id": .string(sessionId)]))
    }
}
