import Foundation
import HermesGatewayKit

// Kanban board (roadmap K1–K3): one `KanbanBoardModel` per board slug. It polls `GET /board?board=<slug>`
// while the board view is on screen (`start`/`stop`; a generation guard drops answers of a stopped loop),
// keeps the lanes in server order, and runs card actions optimistically: the change shows at once as a
// pending overlay on the last server board, and is dropped again (rolled back) with a visible error when the
// server refuses it. Wire calls go through `KanbanService` (KanbanAPI in production, a fake in tests).

/// The kanban calls the app makes. `KanbanAPI` (HermesGatewayKit) conforms as is.
protocol KanbanService: Sendable {
    func boards(includeArchived: Bool) async throws -> KanbanBoardList
    func board(_ board: String?, includeArchived: Bool, tenant: String?) async throws -> KanbanBoard
    func task(_ id: String, board: String?) async throws -> KanbanTaskDetail
    func log(taskId: String, board: String?, tailBytes: Int?) async throws -> KanbanWorkerLog
    func assignees(board: String?) async throws -> [KanbanAssignee]
    func createTask(_ draft: KanbanTaskDraft, board: String?, column: String?) async throws -> KanbanCreateResult
    func move(_ id: String, to status: String, board: String?) async throws -> KanbanTask?
    func archive(_ id: String, board: String?) async throws -> KanbanTask?
    func setPriority(_ id: String, _ priority: Int, board: String?) async throws -> KanbanTask?
    func reassign(_ id: String, to profile: String?, board: String?, reclaimFirst: Bool) async throws
    func addComment(taskId: String, body: String, board: String?, author: String) async throws
}

extension KanbanAPI: KanbanService {}

/// One lane as the app shows it (server order of columns and of tasks within a column).
struct KanbanLane: Equatable, Identifiable {
    let name: String
    var tasks: [KanbanTask]
    var id: String { name }
}

// MARK: - columns, filter, card flags (pure presentation rules)

enum KanbanColumns {
    /// Lanes only the dispatcher (or an agent) moves cards into; Desktop refuses drops there too
    /// (`LOCKED_COLUMNS`, desktop `ui.tsx`). The server answers 400 for `running`.
    static let locked: Set<String> = ["running", "review", "scheduled"]
    static let archived = "archived"

    private static let labels: [String: String] = [
        "triage": "Triage", "todo": "Todo", "scheduled": "Scheduled", "ready": "Ready", "running": "Running",
        "blocked": "Blocked", "review": "Review", "done": "Done", "archived": "Archived",
    ]
    private static let helps: [String: String] = [
        "triage": "Raw ideas: an agent rewrites them into a proper task first.",
        "todo": "Waiting on dependencies, or unassigned.",
        "scheduled": "Waiting for a scheduled time to arrive.",
        "ready": "Dependencies done. With an assignee, the dispatcher runs it.",
        "running": "A worker claimed it and an agent is on it. Set by the dispatcher.",
        "blocked": "The worker asked for human input.",
        "review": "A review agent is checking the work. Set by the dispatcher.",
        "done": "Completed; dependent tasks become ready.",
        "archived": "Hidden from the board.",
    ]

    static func label(_ name: String) -> String {
        labels[name] ?? name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func help(_ name: String) -> String? { helps[name] }

    /// Lanes on screen: server order, an empty `archived` lane hidden.
    static func visible(_ lanes: [KanbanLane]) -> [KanbanLane] {
        lanes.filter { !($0.name == archived && $0.tasks.isEmpty) }
    }

    /// Where a card in `current` can be moved by hand: every lane but its own, the locked ones and archived
    /// (Archive is its own action, with a confirmation).
    static func moveTargets(from current: String, lanes: [String]) -> [String] {
        lanes.filter { $0 != current && $0 != archived && !locked.contains($0) }
    }

    /// Lanes a new task may start in (`nil` = let the server decide: ready with an assignee, else todo).
    static func createTargets(_ lanes: [String]) -> [String] {
        lanes.filter { $0 != archived && $0 != "done" && !locked.contains($0) }
    }

    /// Insert `task` where the server would list it: newest-completed first in `done`, else priority
    /// descending then created ascending (`plugin_api.py:345-351`).
    static func insert(_ task: KanbanTask, into tasks: [KanbanTask], lane: String) -> [KanbanTask] {
        var out = tasks.filter { $0.id != task.id }
        if lane == "done" {
            out.insert(task, at: 0)
            return out
        }
        let i = out.firstIndex { other in
            other.priority < task.priority || (other.priority == task.priority && (other.createdAt ?? 0) > (task.createdAt ?? 0))
        } ?? out.endIndex
        out.insert(task, at: i)
        return out
    }
}

/// The board's filter field: every whitespace-separated term must match the title, the assignee (with or
/// without a leading `@`) or the task id, case-insensitively.
enum KanbanFilter {
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map { String($0) }
    }

