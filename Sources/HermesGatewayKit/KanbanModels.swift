import Foundation

// Wire models of the built-in kanban plugin (`~/.hermes/hermes-agent/plugins/kanban/dashboard/plugin_api.py`).
// Decoding is lenient: only `id` (tasks, comments) and `slug` (boards) are required; every other field
// tolerates absence or an unexpected type, and unknown keys are ignored. Tasks keep the raw object
// (`raw`) for fields not modelled here. Timestamps are epoch seconds (ints on the wire).

/// One card. `status` is its column name. Built by `_task_dict` (`plugin_api.py:181-194`: `asdict(Task)`
/// from `hermes_cli/kanban_db.py:621-681` + `age`, `latest_summary`, `current_run_started_at`), plus the
/// board-only rollups `link_counts`, `comment_count`, `progress`, `warnings` (`get_board`, `:338-342`).
public struct KanbanTask: Sendable, Equatable, Identifiable, Decodable {
    public struct LinkCounts: Sendable, Equatable { public let parents: Int; public let children: Int }
    public struct Progress: Sendable, Equatable { public let done: Int; public let total: Int }
    public struct Warnings: Sendable, Equatable { public let count: Int; public let highestSeverity: String? }

    public let id: String
    public let title: String
    public let body: String?
    public let status: String
    public let assignee: String?
    public let priority: Int
    public let tenant: String?
    public let createdBy: String?
    public let createdAt: Int?
    public let startedAt: Int?
    public let completedAt: Int?
    public let currentRunStartedAt: Int?
    public let lastHeartbeatAt: Int?
    public let workerPid: Int?
    /// Board cards carry a 200-char preview; `GET /tasks/{id}` the full text (`plugin_api.py:330-331,390-391`).
    public let latestSummary: String?
    public let result: String?
    public let blockKind: String?
    public let blockRecurrences: Int
    public let consecutiveFailures: Int
    public let lastFailureError: String?
    public let workspaceKind: String?
    public let workspacePath: String?
    public let branchName: String?
    public let commentCount: Int
    public let linkCounts: LinkCounts
    public let progress: Progress?
    public let warnings: Warnings?
    /// The task object as received (forward-compatible access to unmodelled fields).
    public let raw: JSONValue

    public init(from decoder: Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) throws {
        guard j.object != nil, let id = j["id"]?.nonEmptyString else { throw MissingField(key: "id", model: "KanbanTask") }
        self.id = id
        title = j["title"]?.string ?? ""
        body = j["body"]?.string
        status = j["status"]?.nonEmptyString ?? "todo"
        assignee = j["assignee"]?.nonEmptyString
        priority = j["priority"]?.intValue ?? 0
        tenant = j["tenant"]?.nonEmptyString
        createdBy = j["created_by"]?.nonEmptyString
        createdAt = j["created_at"]?.intValue
        startedAt = j["started_at"]?.intValue
        completedAt = j["completed_at"]?.intValue
        currentRunStartedAt = j["current_run_started_at"]?.intValue
        lastHeartbeatAt = j["last_heartbeat_at"]?.intValue
        workerPid = j["worker_pid"]?.intValue
        latestSummary = j["latest_summary"]?.nonEmptyString
        result = j["result"]?.nonEmptyString
        blockKind = j["block_kind"]?.nonEmptyString
        blockRecurrences = j["block_recurrences"]?.intValue ?? 0
        consecutiveFailures = j["consecutive_failures"]?.intValue ?? 0
        lastFailureError = j["last_failure_error"]?.nonEmptyString
        workspaceKind = j["workspace_kind"]?.nonEmptyString
        workspacePath = j["workspace_path"]?.nonEmptyString
        branchName = j["branch_name"]?.nonEmptyString
        commentCount = j["comment_count"]?.intValue ?? 0
        linkCounts = LinkCounts(parents: j["link_counts"]?["parents"]?.intValue ?? 0,
                                children: j["link_counts"]?["children"]?.intValue ?? 0)
        progress = j["progress"].flatMap { p in
            p["total"]?.intValue.map { Progress(done: p["done"]?.intValue ?? 0, total: $0) }
        }
        warnings = j["warnings"].flatMap { w in
            w["count"]?.intValue.map { Warnings(count: $0, highestSeverity: w["highest_severity"]?.nonEmptyString) }
        }
        raw = j
    }

