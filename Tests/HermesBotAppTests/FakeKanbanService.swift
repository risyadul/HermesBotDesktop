import Foundation
@testable import HermesBotApp
@testable import HermesGatewayKit

/// In-memory kanban server for `KanbanBoardModel` / `KanbanHub` tests. It keeps its own board and applies
/// successful actions to it (so a later poll answers the server truth); delays and failures are set per test
/// through `with`. Every title and name is a placeholder.
final class FakeKanbanService: KanbanService, @unchecked Sendable {
    struct State {
        var columns: [(name: String, tasks: [JSONValue])] = []
        var boards: [JSONValue] = []
        var boardsError: Error?
        var boardError: Error?
        var boardDelay: TimeInterval = 0
        var actionDelay: TimeInterval = 0
        var actionError: Error?
        var createWarning: String?
        var createError: Error?
        var commentError: Error?
        var reclaimError: Error?
        var attachments: [String: [JSONValue]] = [:]
        var uploads: [(name: String, contentType: String?, bytes: Int)] = []
        var uploadError: Error?
        var download = Data("placeholder bytes".utf8)
        var downloadError: Error?
        var deleteError: Error?
        var comments: [String: [JSONValue]] = [:]
        /// `include_archived` of every `board` call, in order.
        var boardArchivedFlags: [Bool] = []
        /// K5: the `/workers/active` rows, and per-call errors.
        var workers: [JSONValue] = []
        var workersError: Error?
        var runError: Error?
        var inspectError: Error?
        var terminateError: Error?
        var terminated: [(runId: Int, reason: String?)] = []
        var assignees = ["alice", "bob"]
        var calls: [String] = []
        var nextId = 0
        /// The next `board` / `addComment` call parks until `release()` (`parked` tells when it does).
        var holdNextBoard = false
        var holdNextComment = false
        var parked: CheckedContinuation<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()

    init(columns: [(String, [JSONValue])] = []) { state.columns = columns.map { (name: $0.0, tasks: $0.1) } }

    @discardableResult
    func with<R>(_ body: (inout State) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }

    var calls: [String] { with { $0.calls } }
    var isParked: Bool { with { $0.parked != nil } }

    func release() {
        let c: CheckedContinuation<Void, Never>? = with { s in defer { s.parked = nil }; return s.parked }
        c?.resume()
    }