    static func matches(_ task: KanbanTask, query: String) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        let title = task.title.lowercased(), assignee = task.assignee?.lowercased() ?? "", id = task.id.lowercased()
        return terms.allSatisfy { term in
            let bare = term.hasPrefix("@") ? String(term.dropFirst()) : term
            if term.hasPrefix("@") { return !bare.isEmpty && assignee.contains(bare) }
            return title.contains(term) || assignee.contains(term) || id.contains(term)
        }
    }

    static func apply(_ lanes: [KanbanLane], query: String) -> [KanbanLane] {
        guard !terms(query).isEmpty else { return lanes }
        return lanes.map { KanbanLane(name: $0.name, tasks: $0.tasks.filter { matches($0, query: query) }) }
    }
}

/// What a card says about its state, from the task fields only (never guessed).
struct KanbanCardFlags: Equatable {
    static let staleHeartbeat = 120  // seconds; Desktop's "no heartbeat" threshold (ui.tsx)

    var running = false
    /// Claimed, but no worker heartbeat for 2+ minutes (the dispatcher will reclaim it).
    var stale = false
    var blocked = false
    /// Blocked because the worker asked for human input (`block_kind == needs_input`).
    var needsInput = false
    /// Ready with no assignee: the dispatcher will not run it.
    var wontRun = false
    var failures = 0

    init(_ t: KanbanTask, now: Int) {
        running = t.status == "running"
        if running, let beat = t.lastHeartbeatAt { stale = now - beat > Self.staleHeartbeat }
        blocked = t.status == "blocked"
        needsInput = blocked && t.blockKind == "needs_input"
        wontRun = t.status == "ready" && t.assignee == nil
        failures = t.consecutiveFailures
    }
}

enum KanbanAge {
    /// "now", "42s", "5m", "3h", "2d", "6w".
    static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<10: return "now"
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<(86_400 * 14): return "\(s / 86_400)d"
        default: return "\(s / (86_400 * 7))w"
        }
    }

    /// The age a card shows: since completion for done cards, else since creation.
    static func of(_ t: KanbanTask, now: Int) -> String? {
        guard let since = (t.status == "done" ? t.completedAt : nil) ?? t.createdAt else { return nil }
        return short(now - since)
    }
}

extension KanbanTask {
    /// A copy with some wire fields replaced (optimistic overlays). Unchanged if the raw object is unusable.
    func replacing(_ fields: [String: JSONValue]) -> KanbanTask {
        guard case .object(var o) = raw else { return self }
        for (k, v) in fields { o[k] = v }
        return (try? KanbanTask(json: .object(o))) ?? self
    }
}

// MARK: - model

@MainActor
final class KanbanBoardModel: ObservableObject, Identifiable {
    enum LoadState: Equatable { case loading, ready, unavailable, failed(String) }

    enum Mutation: Equatable {
        case move(String)
        case archive
        case priority(Int)
        case assign(String?)
    }

    struct Pending: Equatable {
        let seq: Int
        let taskId: String
        let mutation: Mutation
    }

    /// Visible board cadence (Desktop polls its board on a similar beat), and the error backoff cap.
    static let interval: TimeInterval = 4
    static let maxBackoff: TimeInterval = 30
    /// Re-poll soon after an answer was dropped because a card action finished while it was in flight.
    static let staleRetry: TimeInterval = 0.25
    static let defaultPriorities = [0, 1, 2, 3]

