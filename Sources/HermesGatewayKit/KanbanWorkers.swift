import Foundation

// Kanban workers (roadmap K5): the kanban plugin's worker-visibility endpoints
// (`plugins/kanban/dashboard/plugin_api.py`, "Worker visibility"): `GET /workers/active`, `GET /runs/{id}`,
// `GET /runs/{id}/inspect`, `POST /runs/{id}/terminate`. Reclaim (`POST /tasks/{id}/reclaim`) is
// `KanbanAPI.reclaim`. Like every board-scoped call, `?board=<slug>` is passed when a slug is given.

/// One running worker (`list_active_workers`): an open run with a worker pid whose task is `running`.
public struct KanbanActiveWorker: Sendable, Equatable, Identifiable {
    public let runId: Int
    public let taskId: String
    public let taskTitle: String
    public let taskAssignee: String?
    /// The profile (bot) running the card.
    public let profile: String?
    public let workerPid: Int?
    public let startedAt: Int?
    public let lastHeartbeatAt: Int?
    public let claimExpires: Int?
    public let maxRuntimeSeconds: Int?
    public var id: Int { runId }

    public init?(json j: JSONValue) {
        guard let runId = j["run_id"]?.intValue, let taskId = j["task_id"]?.nonEmptyString else { return nil }
        self.runId = runId
        self.taskId = taskId
        taskTitle = j["task_title"]?.string ?? ""
        taskAssignee = j["task_assignee"]?.nonEmptyString
        profile = j["profile"]?.nonEmptyString
        workerPid = j["worker_pid"]?.intValue
        startedAt = j["started_at"]?.intValue
        lastHeartbeatAt = j["last_heartbeat_at"]?.intValue
        claimExpires = j["claim_expires"]?.intValue
        maxRuntimeSeconds = j["max_runtime_seconds"]?.intValue
    }

    /// Who runs it: the run's profile, else the task's assignee.
    public var bot: String? { profile ?? taskAssignee }
}

/// `GET /workers/active` → `{workers, count, checked_at}`. `checkedAt` is the server's clock (epoch seconds).
public struct KanbanActiveWorkers: Sendable, Equatable, Decodable {
    public let workers: [KanbanActiveWorker]
    public let checkedAt: Int?

    public init(workers: [KanbanActiveWorker], checkedAt: Int?) {
        self.workers = workers; self.checkedAt = checkedAt
    }

    public init(from decoder: Decoder) throws { self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) {
        workers = (j["workers"]?.array ?? []).compactMap(KanbanActiveWorker.init(json:))
        checkedAt = j["checked_at"]?.intValue
    }
}

/// `GET /runs/{id}/inspect`: live process stats of a run's worker, or `alive: false` with the reason
/// ("run already ended", "process not found", …). The command line is not kept: it is not shown.
public struct KanbanRunProcess: Sendable, Equatable, Decodable {
    public let alive: Bool
    public let reason: String?
    /// "access denied" when the stats could not be read.
    public let error: String?
    public let pid: Int?
    public let cpuPercent: Double?
    public let memoryRSSBytes: Int?
    public let threads: Int?
    public let status: String?

    public init(from decoder: Decoder) throws { self.init(json: try JSONValue(from: decoder)) }

    public init(json j: JSONValue) {
        alive = j["alive"]?.bool ?? false
        reason = j["reason"]?.nonEmptyString
        error = j["error"]?.nonEmptyString
        pid = j["pid"]?.intValue
        cpuPercent = j["cpu_percent"]?.double
        memoryRSSBytes = j["memory_rss_bytes"]?.intValue
        threads = j["num_threads"]?.intValue
        status = j["status"]?.nonEmptyString
    }
}

extension KanbanRun {
    /// `GET /runs/{id}` → `{run: asdict(Run)}`.
    public static func decodeRecord(_ j: JSONValue) throws -> KanbanRun {
        guard let run = j["run"].flatMap(KanbanRun.init(json:)) else { throw MissingField(key: "run", model: "KanbanRun") }
        return run
    }
}

extension KanbanAPI {
    /// `GET /workers/active` (`list_active_workers`).
    public func activeWorkers(board: String?) async throws -> KanbanActiveWorkers {
        try await rest.send(.get, "/workers/active", query: Self.boardQuery(board), as: KanbanActiveWorkers.self)
    }

    /// `GET /runs/{id}` (`get_run_endpoint`); 404 when unknown.
    public func run(_ runId: Int, board: String?) async throws -> KanbanRun {
        try KanbanRun.decodeRecord(try await rest.get("/runs/\(runId)", query: Self.boardQuery(board)))
    }

    /// `GET /runs/{id}/inspect` (`inspect_run_endpoint`).
    public func inspectRun(_ runId: Int, board: String?) async throws -> KanbanRunProcess {
        try await rest.send(.get, "/runs/\(runId)/inspect", query: Self.boardQuery(board), as: KanbanRunProcess.self)
    }

    /// `POST /runs/{id}/terminate {reason?}` (`terminate_run_endpoint`): the same SIGTERM → SIGKILL and
    /// bookkeeping as a reclaim; 409 when the run already ended or the task is no longer reclaimable.
    public func terminateRun(_ runId: Int, board: String?, reason: String?) async throws {
        var body: [String: JSONValue] = [:]
        if let reason, !reason.isEmpty { body["reason"] = .string(reason) }
        _ = try await rest.post("/runs/\(runId)/terminate", query: Self.boardQuery(board), body: .object(body))
    }
}
