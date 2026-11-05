import Foundation

// Kanban AI actions and per-task model override (roadmap K6): the kanban plugin's auxiliary-model routes
// (`plugins/kanban/dashboard/plugin_api.py`: `POST /tasks/{id}/estimate`, `POST /estimate`,
// `POST /tasks/{id}/decompose`, `POST /tasks/{id}/specify`), `GET /model-options`, and the override fields of
// `PATCH /tasks/{id}` (`UpdateTaskBody.model_override` / `provider_override` / `reasoning_effort` and their
// `clear_*` flags). Request bodies follow Hermes Desktop (`apps/desktop/src/plugins/kanban/api.ts`,
// `model-override.tsx`).
//
// None of the AI routes answers an HTTP error for an expected refusal: `{ok: false, reason}` comes back with
// 200 and is rendered inline. Decompose and Specify only act on a card in `triage`
// (`hermes_cli/kanban_specify.py` `_load_triage_task`) and apply their result themselves: there is no
// proposal to confirm, so the app asks before it sends them.

/// `POST /tasks/{id}/estimate`, `POST /estimate` (`_run_estimate`): a rough token + complexity read from the
/// auxiliary model, never a cost. `ok: false` carries `reason`.
public struct KanbanEstimate: Sendable, Equatable {
    public let ok: Bool
    public let estTokens: Int
    /// `S`, `M` or `L`; nil when the model gave something else.
    public let complexity: String?
    public let rationale: String?
    public let model: String?
    public let reason: String?

    public init(json j: JSONValue) {
        ok = j["ok"]?.bool ?? false
        estTokens = max(0, j["est_tokens"]?.intValue ?? 0)
        let c = j["complexity"]?.nonEmptyString?.uppercased()
        complexity = c.flatMap { ["S", "M", "L"].contains($0) ? $0 : nil }
        rationale = j["rationale"]?.nonEmptyString
        model = j["model"]?.nonEmptyString
        reason = j["reason"]?.nonEmptyString
    }
}

/// `POST /tasks/{id}/decompose` (`decompose_task_endpoint`): `{ok, task_id, reason, fanout, child_ids,
/// new_title}`. With `fanout` the card became the parent of `childIds`; without it the decomposer rewrote the
/// card as one task (`_apply_single`).
public struct KanbanDecomposeResult: Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public let fanout: Bool
    public let childIds: [String]
    public let newTitle: String?

    public init(json j: JSONValue) {
        ok = j["ok"]?.bool ?? false
        reason = j["reason"]?.nonEmptyString
        fanout = j["fanout"]?.bool ?? false
        childIds = (j["child_ids"]?.array ?? []).compactMap(\.nonEmptyString)
        newTitle = j["new_title"]?.nonEmptyString
    }
}

/// `POST /tasks/{id}/specify` (`specify_task_endpoint`): `{ok, task_id, reason, new_title}`. On success the
/// server already rewrote the title/body and promoted the card from triage to todo.
public struct KanbanSpecifyResult: Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public let newTitle: String?

    public init(json j: JSONValue) {
        ok = j["ok"]?.bool ?? false
        reason = j["reason"]?.nonEmptyString
        newTitle = j["new_title"]?.nonEmptyString
    }
}

/// One `GET /model-options` provider: `{slug, label, models}` (only providers with models are listed). Model
/// entries are strings; an object entry's `id` / `model` / `name` is accepted too.
public struct KanbanModelProvider: Sendable, Equatable, Identifiable {
    public let slug: String
    public let label: String
    public let models: [String]
    public var id: String { slug }

    public init?(json j: JSONValue) {
        guard let slug = j["slug"]?.nonEmptyString else { return nil }
        self.slug = slug
        label = j["label"]?.nonEmptyString ?? slug
        models = (j["models"]?.array ?? []).compactMap { m in
            m.nonEmptyString ?? m["id"]?.nonEmptyString ?? m["model"]?.nonEmptyString ?? m["name"]?.nonEmptyString
        }
        guard !models.isEmpty else { return nil }
    }

    static func list(_ v: JSONValue?) -> [KanbanModelProvider] { (v?.array ?? []).compactMap(KanbanModelProvider.init(json:)) }
}

/// A card's model override (Desktop `TaskModelOverride`). Empty strings inherit the assigned profile's own
/// model and reasoning effort, which is what every card does until one is pinned.
public struct KanbanModelOverride: Sendable, Equatable {
    public var model: String
    public var provider: String
    /// "" = the profile's effort, `none` = thinking off, else one of `efforts`.
    public var effort: String

    /// `VALID_REASONING_EFFORTS` (`hermes_constants.py`) plus `none` (`normalize_reasoning_effort`,
    /// `hermes_cli/kanban_db.py`): anything else is refused by the server.
    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    public static let inherit = KanbanModelOverride()