    nonisolated let slug: String
    nonisolated var id: String { slug }
    let api: any KanbanService
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var state: LoadState = .loading
    /// Lanes as last answered by the server (successful actions are folded in until the next poll).
    @Published private(set) var serverLanes: [KanbanLane] = []
    /// Actions sent and not yet answered: drawn over `serverLanes`.
    @Published private(set) var pending: [Pending] = []
    /// The last failed action, in plain words (cleared by the next action or `dismissError`).
    @Published private(set) var error: String?
    /// A refreshing poll failed while the board was already shown (kept on screen; polling backs off).
    @Published private(set) var syncError: String?
    /// The server's `warning` after a create (dispatcher not running for a ready, assigned task).
    @Published private(set) var notice: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var serverNow: Int?
    @Published private(set) var assignees: [KanbanAssignee] = []

    @Published private(set) var selectedTaskId: String?
    @Published private(set) var detail: KanbanTaskDetail?
    @Published private(set) var detailError: String?
    @Published private(set) var log: KanbanWorkerLog?
    @Published private(set) var logError: String?
    @Published private(set) var logLoading = false

    /// Bumped by `start` and `stop`: answers of an older loop are dropped.
    private(set) var generation = 0
    private(set) var pollCount = 0
    private(set) var droppedStale = 0
    private(set) var failures = 0
    private var loop: Task<Void, Never>?
    private var nextSeq = 0
    /// Completed actions: a poll that started before one finished is stale (it may predate the change).
    private var actionsDone = 0
    private var fetchSeq = 0
    private var appliedFetch = 0
    private var detailSeq = 0
    /// The board's copy of the open card when its details were last loaded.
    private var detailBasis: KanbanTask?

    init(slug: String, api: any KanbanService,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.slug = slug; self.api = api; self.sleep = sleep
    }

    /// Lanes on screen: server lanes with the pending actions drawn over them, empty archive hidden.
    var lanes: [KanbanLane] { KanbanColumns.visible(Self.overlay(serverLanes, pending)) }
    var isPolling: Bool { loop != nil }
    var selectedTask: KanbanTask? {
        guard let id = selectedTaskId else { return nil }
        return task(id) ?? (detail?.task.id == id ? detail?.task : nil)
    }

    func task(_ id: String) -> KanbanTask? {
        for lane in Self.overlay(serverLanes, pending) { if let t = lane.tasks.first(where: { $0.id == id }) { return t } }
        return nil
    }

    func isPending(_ taskId: String) -> Bool { pending.contains { $0.taskId == taskId } }
    func dismissError() { error = nil }
    func dismissNotice() { notice = nil }

    // MARK: polling

