import Foundation

// Kanban board management and orchestration settings (roadmap K7): the kanban plugin's boards CRUD
// (`POST /boards`, `PATCH /boards/{slug}`, `DELETE /boards/{slug}`), board transfer
// (`POST /boards/{slug}/export`, `POST /boards/import`), `GET`/`PUT /orchestration` and `GET /profiles`
// (`plugins/kanban/dashboard/plugin_api.py`). Shapes follow Hermes Desktop (`board-switcher.tsx`,
// `transfer.ts`, `orchestration.tsx`).
//
// Board transfer exchanges filesystem PATHS, not bytes: the backend reads and writes the archive itself
// (Desktop `transfer.ts`). That is sound here because the app only talks to a loopback backend
// (`PluginREST` refuses any other host), so a path picked in a save/open panel names the same file for both.
// `POST /boards/{slug}/switch` (the server-wide current board) is still never sent.

/// `POST /boards/{slug}/export` → `{board, archive, size, counts}` (`kanban_transfer.export_board`).
public struct KanbanBoardExport: Sendable, Equatable {
    public let board: String
    /// The archive written (a `.tar.gz`).
    public let archive: String
    public let size: Int

    public init(json j: JSONValue) {
        board = j["board"]?.nonEmptyString ?? ""
        archive = j["archive"]?.nonEmptyString ?? ""
        size = max(0, j["size"]?.intValue ?? 0)
    }
}

/// `POST /boards/import` → `{board, requested_board, renamed, name, warnings, current, ...}`: the NEW board
/// the archive landed as (its slug auto-suffixes on collision).
public struct KanbanBoardImport: Sendable, Equatable {
    public let board: String
    public let name: String
    public let renamed: Bool
    public let requestedBoard: String?
    /// Plain-words notes (tasks parked for an unresolvable workspace, dropped attachments).
    public let warnings: [String]

    public init(json j: JSONValue) {
        board = j["board"]?.nonEmptyString ?? ""
        name = j["name"]?.nonEmptyString ?? j["board"]?.nonEmptyString ?? ""
        renamed = j["renamed"]?.bool ?? false
        requestedBoard = j["requested_board"]?.nonEmptyString
        warnings = (j["warnings"]?.array ?? []).compactMap(\.nonEmptyString)
    }
}

/// `DELETE /boards/{slug}` → `{result: {slug, action, new_path}, current}`: archived (recoverable) unless
/// hard-deleted, which the app never asks for.
public struct KanbanBoardRemoval: Sendable, Equatable {
    public let action: String
    public let newPath: String?
    /// The server's current board afterwards (it falls back to `default` when the removed one was current).
    public let current: String?

    public init(json j: JSONValue) {
        action = j["result"]?["action"]?.nonEmptyString ?? "archived"
        newPath = j["result"]?["new_path"]?.nonEmptyString
        current = j["current"]?.nonEmptyString
    }
}

/// `GET /orchestration` (`get_orchestration_settings`): the `kanban.*` knobs of config.yaml. An empty profile
/// means "not set": the resolved value (the active profile) applies.
public struct KanbanOrchestration: Sendable, Equatable {
    public let orchestratorProfile: String
    public let defaultAssignee: String
    public let autoDecompose: Bool
    public let autoPromoteChildren: Bool
    public let resolvedOrchestratorProfile: String
    public let resolvedDefaultAssignee: String
    public let activeProfile: String

    public init(json j: JSONValue) {
        orchestratorProfile = j["orchestrator_profile"]?.string ?? ""
        defaultAssignee = j["default_assignee"]?.string ?? ""
        autoDecompose = j["auto_decompose"]?.bool ?? true
        autoPromoteChildren = j["auto_promote_children"]?.bool ?? true
        activeProfile = j["active_profile"]?.nonEmptyString ?? "default"
        resolvedOrchestratorProfile = j["resolved_orchestrator_profile"]?.nonEmptyString ?? activeProfile
        resolvedDefaultAssignee = j["resolved_default_assignee"]?.nonEmptyString ?? activeProfile
    }
}

/// `PUT /orchestration` (`OrchestrationSettingsBody`): only the fields set are written; an empty profile
/// clears that override.
public struct KanbanOrchestrationPatch: Sendable, Equatable {
    public var orchestratorProfile: String?
    public var defaultAssignee: String?
    public var autoDecompose: Bool?
    public var autoPromoteChildren: Bool?