    /// Parks the call when `flag` is set (and clears it).
    private func parkIf(_ flag: WritableKeyPath<State, Bool>) async {
        guard with({ s in defer { s[keyPath: flag] = false }; return s[keyPath: flag] }) else { return }
        await withCheckedContinuation { c in with { $0.parked = c } }
    }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    static func task(_ id: String, _ title: String, status: String, priority: Int = 0, assignee: String? = nil,
                     created: Int = 1_760_000_000, extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "status": .string(status),
                                      "priority": .number(Double(priority)), "created_at": .number(Double(created))]
        if let assignee { o["assignee"] = .string(assignee) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func summary(_ slug: String, archived: Bool = false, counts: [String: Int] = [:]) -> JSONValue {
        .object(["slug": .string(slug), "name": .string(slug.capitalized), "archived": .bool(archived),
                 "counts": .object(counts.mapValues { .number(Double($0)) })])
    }

    private func record(_ call: String) { with { $0.calls.append(call) } }

    private func pause(_ seconds: TimeInterval) async {
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    /// Applies `fields` to the task `id` on the fake board; a changed status moves it to that lane (dropped
    /// when the lane does not exist, e.g. archived).
    private func update(_ id: String, _ fields: [String: JSONValue]) -> JSONValue? {
        with { s in
            for (ci, col) in s.columns.enumerated() {
                guard let ti = col.tasks.firstIndex(where: { $0["id"]?.string == id }), case .object(var o) = col.tasks[ti] else { continue }
                for (k, v) in fields { o[k] = v }
                let t = JSONValue.object(o)
                s.columns[ci].tasks.remove(at: ti)
                let lane = o["status"]?.string ?? col.name
                if let target = s.columns.firstIndex(where: { $0.name == lane }) { s.columns[target].tasks.append(t) }
                return t
            }
            return nil
        }
    }

    private func actionGate() async throws {
        let (delay, error) = with { ($0.actionDelay, $0.actionError) }
        await pause(delay)
        if let error { throw error }
    }

    // MARK: KanbanService

    func boards(includeArchived: Bool) async throws -> KanbanBoardList {
        record("boards")
        let (list, error) = with { ($0.boards, $0.boardsError) }
        if let error { throw error }
        return try KanbanBoardList(json: ["boards": .array(list)])
    }

    func board(_ board: String?, includeArchived: Bool, tenant: String?) async throws -> KanbanBoard {
        record("board")
        with { $0.boardArchivedFlags.append(includeArchived) }
        await parkIf(\.holdNextBoard)
        await pause(with { $0.boardDelay })
        let (cols, error) = with { ($0.columns, $0.boardError) }
        if let error { throw error }
        return try KanbanBoard(json: ["columns": .array(cols.map { ["name": .string($0.name), "tasks": .array($0.tasks)] }),
                                      "now": 1_760_000_300])
    }

    func task(_ id: String, board: String?) async throws -> KanbanTaskDetail {
        record("task")
        let (t, comments) = with { s in (s.columns.flatMap(\.tasks).first { $0["id"]?.string == id }, s.comments[id] ?? []) }
        guard let t else { throw PluginREST.Failure.http(status: 404, detail: "task \(id) not found") }
        let files = with { $0.attachments[id] ?? [] }
        return try KanbanTaskDetail(json: ["task": t, "comments": .array(comments), "attachments": .array(files),
                                           "links": ["parents": ["t_parent"], "children": []],
                                           "link_tasks": [["id": "t_parent", "title": "Parent placeholder", "status": "done"]]])
    }

    func log(taskId: String, board: String?, tailBytes: Int?) async throws -> KanbanWorkerLog {
        record("log")
        let json = #"{"exists":true,"size_bytes":12,"content":"line one\nline two","truncated":false}"#
        return try JSONDecoder().decode(KanbanWorkerLog.self, from: Data(json.utf8))
    }

    func assignees(board: String?) async throws -> [KanbanAssignee] {
        record("assignees")
        return with { $0.assignees }.compactMap { KanbanAssignee(json: ["name": .string($0), "on_disk": true]) }
    }

    func createTask(_ draft: KanbanTaskDraft, board: String?, column: String?) async throws -> KanbanCreateResult {
        record("create")
        await pause(with { $0.actionDelay })
        if let error = with({ $0.createError }) { throw error }
        let (t, warning): (JSONValue, String?) = with { s in
            s.nextId += 1
            let status = draft.triage ? "triage" : (column ?? (draft.assignee == nil ? "todo" : "ready"))
            let t = Self.task("t_new\(s.nextId)", draft.title, status: status, priority: draft.priority, assignee: draft.assignee,
                              created: 1_760_000_299)
            if let i = s.columns.firstIndex(where: { $0.name == status }) { s.columns[i].tasks.append(t) }
            return (t, s.createWarning)
        }
        return KanbanCreateResult(task: try KanbanTask(json: t), warning: warning)
    }

    func move(_ id: String, to status: String, board: String?) async throws -> KanbanTask? {
        record("move")
        try await actionGate()
        return try update(id, ["status": .string(status)]).map { try KanbanTask(json: $0) }
    }

    func archive(_ id: String, board: String?) async throws -> KanbanTask? {
        record("archive")
        try await actionGate()
        return try update(id, ["status": "archived"]).map { try KanbanTask(json: $0) }
    }

    func setPriority(_ id: String, _ priority: Int, board: String?) async throws -> KanbanTask? {
        record("priority")
        try await actionGate()
        return try update(id, ["priority": .number(Double(priority))]).map { try KanbanTask(json: $0) }
    }

    func reassign(_ id: String, to profile: String?, board: String?, reclaimFirst: Bool) async throws {
        record("reassign")
        try await actionGate()
        _ = update(id, ["assignee": profile.map(JSONValue.string) ?? .null])
    }

    func addComment(taskId: String, body: String, board: String?, author: String) async throws {
        record("comment")
        await parkIf(\.holdNextComment)
        if let error = with({ $0.commentError }) { throw error }
        with { s in
            s.nextId += 1
            s.comments[taskId, default: []].append(["id": .number(Double(s.nextId)), "author": .string(author),
                                                    "body": .string(body), "created_at": 1_760_000_301])
        }
    }

    func reclaim(_ id: String, board: String?, reason: String?) async throws {
        record("reclaim")
        if let error = with({ $0.reclaimError }) { throw error }
        _ = update(id, ["status": "ready"])
        with { $0.workers.removeAll { $0["task_id"]?.string == id } }
    }

    static func attachment(_ id: Int, task: String, name: String, size: Int = 10) -> JSONValue {
        ["id": .number(Double(id)), "task_id": .string(task), "filename": .string(name), "size": .number(Double(size)),
         "uploaded_by": "hermes-bot-app", "created_at": 1_760_000_302]
    }

    func attachments(taskId: String, board: String?) async throws -> [KanbanAttachment] {
        record("attachments")
        return with { $0.attachments[taskId] ?? [] }.compactMap(KanbanAttachment.init(json:))
    }

    func uploadAttachment(taskId: String, filename: String, contentType: String?, data: Data, board: String?,
                          uploadedBy: String) async throws -> KanbanAttachment? {
        record("upload")
        if let error = with({ $0.uploadError }) { throw error }
        let row: JSONValue = with { s in
            s.nextId += 1
            s.uploads.append((filename, contentType, data.count))
            let row = Self.attachment(100 + s.nextId, task: taskId, name: filename, size: data.count)
            s.attachments[taskId, default: []].append(row)
            return row
        }
        return KanbanAttachment(json: row)
    }

    func downloadAttachment(_ id: Int, board: String?) async throws -> Data {
        record("download")
        if let error = with({ $0.downloadError }) { throw error }
        return with { $0.download }
    }

    func deleteAttachment(_ id: Int, board: String?) async throws {
        record("delete")
        if let error = with({ $0.deleteError }) { throw error }
        with { s in for k in s.attachments.keys { s.attachments[k]?.removeAll { $0["id"]?.intValue == id } } }
    }

    // MARK: K5 workers

    static func worker(run: Int, task: String, title: String, profile: String?, started: Int = 1_760_000_000,
                       heartbeat: Int? = 1_760_000_290, pid: Int = 4242) -> JSONValue {
        var o: [String: JSONValue] = ["run_id": .number(Double(run)), "task_id": .string(task), "task_title": .string(title),
                                      "task_status": "running", "worker_pid": .number(Double(pid)),
                                      "started_at": .number(Double(started))]
        if let profile { o["profile"] = .string(profile); o["task_assignee"] = .string(profile) }
        if let heartbeat { o["last_heartbeat_at"] = .number(Double(heartbeat)) }
        return .object(o)
    }

    func activeWorkers(board: String?) async throws -> KanbanActiveWorkers {
        record("workers")
        let (rows, error) = with { ($0.workers, $0.workersError) }
        if let error { throw error }
        return KanbanActiveWorkers(json: ["workers": .array(rows), "count": .number(Double(rows.count)), "checked_at": 1_760_000_300])
    }

    func run(_ runId: Int, board: String?) async throws -> KanbanRun {
        record("run")
        if let error = with({ $0.runError }) { throw error }
        return try KanbanRun.decodeRecord(["run": ["id": .number(Double(runId)), "profile": "alice", "status": "running",
                                                   "summary": "Halfway there", "started_at": 1_760_000_000]])
    }

    func inspectRun(_ runId: Int, board: String?) async throws -> KanbanRunProcess {
        record("inspect")
        if let error = with({ $0.inspectError }) { throw error }
        return KanbanRunProcess(json: ["run_id": .number(Double(runId)), "alive": true, "pid": 4242, "cpu_percent": .number(12.5),
                                       "memory_rss_bytes": 1_048_576, "num_threads": 4, "status": "running"])
    }

    func terminateRun(_ runId: Int, board: String?, reason: String?) async throws {
        record("terminate")
        if let error = with({ $0.terminateError }) { throw error }
        with { s in
            s.terminated.append((runId, reason))
            s.workers.removeAll { $0["run_id"]?.intValue == runId }
        }
    }
}
