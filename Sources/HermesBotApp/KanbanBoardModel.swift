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
    func reclaim(_ id: String, board: String?, reason: String?) async throws
    func attachments(taskId: String, board: String?) async throws -> [KanbanAttachment]
    func uploadAttachment(taskId: String, filename: String, contentType: String?, data: Data, board: String?,
                          uploadedBy: String) async throws -> KanbanAttachment?
    func downloadAttachment(_ id: Int, board: String?) async throws -> Data
    func deleteAttachment(_ id: Int, board: String?) async throws
    // K5 workers (KanbanWorkers.swift in HermesGatewayKit; KanbanWorkersModel.swift)
    func activeWorkers(board: String?) async throws -> KanbanActiveWorkers
    func run(_ runId: Int, board: String?) async throws -> KanbanRun
    func inspectRun(_ runId: Int, board: String?) async throws -> KanbanRunProcess
    func terminateRun(_ runId: Int, board: String?, reason: String?) async throws
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

    /// An empty lane folds into a slim strip (label + count) unless the user expanded it, so the lanes that
    /// hold cards fit on screen. Nothing folds while every lane is empty: a new board shows its lanes.
    static func isCollapsed(_ lane: KanbanLane, in lanes: [KanbanLane], expanded: Set<String>) -> Bool {
        lane.tasks.isEmpty && !expanded.contains(lane.name) && lanes.contains { !$0.tasks.isEmpty }
    }

    /// The lane holding card `id`, to scroll it into view.
    static func lane(containing id: String?, in lanes: [KanbanLane]) -> String? {
        guard let id else { return nil }
        return lanes.first { $0.tasks.contains { $0.id == id } }?.name
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

/// When the card details inspector shows: closed until a card is selected, then open, unless the user
/// closed it while a card was selected (remembered); opening it again by hand clears that.
enum KanbanInspectorRule {
    static func shown(selection: String?, closedByUser: Bool) -> Bool { selection != nil && !closedByUser }

    /// The remembered "closed by the user" flag once the inspector became `shown`. The app only closes it
    /// by itself when nothing is selected, so a close with a card selected is the user's.
    static func closedByUser(afterShown shown: Bool, selection: String?, was: Bool) -> Bool {
        if shown { return false }
        return selection != nil ? true : was
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
    /// `gone`: the board was deleted or archived while open (the server answers 404 "board … does not exist"
    /// / "… is archived"): polling stops for good and every action is refused.
    enum LoadState: Equatable { case loading, ready, unavailable, gone, failed(String) }

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
    /// "Show archived" (K4): the board is fetched with `include_archived` and the archived lane shows.
    @Published private(set) var includeArchived = false

    @Published private(set) var selectedTaskId: String?
    @Published private(set) var detail: KanbanTaskDetail?
    @Published private(set) var detailError: String?
    @Published private(set) var log: KanbanWorkerLog?
    @Published private(set) var logError: String?
    @Published private(set) var logLoading = false
    /// The open card's attachments (from its details, refreshed by `GET /tasks/{id}/attachments`).
    @Published private(set) var attachments: [KanbanAttachment] = []
    /// The last failed attachment action (list, upload, open, delete), in plain words.
    @Published private(set) var attachmentError: String?
    /// Uploads in flight for the open card.
    @Published private(set) var uploading = 0
    /// Attachments being downloaded to open.
    @Published private(set) var opening: Set<Int> = []
    /// A short confirmation under the comment box (Requeue with note).
    @Published private(set) var inspectorNote: String?
    /// Unsent comment box text per card id: a draft never shows on another card.
    @Published private(set) var commentDrafts: [String: String] = [:]

    /// Where downloads are saved and how a checked one is shown; tests replace both.
    var attachmentRoot = KanbanAttachmentFiles.root
    var openFile: @MainActor (URL, KanbanAttachmentFiles.Action) -> Void = { KanbanAttachmentFiles.perform($0, $1) }

    /// Bumped by `start` and `stop`: answers of an older loop are dropped.
    private(set) var generation = 0
    /// The view wants polling (`start` … `stop`); kept while suspended, so `setSuspended(false)` resumes.
    private(set) var wantsPolling = false
    /// No app window on screen (KanbanHub.setActive): no loop runs.
    private(set) var isSuspended = false
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

    /// Lanes on screen: server lanes with the pending actions drawn over them, empty archive hidden (kept
    /// while "Show archived" is on).
    var lanes: [KanbanLane] {
        let all = Self.overlay(serverLanes, pending)
        return includeArchived ? all : KanbanColumns.visible(all)
    }

    /// Turns "Show archived" on or off and fetches the board again at once.
    func setIncludeArchived(_ on: Bool) {
        guard on != includeArchived else { return }
        includeArchived = on
        Task { await refresh() }
    }
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
        wantsPolling = true
        guard loop == nil, !isSuspended, state != .gone else { return }
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
        wantsPolling = false
        endLoop()
    }

    private func endLoop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// Suspended: the loop stops but `wantsPolling` is kept; resumed: it starts again (fetching at once).
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            if loop != nil { endLoop() }
        } else if wantsPolling {
            start()
        }
    }

    static let goneMessage = "This board was deleted or archived."

    /// The 404 the kanban plugin answers for a board that no longer exists or was archived
    /// (`_resolve_board`, plugins/kanban/dashboard/plugin_api.py).
    static func isBoardGone(_ error: Error) -> Bool {
        guard case PluginREST.Failure.http(404, let detail) = error, detail.hasPrefix("board ") else { return false }
        return detail.hasSuffix(" does not exist") || detail.hasSuffix(" is archived")
    }

    /// Stops polling for good; pending overlays and sync errors go (the view shows the gone state).
    private func markGone() {
        state = .gone
        pending = []
        syncError = nil
        endLoop()
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
        case .gone:
            return nil
        }
    }

    static func backoff(failures: Int) -> TimeInterval {
        min(maxBackoff, interval * pow(2, Double(max(0, failures))))
    }

    enum FetchOutcome { case applied, stale, dropped, failed, unavailable, gone }

    /// Fetches the board now (also used right after an action). Applies the answer only if it is still the
    /// newest one for the current generation and no action finished while it was in flight.
    @discardableResult
    func refresh() async -> FetchOutcome { await fetch(generation: generation) }

    private func fetch(generation gen: Int) async -> FetchOutcome {
        fetchSeq += 1
        let mine = fetchSeq, actionsAtStart = actionsDone
        pollCount += 1
        do {
            let board = try await api.board(slug, includeArchived: includeArchived, tenant: nil)
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
            if Self.isBoardGone(error) {
                markGone()
                return .gone
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
        guard state != .gone else {
            error = "\(what) failed: \(Self.goneMessage)"
            return false
        }
        nextSeq += 1
        let p = Pending(seq: nextSeq, taskId: taskId, mutation: mutation)
        pending.append(p)
        error = nil
        do {
            let updated = try await call(api, slug)
            pending.removeAll { $0.seq == p.seq }
            actionsDone += 1
            // Keep the change on screen until the next poll confirms it.
            if let updated { serverLanes = Self.place(updated, in: serverLanes, keepArchived: includeArchived) } else { serverLanes = Self.overlay(serverLanes, [p]) }
            if selectedTaskId == taskId { Task { await loadDetail() } }
            refreshIfPolling()
            return true
        } catch {
            pending.removeAll { $0.seq == p.seq }  // rollback: the server board shows again
            if Self.isBoardGone(error) { markGone() }
            self.error = "\(what) failed: \(Self.describe(error))"
            return false
        }
    }

    /// `POST /tasks`. Returns an error text, or nil on success (the card is on the board at once; the
    /// server's warning, if any, becomes `notice`).
    func create(_ draft: KanbanTaskDraft, column: String?) async -> String? {
        guard state != .gone else { return Self.goneMessage }
        do {
            let r = try await api.createTask(draft, board: slug, column: column)
            actionsDone += 1
            if let t = r.task { serverLanes = Self.place(t, in: serverLanes) }
            notice = r.warning
            refreshIfPolling()
            return nil
        } catch {
            if Self.isBoardGone(error) { markGone() }
            return Self.describe(error)
        }
    }

    /// After an action: fetch the board now, unless the view stopped polling (then nothing is shown and the
    /// next `start` fetches anyway).
    private func refreshIfPolling() {
        if isPolling { Task { await refresh() } }
    }

    // MARK: details (K2)

    func select(_ taskId: String?) {
        guard taskId != selectedTaskId else { return }
        selectedTaskId = taskId
        detailBasis = taskId.flatMap(task)
        detail = nil; detailError = nil
        log = nil; logError = nil
        attachments = []; attachmentError = nil; inspectorNote = nil
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
            attachments = d.attachments
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

    /// The open card's comment box text.
    var commentDraft: String {
        get { selectedTaskId.flatMap { commentDrafts[$0] } ?? "" }
        set {
            guard let id = selectedTaskId else { return }
            commentDrafts[id] = newValue.isEmpty ? nil : newValue
        }
    }

    /// After `body` was posted to `taskId`: that card's draft goes, unless it was edited meanwhile.
    private func clearDraft(_ taskId: String, sent body: String) {
        if commentDrafts[taskId] == body { commentDrafts[taskId] = nil }
    }

    /// Adds a comment to the selected card, then reloads its details. False (draft kept) on failure; on
    /// success the draft of that card (even if another is open by then) is cleared.
    func addComment(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTaskId, !text.isEmpty else { return false }
        do {
            try await api.addComment(taskId: id, body: text, board: slug, author: KanbanAPI.commentAuthor)
            clearDraft(id, sent: body)
            error = nil
            await loadDetail()
            return true
        } catch {
            self.error = "Comment failed: \(Self.describe(error))"
            return false
        }
    }

    static let requeuedNote = "Note posted; the task will restart with it."

    /// The open card is being worked on: a comment reaches the worker's current turn.
    var selectedIsRunning: Bool { selectedTask?.status == "running" }

    /// Desktop's "Requeue with note" (drawer.tsx `requeueMut`): post the note, then reclaim the task so the
    /// dispatcher runs it again with the note in context. The reclaim is never sent when the note was not
    /// posted. True when the note was posted (the draft can go), even if the reclaim then failed.
    func requeueWithNote(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTaskId, !text.isEmpty else { return false }
        inspectorNote = nil
        do {
            try await api.addComment(taskId: id, body: text, board: slug, author: KanbanAPI.commentAuthor)
        } catch {
            self.error = "Requeue with note failed: \(Self.describe(error))"
            return false
        }
        clearDraft(id, sent: body)
        do {
            try await api.reclaim(id, board: slug, reason: nil)
            error = nil
            inspectorNote = Self.requeuedNote
            actionsDone += 1
        } catch {
            self.error = "The note was posted, but the requeue failed: \(Self.describe(error))"
        }
        refreshIfPolling()
        await loadDetail()
        return true
    }

    // MARK: attachments (K2)

    func dismissAttachmentError() { attachmentError = nil }

    func loadAttachments() async {
        guard let id = selectedTaskId else { return }
        do {
            let list = try await api.attachments(taskId: id, board: slug)
            guard selectedTaskId == id else { return }
            attachments = list
        } catch {
            guard selectedTaskId == id else { return }
            attachmentError = "Attachments not loaded: \(Self.describe(error))"
        }
    }

    /// Uploads files to the open card, one after another; a file that cannot be read or is over the limit is
    /// refused before anything is sent, the others still go. Then the list is reloaded.
    func upload(_ urls: [URL]) async {
        let files = urls.filter(\.isFileURL)
        guard let id = selectedTaskId, !files.isEmpty else { return }
        attachmentError = nil
        var failures: [String] = []
        for url in files {
            uploading += 1
            do {
                let file = try await Task.detached(priority: .userInitiated) { try KanbanAttachmentFiles.readUpload(url) }.value
                _ = try await api.uploadAttachment(taskId: id, filename: file.name, contentType: file.contentType, data: file.data,
                                               board: slug, uploadedBy: KanbanAPI.commentAuthor)
            } catch let e as KanbanAttachmentFiles.Failure {
                failures.append(e.description)
            } catch {
                failures.append("\(VisibleText.reveal(url.lastPathComponent)): \(Self.describe(error))")
            }
            uploading -= 1
        }
        guard selectedTaskId == id else { return }
        await loadAttachments()
        if !failures.isEmpty { attachmentError = "Upload failed: " + failures.joined(separator: " ") }
    }

    /// Downloads an attachment into the app's caches and opens it after the click-time check (or reveals it).
    func open(_ attachment: KanbanAttachment) async {
        guard !opening.contains(attachment.id) else { return }
        opening.insert(attachment.id)
        defer { opening.remove(attachment.id) }
        let name = VisibleText.reveal(attachment.filename)
        do {
            let data = try await api.downloadAttachment(attachment.id, board: slug)
            let root = attachmentRoot
            let (file, action) = try await Task.detached(priority: .userInitiated) {
                let file = try KanbanAttachmentFiles.save(data, filename: attachment.filename, id: attachment.id, root: root)
                return (file, KanbanAttachmentFiles.action(for: file))
            }.value
            if case .refuse(let reason) = action { attachmentError = "“\(name)” was not opened: \(reason)"; return }
            openFile(file, action)
        } catch let e as KanbanAttachmentFiles.Failure {
            attachmentError = "“\(name)” could not be opened: \(e.description)"
        } catch {
            attachmentError = "“\(name)” could not be downloaded: \(Self.describe(error))"
        }
    }

    /// Deletes an attachment (the view asks first). False on failure.
    @discardableResult
    func delete(_ attachment: KanbanAttachment) async -> Bool {
        do {
            try await api.deleteAttachment(attachment.id, board: slug)
            attachments.removeAll { $0.id == attachment.id }
            attachmentError = nil
            await loadAttachments()
            return true
        } catch {
            attachmentError = "Delete “\(VisibleText.reveal(attachment.filename))” failed: \(Self.describe(error))"
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
    /// is not on the board, and when archived unless `keepArchived`: "Show archived" is off, so the board is
    /// fetched without archived cards).
    static func place(_ task: KanbanTask, in lanes: [KanbanLane], keepArchived: Bool = false) -> [KanbanLane] {
        lanes.map { lane in
            let rest = lane.tasks.filter { $0.id != task.id }
            guard lane.name == task.status, keepArchived || task.status != KanbanColumns.archived else {
                return KanbanLane(name: lane.name, tasks: rest)
            }
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
        case _ where isBoardGone(error): return goneMessage
        case PluginREST.Failure.http(_, let detail) where !detail.isEmpty: return detail
        case PluginREST.Failure.pluginUnavailable: return "Kanban is off in Hermes."
        case PluginREST.Failure.unauthorized: return "Hermes refused the session token."
        default: return Redaction.describe(error)
        }
    }
}
