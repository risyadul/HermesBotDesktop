import Foundation

/// Typed calls to the built-in kanban plugin, `/api/plugins/kanban/...`
/// (`~/.hermes/hermes-agent/plugins/kanban/dashboard/plugin_api.py`). Request bodies match what Hermes
/// Desktop sends (`apps/desktop/src/plugins/kanban/api.ts`). Like Desktop, every board-scoped call passes
/// `?board=<slug>` when a slug is given, so the app's selection never flips the server-wide current board
/// (`POST /boards/{slug}/switch` is not used). `board: nil` = the server's current board.
public struct KanbanAPI: Sendable {
    public static let pluginName = "kanban"
    /// `CommentBody.author` (`plugin_api.py:797-799`; Desktop sends `"desktop"`).
    public static let commentAuthor = "hermes-bot-app"
    /// Desktop's drawer log tail (`fetchLog`, api.ts: 16 KiB).
    public static let defaultLogTail = 16_384

    public let rest: PluginREST

    public init(access: SessionRESTAccess, timeout: TimeInterval = 15) {
        rest = PluginREST(access: access, plugin: Self.pluginName, timeout: timeout)
    }

    public init(rest: PluginREST) { self.rest = rest }

    // MARK: - reads

    /// `GET /boards` (`list_boards`, `plugin_api.py:1411-1427`).
    public func boards(includeArchived: Bool = false) async throws -> KanbanBoardList {
        try await rest.send(.get, "/boards", query: includeArchived ? [.init(name: "include_archived", value: "true")] : [],
                            as: KanbanBoardList.self)
    }

    /// `GET /board` (`get_board_endpoint`, `plugin_api.py:359-376`). `includeArchived` adds the `archived`
    /// column (Desktop's "Show archived"); `tenant` filters to one tenant.
    public func board(_ board: String?, includeArchived: Bool = false, tenant: String? = nil) async throws -> KanbanBoard {
        var q = Self.boardQuery(board)
        if includeArchived { q.append(.init(name: "include_archived", value: "true")) }
        if let tenant, !tenant.isEmpty { q.append(.init(name: "tenant", value: tenant)) }
        return try await rest.send(.get, "/board", query: q, as: KanbanBoard.self)
    }

    /// `GET /tasks/{id}` (`get_task`, `plugin_api.py:379-410`): task + comments, events, links, runs.
    public func task(_ id: String, board: String?) async throws -> KanbanTaskDetail {
        try await rest.send(.get, Self.taskPath(id), query: Self.boardQuery(board), as: KanbanTaskDetail.self)
    }

    /// `GET /tasks/{id}/log?tail=` (`get_task_log`, `plugin_api.py:1255-1266`). `tailBytes: nil` = whole log.
    public func log(taskId: String, board: String?, tailBytes: Int? = KanbanAPI.defaultLogTail) async throws -> KanbanWorkerLog {
        var q = Self.boardQuery(board)
        if let tailBytes { q.append(.init(name: "tail", value: String(max(1, tailBytes)))) }
        return try await rest.send(.get, Self.taskPath(taskId) + "/log", query: q, as: KanbanWorkerLog.self)
    }

    /// `GET /assignees` (`get_assignees`, `plugin_api.py:1247-1252`).
    public func assignees(board: String?) async throws -> [KanbanAssignee] {
        let r = try await rest.get("/assignees", query: Self.boardQuery(board))
        return (r["assignees"]?.array ?? []).compactMap(KanbanAssignee.init(json:))
    }

    // MARK: - writes

    /// `POST /tasks` (`CreateTaskBody`, `plugin_api.py:414-461`). The server derives the status (`triage`
    /// when `draft.triage`, else ready/todo by its rules); with `column` set and different from the created
    /// status, a follow-up `PATCH {status: column}` moves it, exactly as Desktop's per-column add does
    /// (board.tsx). `warning`: the dispatcher-presence banner for a ready, assigned task with no gateway.
    public func createTask(_ draft: KanbanTaskDraft, board: String?, column: String? = nil) async throws -> KanbanCreateResult {
        let r = try await rest.post("/tasks", query: Self.boardQuery(board), body: draft.json)
        var task = try r["task"]?.nonNull.map { try KanbanTask(json: $0) }
        if let created = task, let column, !column.isEmpty, created.status != column {
            task = try await updateTask(created.id, board: board, KanbanTaskPatch(status: column)) ?? created
        }
        return KanbanCreateResult(task: task, warning: r["warning"]?.nonEmptyString)
    }

    /// `PATCH /tasks/{id}` (`UpdateTaskBody`, `plugin_api.py:533-552,692-716`): only the fields set in
    /// `patch` are sent. 409 (`.http(409, detail)`) when a transition is refused; the detail names the
    /// blocking parents. Returns the updated task.
    @discardableResult
    public func updateTask(_ id: String, board: String?, _ patch: KanbanTaskPatch) async throws -> KanbanTask? {
        let r = try await rest.patch(Self.taskPath(id), query: Self.boardQuery(board), body: patch.json)
        return try r["task"]?.nonNull.map { try KanbanTask(json: $0) }
    }