    func start() {
        guard loop == nil else { return }
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.pollOnce(generation: gen) else { return }
                do { try await sleep(wait) } catch { return }
            }
        }
        if assignees.isEmpty { Task { await loadAssignees() } }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// One fetch for the loop of `gen`; returns the wait before the next one, or nil to end the loop.
    private func pollOnce(generation gen: Int) async -> TimeInterval? {
        guard gen == generation else { return nil }
        switch await fetch(generation: gen) {
        case .applied: return Self.interval
        case .stale: return Self.staleRetry
        case .dropped: return gen == generation ? Self.interval : nil
        case .failed: return Self.backoff(failures: failures)
        case .unavailable:
            if gen == generation { loop = nil }  // the plugin is off: no retry loop, `start` begins anew
            return nil
        }
    }

    static func backoff(failures: Int) -> TimeInterval {
        min(maxBackoff, interval * pow(2, Double(max(0, failures))))
    }

    enum FetchOutcome { case applied, stale, dropped, failed, unavailable }

    /// Fetches the board now (also used right after an action). Applies the answer only if it is still the
    /// newest one for the current generation and no action finished while it was in flight.
    @discardableResult
    func refresh() async -> FetchOutcome { await fetch(generation: generation) }

    private func fetch(generation gen: Int) async -> FetchOutcome {
        fetchSeq += 1
        let mine = fetchSeq, actionsAtStart = actionsDone
        pollCount += 1
        do {
            let board = try await api.board(slug, includeArchived: false, tenant: nil)
            guard gen == generation, mine > appliedFetch else { droppedStale += 1; return .dropped }
            guard actionsAtStart == actionsDone else { droppedStale += 1; return .stale }
            appliedFetch = mine
            serverLanes = board.columns.map { KanbanLane(name: $0.name, tasks: $0.tasks) }
            serverNow = board.now
            state = .ready
            syncError = nil
            failures = 0
            lastSync = Date()
            // The open card changed on the board (status, summary, comments…): reload its details.
            if let id = selectedTaskId, let t = task(id), t != detailBasis {
                detailBasis = t
                Task { await loadDetail() }
            }
            return .applied
        } catch {
            guard gen == generation, mine > appliedFetch else { return .dropped }
            if case PluginREST.Failure.pluginUnavailable = error {
                state = .unavailable
                return .unavailable
            }
            failures += 1
            let text = Self.describe(error)
            if serverLanes.isEmpty && state != .ready { state = .failed(text) } else { syncError = text }
            return .failed
        }
    }

    func loadAssignees() async {
        if let list = try? await api.assignees(board: slug) { assignees = list }
    }

    /// Assignee choices: on-disk profiles and anyone already on the board, sorted.
    var assigneeNames: [String] {
        var names = Set(assignees.map(\.name))
        for lane in serverLanes { for t in lane.tasks { if let a = t.assignee { names.insert(a) } } }
        return names.sorted()
    }

    // MARK: actions (optimistic, rolled back on failure)

    /// Move a card to another lane. Locked lanes (running, review, scheduled) are refused before sending.
    @discardableResult
    func move(_ taskId: String, to lane: String) async -> Bool {
        guard let t = task(taskId), t.status != lane, !KanbanColumns.locked.contains(lane), lane != KanbanColumns.archived else {
            return false
        }
        return await perform(taskId, .move(lane), what: "Move “\(t.title)” to \(KanbanColumns.label(lane))") { api, slug in
            try await api.move(taskId, to: lane, board: slug)
        }
    }

    @discardableResult
    func archive(_ taskId: String) async -> Bool {
        guard let t = task(taskId) else { return false }
        return await perform(taskId, .archive, what: "Archive “\(t.title)”") { api, slug in
            try await api.archive(taskId, board: slug)
        }
    }

    @discardableResult
    func setPriority(_ taskId: String, _ priority: Int) async -> Bool {
        guard let t = task(taskId), t.priority != priority else { return false }
        return await perform(taskId, .priority(priority), what: "Set the priority of “\(t.title)”") { api, slug in
            try await api.setPriority(taskId, priority, board: slug)
        }
    }

    /// `profile: nil` unassigns.
    @discardableResult
    func reassign(_ taskId: String, to profile: String?) async -> Bool {
        guard let t = task(taskId), t.assignee != profile else { return false }
        let what = profile.map { "Assign “\(t.title)” to @\($0)" } ?? "Unassign “\(t.title)”"
        return await perform(taskId, .assign(profile), what: what) { api, slug in
            try await api.reassign(taskId, to: profile, board: slug, reclaimFirst: true)
            return nil
        }
    }

    private func perform(_ taskId: String, _ mutation: Mutation, what: String,
                         _ call: @escaping @Sendable (any KanbanService, String) async throws -> KanbanTask?) async -> Bool {
        nextSeq += 1
        let p = Pending(seq: nextSeq, taskId: taskId, mutation: mutation)
        pending.append(p)
        error = nil
        do {
            let updated = try await call(api, slug)
            pending.removeAll { $0.seq == p.seq }
            actionsDone += 1
            // Keep the change on screen until the next poll confirms it.
            if let updated { serverLanes = Self.place(updated, in: serverLanes) } else { serverLanes = Self.overlay(serverLanes, [p]) }
            if selectedTaskId == taskId { Task { await loadDetail() } }
            Task { await refresh() }
            return true
        } catch {
            pending.removeAll { $0.seq == p.seq }  // rollback: the server board shows again
            self.error = "\(what) failed: \(Self.describe(error))"
            return false
        }
    }

    /// `POST /tasks`. Returns an error text, or nil on success (the card is on the board at once; the
    /// server's warning, if any, becomes `notice`).
    func create(_ draft: KanbanTaskDraft, column: String?) async -> String? {
        do {
            let r = try await api.createTask(draft, board: slug, column: column)
            actionsDone += 1
            if let t = r.task { serverLanes = Self.place(t, in: serverLanes) }
            notice = r.warning
            Task { await refresh() }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: details (K2)

    func select(_ taskId: String?) {
        guard taskId != selectedTaskId else { return }
        selectedTaskId = taskId
        detailBasis = taskId.flatMap(task)
        detail = nil; detailError = nil
        log = nil; logError = nil
        if taskId != nil { Task { await loadDetail() } }
    }

    func loadDetail() async {
        guard let id = selectedTaskId else { return }
        detailSeq += 1
        let mine = detailSeq
        do {
            let d = try await api.task(id, board: slug)
            guard mine == detailSeq, selectedTaskId == id else { return }
            detail = d; detailError = nil
        } catch {
            guard mine == detailSeq, selectedTaskId == id else { return }
            detailError = Self.describe(error)
        }
    }

    func loadLog() async {
        guard let id = selectedTaskId else { return }
        logLoading = true
        defer { logLoading = false }
        do {
            let l = try await api.log(taskId: id, board: slug, tailBytes: KanbanAPI.defaultLogTail)
            guard selectedTaskId == id else { return }
            log = l; logError = nil
        } catch {
            guard selectedTaskId == id else { return }
            logError = Self.describe(error)
        }
    }

    /// Adds a comment to the selected card, then reloads its details. False (draft kept) on failure.
    func addComment(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTaskId, !text.isEmpty else { return false }
        do {
            try await api.addComment(taskId: id, body: text, board: slug, author: KanbanAPI.commentAuthor)
            error = nil
            await loadDetail()
            return true
        } catch {
            self.error = "Comment failed: \(Self.describe(error))"
            return false
        }
    }

    // MARK: lane arithmetic

    /// `pending` applied in order over `lanes`.
    static func overlay(_ lanes: [KanbanLane], _ pending: [Pending]) -> [KanbanLane] {
        pending.reduce(lanes) { lanes, p in
            guard let t = lanes.lazy.flatMap(\.tasks).first(where: { $0.id == p.taskId }) else { return lanes }
            switch p.mutation {
            case .move(let lane): return place(t.replacing(["status": .string(lane)]), in: lanes)
            case .archive: return lanes.map { KanbanLane(name: $0.name, tasks: $0.tasks.filter { $0.id != p.taskId }) }
            case .priority(let n): return place(t.replacing(["priority": .number(Double(n))]), in: lanes)
            case .assign(let who): return place(t.replacing(["assignee": who.map(JSONValue.string) ?? .null]), in: lanes)
            }
        }
    }

    /// `task` removed from every lane and inserted into the lane named by its status (dropped when that lane
    /// is not on the board, and always when archived: the board is fetched without archived cards).
    static func place(_ task: KanbanTask, in lanes: [KanbanLane]) -> [KanbanLane] {
        lanes.map { lane in
            let rest = lane.tasks.filter { $0.id != task.id }
            guard lane.name == task.status, task.status != KanbanColumns.archived else { return KanbanLane(name: lane.name, tasks: rest) }
            // Same lane: keep its slot unless the order key changed.
            if let i = lane.tasks.firstIndex(where: { $0.id == task.id }), lane.tasks[i].priority == task.priority {
                var same = lane.tasks
                same[i] = task
                return KanbanLane(name: lane.name, tasks: same)
            }
            return KanbanLane(name: lane.name, tasks: KanbanColumns.insert(task, into: rest, lane: lane.name))
        }
    }

    /// Plain words for an error: the server's own `detail` for a refused request (e.g. a 409 naming the
    /// blocking parents), else the redacted description.
    static func describe(_ error: Error) -> String {
        switch error {
        case PluginREST.Failure.http(_, let detail) where !detail.isEmpty: return detail
        case PluginREST.Failure.pluginUnavailable: return "Kanban is off in Hermes."
        case PluginREST.Failure.unauthorized: return "Hermes refused the session token."
        default: return Redaction.describe(error)
        }
    }
}