    /// Lenient list: entries without an id are dropped, not fatal.
    static func list(_ v: JSONValue?) -> [KanbanTask] { (v?.array ?? []).compactMap { try? KanbanTask(json: $0) } }
}

/// One status column, tasks in server order (queue lanes: priority DESC, created_at ASC; `done`: newest
/// completed first — `plugin_api.py:345-351`).
public struct KanbanColumn: Sendable, Equatable, Identifiable {
    public let name: String
    public let tasks: [KanbanTask]
    public var id: String { name }
}

/// `GET /board` (`get_board`, `plugin_api.py:290-356`): `{columns:[{name, tasks}], tenants, assignees,
/// latest_event_id, now}`. Column order is the server's (`BOARD_COLUMNS` = the workflow's statuses,
/// `archived` last when requested) and is preserved.
public struct KanbanBoard: Sendable, Equatable, Decodable {
    public let columns: [KanbanColumn]
    public let tenants: [String]
    public let assignees: [String]
    public let latestEventId: Int
    public let now: Int?

    public init(from decoder: Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) throws {
        guard let cols = j["columns"]?.array else { throw MissingField(key: "columns", model: "KanbanBoard") }
        columns = cols.compactMap { c in
            c["name"]?.nonEmptyString.map { KanbanColumn(name: $0, tasks: KanbanTask.list(c["tasks"])) }
        }
        tenants = (j["tenants"]?.array ?? []).compactMap(\.nonEmptyString)
        assignees = (j["assignees"]?.array ?? []).compactMap(\.nonEmptyString)
        latestEventId = j["latest_event_id"]?.intValue ?? 0
        now = j["now"]?.intValue
    }

    public func task(id: String) -> KanbanTask? {
        for c in columns { if let t = c.tasks.first(where: { $0.id == id }) { return t } }
        return nil
    }
}

/// One entry of `GET /boards` (`list_boards`, `plugin_api.py:1411-1427`; metadata from
/// `read_board_metadata`, `hermes_cli/kanban_db_boards.py:38-66`).
public struct KanbanBoardSummary: Sendable, Equatable, Identifiable, Decodable {
    public let slug: String
    public let name: String
    public let description: String?
    public let icon: String?
    public let color: String?
    public let isCurrent: Bool
    public let archived: Bool
    /// `{status: count}`, archived tasks included; `total` excludes them.
    public let counts: [String: Int]
    public let total: Int
    public let defaultWorkdir: String?
    public let projectName: String?
    public var id: String { slug }

    public init(from decoder: Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) throws {
        guard let slug = j["slug"]?.nonEmptyString else { throw MissingField(key: "slug", model: "KanbanBoardSummary") }
        self.slug = slug
        name = j["name"]?.nonEmptyString ?? slug
        description = j["description"]?.nonEmptyString
        icon = j["icon"]?.nonEmptyString
        color = j["color"]?.nonEmptyString
        isCurrent = j["is_current"]?.bool ?? false
        archived = j["archived"]?.bool ?? false
        counts = (j["counts"]?.object ?? [:]).compactMapValues(\.intValue)
        total = j["total"]?.intValue ?? counts.filter { $0.key != "archived" }.values.reduce(0, +)
        defaultWorkdir = j["default_workdir"]?.nonEmptyString
        projectName = j["project_name"]?.nonEmptyString
    }
}

/// `GET /boards`: every board plus the server's current slug.
public struct KanbanBoardList: Sendable, Equatable, Decodable {
    public let boards: [KanbanBoardSummary]
    public let current: String?

    public init(from decoder: Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) throws {
        guard let list = j["boards"]?.array else { throw MissingField(key: "boards", model: "KanbanBoardList") }
        boards = list.compactMap { try? KanbanBoardSummary(json: $0) }
        current = j["current"]?.nonEmptyString
    }
}

/// `asdict(Comment)` (`kanban_db.py:743-756`).
public struct KanbanComment: Sendable, Equatable, Identifiable {
    public let id: Int
    public let author: String
    public let body: String
    public let createdAt: Int?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.intValue else { return nil }
        self.id = id
        author = j["author"]?.string ?? ""
        body = j["body"]?.string ?? ""
        createdAt = j["created_at"]?.intValue
    }
}

/// `asdict(Event)` (`kanban_db.py:781-797`). `payload` is open.
public struct KanbanEvent: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: String
    public let payload: JSONValue?
    public let createdAt: Int?
    public let runId: Int?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.intValue else { return nil }
        self.id = id
        kind = j["kind"]?.string ?? ""
        payload = j["payload"]?.nonNull
        createdAt = j["created_at"]?.intValue
        runId = j["run_id"]?.intValue
    }
}