    /// Column move (Desktop's drag-drop / status menu: `patchTask(id, {status})`). `running` is refused by
    /// the server (400); use the dispatcher.
    @discardableResult
    public func move(_ id: String, to status: String, board: String?) async throws -> KanbanTask? {
        try await updateTask(id, board: board, KanbanTaskPatch(status: status))
    }

    /// Desktop's drawer "Archive": `PATCH {status: "archived"}` (`_patch_status`, `plugin_api.py:641-642`).
    @discardableResult
    public func archive(_ id: String, board: String?) async throws -> KanbanTask? {
        try await move(id, to: "archived", board: board)
    }

    @discardableResult
    public func setPriority(_ id: String, _ priority: Int, board: String?) async throws -> KanbanTask? {
        try await updateTask(id, board: board, KanbanTaskPatch(priority: priority))
    }

    /// Desktop's drawer assignee picker: `POST /tasks/{id}/reassign {profile, reclaim_first: true}`
    /// (`reassign_task_endpoint`, `plugin_api.py:1033-1052`; api.ts `reassignTask`). `profile: nil` unassigns.
    /// Reclaiming first releases a live worker claim, which a plain `PATCH {assignee}` refuses with 409.
    public func reassign(_ id: String, to profile: String?, board: String?, reclaimFirst: Bool = true) async throws {
        _ = try await rest.post(Self.taskPath(id) + "/reassign", query: Self.boardQuery(board),
                                body: ["profile": .string(profile ?? ""), "reclaim_first": .bool(reclaimFirst)])
    }

    /// `POST /tasks/{id}/comments {author, body}` (`add_comment`, `plugin_api.py:802-809`). Blank body: 400.
    public func addComment(taskId: String, body: String, board: String?, author: String = KanbanAPI.commentAuthor) async throws {
        _ = try await rest.post(Self.taskPath(taskId) + "/comments", query: Self.boardQuery(board),
                                body: ["author": .string(author), "body": .string(body)])
    }

    // MARK: - helpers

    static func boardQuery(_ board: String?) -> [URLQueryItem] {
        guard let board, !board.isEmpty else { return [] }
        return [URLQueryItem(name: "board", value: board)]
    }

    static func taskPath(_ id: String) -> String { "/tasks/" + PluginREST.segment(id) }
}

/// `POST /tasks` answer.
public struct KanbanCreateResult: Sendable, Equatable {
    public let task: KanbanTask?
    public let warning: String?
}

/// `CreateTaskBody` (`plugin_api.py:414-432`). Unset optionals are omitted, like Desktop's `undefined`.
public struct KanbanTaskDraft: Sendable, Equatable {
    public var title: String
    public var body: String?
    public var assignee: String?
    public var priority: Int
    public var triage: Bool
    public var parents: [String]
    public var tenant: String?
    public var skills: [String]?

    public init(title: String, body: String? = nil, assignee: String? = nil, priority: Int = 0, triage: Bool = false,
                parents: [String] = [], tenant: String? = nil, skills: [String]? = nil) {
        self.title = title; self.body = body; self.assignee = assignee; self.priority = priority
        self.triage = triage; self.parents = parents; self.tenant = tenant; self.skills = skills
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["title": .string(title), "priority": .number(Double(priority)), "triage": .bool(triage)]
        if let body, !body.isEmpty { o["body"] = .string(body) }
        if let assignee, !assignee.isEmpty { o["assignee"] = .string(assignee) }
        if !parents.isEmpty { o["parents"] = .array(parents.map(JSONValue.string)) }
        if let tenant, !tenant.isEmpty { o["tenant"] = .string(tenant) }
        if let skills, !skills.isEmpty { o["skills"] = .array(skills.map(JSONValue.string)) }
        return .object(o)
    }
}

/// `UpdateTaskBody` (`plugin_api.py:533-552`): `nil` = not sent (the server's PATCH semantics).
/// `assignee: ""` unassigns. `blockReason` goes with `status: "blocked"`/`"scheduled"`.
public struct KanbanTaskPatch: Sendable, Equatable {
    public var status: String?
    public var assignee: String?
    public var priority: Int?
    public var title: String?
    public var body: String?
    public var blockReason: String?

    public init(status: String? = nil, assignee: String? = nil, priority: Int? = nil, title: String? = nil,
                body: String? = nil, blockReason: String? = nil) {
        self.status = status; self.assignee = assignee; self.priority = priority
        self.title = title; self.body = body; self.blockReason = blockReason
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let status { o["status"] = .string(status) }
        if let assignee { o["assignee"] = .string(assignee) }
        if let priority { o["priority"] = .number(Double(priority)) }
        if let title { o["title"] = .string(title) }
        if let body { o["body"] = .string(body) }
        if let blockReason { o["block_reason"] = .string(blockReason) }
        return .object(o)
    }
}