    public init(orchestratorProfile: String? = nil, defaultAssignee: String? = nil, autoDecompose: Bool? = nil,
                autoPromoteChildren: Bool? = nil) {
        self.orchestratorProfile = orchestratorProfile; self.defaultAssignee = defaultAssignee
        self.autoDecompose = autoDecompose; self.autoPromoteChildren = autoPromoteChildren
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let orchestratorProfile { o["orchestrator_profile"] = .string(orchestratorProfile) }
        if let defaultAssignee { o["default_assignee"] = .string(defaultAssignee) }
        if let autoDecompose { o["auto_decompose"] = .bool(autoDecompose) }
        if let autoPromoteChildren { o["auto_promote_children"] = .bool(autoPromoteChildren) }
        return .object(o)
    }
}

/// `GET /profiles` rows (`list_profile_roster`): the roster the decomposer routes across.
public struct KanbanProfile: Sendable, Equatable, Identifiable {
    public let name: String
    public let isDefault: Bool
    public let description: String
    public var id: String { name }

    public init?(json j: JSONValue) {
        guard let name = j["name"]?.nonEmptyString else { return nil }
        self.name = name
        isDefault = j["is_default"]?.bool ?? false
        description = j["description"]?.string ?? ""
    }
}

extension KanbanAPI {
    /// The board the server never removes (`remove_board`: "the 'default' board cannot be removed").
    public static let defaultBoard = "default"
    /// Board export/import run on the backend and may copy many attachments.
    public static let transferTimeout: TimeInterval = 120

    /// A board slug from a display name, as Desktop's New Board dialog derives it: lowercased, runs of other
    /// characters become one `-`, no leading or trailing `-`, at most 64 characters (`_BOARD_SLUG_RE`,
    /// `hermes_cli/kanban_db.py`: `^[a-z0-9][a-z0-9\-_]{0,63}$`). "" when nothing usable is left.
    public static func boardSlug(fromName name: String) -> String {
        var out = "", dash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if dash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        return String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `POST /boards {slug, name}` (Desktop `createBoard`). Idempotent on the server: an existing slug answers
    /// that board. Never switches the server's current board.
    @discardableResult
    public func createBoard(slug: String, name: String) async throws -> KanbanBoardSummary? {
        let r = try await rest.post("/boards", body: ["slug": .string(slug), "name": .string(name)])
        return r["board"]?.nonNull.flatMap { try? KanbanBoardSummary(json: $0) }
    }

    /// `PATCH /boards/{slug} {name}` (Desktop's rename dialog: the slug is immutable).
    @discardableResult
    public func renameBoard(_ slug: String, name: String) async throws -> KanbanBoardSummary? {
        let r = try await rest.patch("/boards/" + PluginREST.segment(slug), body: ["name": .string(name)])
        return r["board"]?.nonNull.flatMap { try? KanbanBoardSummary(json: $0) }
    }

    /// `DELETE /boards/{slug}` without `delete=true`: the board is archived (recoverable), as Desktop does.
    /// The server refuses `default` (400).
    public func archiveBoard(_ slug: String) async throws -> KanbanBoardRemoval {
        KanbanBoardRemoval(json: try await rest.delete("/boards/" + PluginREST.segment(slug)))
    }

    /// `POST /boards/{slug}/export {output}`: the backend writes the archive to `output` (attachments
    /// included, logs not: the server defaults).
    public func exportBoard(_ slug: String, to output: String) async throws -> KanbanBoardExport {
        var r = rest
        r.timeout = max(r.timeout, Self.transferTimeout)
        return KanbanBoardExport(json: try await r.post("/boards/" + PluginREST.segment(slug) + "/export",
                                                        body: ["output": .string(output)]))
    }

    /// `POST /boards/import {archive}`: the archive becomes a NEW board; the current board is not switched.
    public func importBoard(archive: String) async throws -> KanbanBoardImport {
        var r = rest
        r.timeout = max(r.timeout, Self.transferTimeout)
        return KanbanBoardImport(json: try await r.post("/boards/import", body: ["archive": .string(archive)]))
    }

    /// `GET /orchestration`.
    public func orchestration() async throws -> KanbanOrchestration {
        KanbanOrchestration(json: try await rest.get("/orchestration"))
    }

    /// `PUT /orchestration`: answers the resolved settings. An unknown profile is refused with 400.
    public func setOrchestration(_ patch: KanbanOrchestrationPatch) async throws -> KanbanOrchestration {
        KanbanOrchestration(json: try await rest.send(.put, "/orchestration", body: patch.json))
    }

    /// `GET /profiles`.
    public func profiles() async throws -> [KanbanProfile] {
        (try await rest.get("/profiles")["profiles"]?.array ?? []).compactMap(KanbanProfile.init(json:))
    }
}