    public init(model: String = "", provider: String = "", effort: String = "") {
        self.model = model; self.provider = provider; self.effort = effort
    }

    public var isInherited: Bool {
        model.trimmingCharacters(in: .whitespaces).isEmpty && provider.trimmingCharacters(in: .whitespaces).isEmpty
            && effort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The `PATCH /tasks/{id}` fields (Desktop `overridePatch`): an empty part is cleared with its explicit
    /// `clear_*` flag, because `null` in a PATCH body means "not sent".
    public var patchJSON: JSONValue {
        let m = model.trimmingCharacters(in: .whitespaces), p = provider.trimmingCharacters(in: .whitespaces)
        let e = effort.trimmingCharacters(in: .whitespaces)
        var o: [String: JSONValue] = [:]
        if m.isEmpty {
            o["clear_model_override"] = .bool(true)
        } else {
            o["model_override"] = .string(m)
            if !p.isEmpty { o["provider_override"] = .string(p) }
        }
        if e.isEmpty { o["clear_reasoning_effort"] = .bool(true) } else { o["reasoning_effort"] = .string(e) }
        return .object(o)
    }
}

extension KanbanTask {
    /// The card's pinned model, provider and effort (`model_override`, `provider_override`, `reasoning_effort`
    /// of `asdict(Task)`); all empty = the profile decides.
    public var modelOverride: KanbanModelOverride {
        KanbanModelOverride(model: raw["model_override"]?.nonEmptyString ?? "",
                            provider: raw["provider_override"]?.nonEmptyString ?? "",
                            effort: raw["reasoning_effort"]?.nonEmptyString ?? "")
    }
}

extension KanbanAPI {
    /// The estimator's own LLM timeout is 60 s (`_run_estimate`); specify uses 120 s and decompose 180 s
    /// (`kanban_specify.py`, `kanban_decompose.py`). The HTTP wait is a little longer than each.
    public static let estimateTimeout: TimeInterval = 75
    public static let specifyTimeout: TimeInterval = 135
    public static let decomposeTimeout: TimeInterval = 195

    private func waiting(_ seconds: TimeInterval) -> PluginREST {
        var r = rest
        r.timeout = max(r.timeout, seconds)
        return r
    }

    /// `POST /tasks/{id}/estimate {}` (Desktop `estimateTask`): makes a model call.
    public func estimate(taskId: String, board: String?) async throws -> KanbanEstimate {
        KanbanEstimate(json: try await waiting(Self.estimateTimeout).post(Self.taskPath(taskId) + "/estimate",
                                                                          query: Self.boardQuery(board), body: [:]))
    }

    /// `POST /estimate {title, body?}` (Desktop `estimateNew`): before a task exists. Not board-scoped.
    public func estimate(title: String, body: String?) async throws -> KanbanEstimate {
        var o: [String: JSONValue] = ["title": .string(title)]
        if let body, !body.isEmpty { o["body"] = .string(body) }
        return KanbanEstimate(json: try await waiting(Self.estimateTimeout).post("/estimate", body: .object(o)))
    }

    /// `POST /tasks/{id}/decompose {author}`: fans a triage card out into child tasks.
    public func decompose(taskId: String, board: String?, author: String?) async throws -> KanbanDecomposeResult {
        KanbanDecomposeResult(json: try await waiting(Self.decomposeTimeout).post(
            Self.taskPath(taskId) + "/decompose", query: Self.boardQuery(board), body: Self.authorBody(author)))
    }

    /// `POST /tasks/{id}/specify {author}`: rewrites a triage card's title and body and moves it to todo.
    public func specify(taskId: String, board: String?, author: String?) async throws -> KanbanSpecifyResult {
        KanbanSpecifyResult(json: try await waiting(Self.specifyTimeout).post(
            Self.taskPath(taskId) + "/specify", query: Self.boardQuery(board), body: Self.authorBody(author)))
    }

    /// `GET /model-options`: providers and their models for the override menu. Empty when Hermes lists none
    /// (the menu then offers a typed model name, as Desktop falls back to free text).
    public func modelOptions() async throws -> [KanbanModelProvider] {
        KanbanModelProvider.list(try await rest.get("/model-options")["providers"])
    }

    /// `PATCH /tasks/{id}` with the override fields only. Returns the updated task.
    @discardableResult
    public func setModelOverride(_ id: String, _ override: KanbanModelOverride, board: String?) async throws -> KanbanTask? {
        let r = try await rest.patch(Self.taskPath(id), query: Self.boardQuery(board), body: override.patchJSON)
        return try r["task"]?.nonNull.map { try KanbanTask(json: $0) }
    }

    static func authorBody(_ author: String?) -> JSONValue {
        guard let author, !author.isEmpty else { return [:] }
        return ["author": .string(author)]
    }
}