/// `asdict(Run)` (`kanban_db.py:705-741`), one attempt at a task.
public struct KanbanRun: Sendable, Equatable, Identifiable {
    public let id: Int
    public let profile: String?
    public let status: String
    public let outcome: String?
    public let summary: String?
    public let error: String?
    public let startedAt: Int?
    public let endedAt: Int?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.intValue else { return nil }
        self.id = id
        profile = j["profile"]?.nonEmptyString
        status = j["status"]?.string ?? ""
        outcome = j["outcome"]?.nonEmptyString
        summary = j["summary"]?.nonEmptyString
        error = j["error"]?.nonEmptyString
        startedAt = j["started_at"]?.intValue
        endedAt = j["ended_at"]?.intValue
    }
}

/// `link_tasks` / `child_results` rows (`_link_tasks`, `plugin_api.py:276-287`; `:405-407`).
public struct KanbanLinkedTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    /// `child_results` only.
    public let latestSummary: String?

    init?(json j: JSONValue) {
        guard let id = j["id"]?.nonEmptyString else { return nil }
        self.id = id
        title = j["title"]?.string ?? ""
        status = j["status"]?.string ?? ""
        latestSummary = j["latest_summary"]?.nonEmptyString
    }
}

/// `GET /tasks/{id}` (`get_task`, `plugin_api.py:379-410`): the task (full `latest_summary`) and its
/// related collections, which are siblings of `task`.
public struct KanbanTaskDetail: Sendable, Equatable, Decodable {
    public let task: KanbanTask
    public let comments: [KanbanComment]
    public let events: [KanbanEvent]
    public let parents: [String]
    public let children: [String]
    /// Titles/statuses for `parents` + `children` (older backends omit it: fall back to the ids).
    public let linkTasks: [KanbanLinkedTask]
    public let childResults: [KanbanLinkedTask]
    public let runs: [KanbanRun]
    /// Attachment rows as received (not modelled in P0).
    public let attachments: [JSONValue]

    public init(from decoder: Decoder) throws { try self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) throws {
        guard let t = j["task"] else { throw MissingField(key: "task", model: "KanbanTaskDetail") }
        task = try KanbanTask(json: t)
        comments = (j["comments"]?.array ?? []).compactMap(KanbanComment.init(json:))
        events = (j["events"]?.array ?? []).compactMap(KanbanEvent.init(json:))
        parents = (j["links"]?["parents"]?.array ?? []).compactMap(\.nonEmptyString)
        children = (j["links"]?["children"]?.array ?? []).compactMap(\.nonEmptyString)
        linkTasks = (j["link_tasks"]?.array ?? []).compactMap(KanbanLinkedTask.init(json:))
        childResults = (j["child_results"]?.array ?? []).compactMap(KanbanLinkedTask.init(json:))
        runs = (j["runs"]?.array ?? []).compactMap(KanbanRun.init(json:))
        attachments = j["attachments"]?.array ?? []
    }
}

/// `GET /tasks/{id}/log` (`get_task_log`, `plugin_api.py:1255-1266`). The on-disk `path` is not kept.
public struct KanbanWorkerLog: Sendable, Equatable, Decodable {
    public let exists: Bool
    public let sizeBytes: Int
    public let content: String
    public let truncated: Bool

    public init(from decoder: Decoder) throws {
        let j = try JSONValue(from: decoder)
        exists = j["exists"]?.bool ?? false
        sizeBytes = j["size_bytes"]?.intValue ?? 0
        content = j["content"]?.string ?? ""
        truncated = j["truncated"]?.bool ?? false
    }
}

/// `GET /assignees` rows (`known_assignees`, `kanban_db.py:4315-4323`): on-disk profiles ∪ board assignees.
public struct KanbanAssignee: Sendable, Equatable, Identifiable {
    public let name: String
    public let onDisk: Bool
    /// `{status: n}` over non-archived tasks.
    public let counts: [String: Int]
    public var id: String { name }

    init?(json j: JSONValue) {
        guard let name = j["name"]?.nonEmptyString else { return nil }
        self.name = name
        onDisk = j["on_disk"]?.bool ?? false
        counts = (j["counts"]?.object ?? [:]).compactMapValues(\.intValue)
    }
}
