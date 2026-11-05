import Foundation
import HermesGatewayKit

// Kanban workers (roadmap K5): the active workers of one board (`GET /workers/active`), polled while the
// Workers sheet is open, with Inspect (the run record, the worker process and its log), Terminate
// (`POST /runs/{id}/terminate`) and Reclaim (`POST /tasks/{id}/reclaim`). Both stop the worker
// (SIGTERM, then SIGKILL) and put the card back for the dispatcher; the view asks first.

/// What a worker row says, from the server's fields and the server's clock (`checked_at`) only.
struct KanbanWorkerStatus: Equatable {
    /// "4m": since the run started.
    let elapsed: String?
    /// "12s ago", or "none yet" when the worker never sent one.
    let heartbeat: String
    /// No heartbeat for 2+ minutes (Desktop's threshold): the worker may have died.
    let stale: Bool

    init(_ w: KanbanActiveWorker, now: Int) {
        elapsed = w.startedAt.map { KanbanAge.short(now - $0) }
        if let beat = w.lastHeartbeatAt {
            let age = now - beat
            heartbeat = age < 10 ? "just now" : "\(KanbanAge.short(age)) ago"
            stale = age > KanbanCardFlags.staleHeartbeat
        } else {
            heartbeat = "none yet"
            stale = false
        }
    }
}

@MainActor
final class KanbanWorkersModel: ObservableObject {
    enum LoadState: Equatable { case loading, ready, unavailable, failed(String) }

    /// The run, its process and its log, as far as each could be read.
    struct Inspection: Equatable {
        let worker: KanbanActiveWorker
        var run: KanbanRun?
        var process: KanbanRunProcess?
        var log: KanbanWorkerLog?
        /// One line per part that could not be read.
        var problems: [String] = []
    }

    static let interval: TimeInterval = 5
    static let terminateReason = "Terminated from Hermes Bot"

    let slug: String
    let api: any KanbanService
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var workers: [KanbanActiveWorker] = []
    @Published private(set) var checkedAt: Int?
    /// A refreshing poll failed while the list was shown (kept on screen).
    @Published private(set) var syncError: String?
    /// The last failed action, in plain words.
    @Published private(set) var error: String?
    /// The last finished action ("Terminated …").
    @Published private(set) var notice: String?
    @Published private(set) var inspection: Inspection?
    @Published private(set) var inspecting: Int?
    /// Runs with a terminate or reclaim in flight.
    @Published private(set) var busy: Set<Int> = []

    /// Called after a terminate or reclaim went through (the board refreshes).
    var onChanged: (() -> Void)?
    private(set) var generation = 0
    private var loop: Task<Void, Never>?
    private var fetchSeq = 0
    private var appliedFetch = 0

    init(slug: String, api: any KanbanService,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.slug = slug; self.api = api; self.sleep = sleep
    }

    var isPolling: Bool { loop != nil }

    func status(_ w: KanbanActiveWorker) -> KanbanWorkerStatus {
        KanbanWorkerStatus(w, now: checkedAt ?? Int(Date().timeIntervalSince1970))
    }

    // MARK: polling

    func start() {
        guard loop == nil else { return }
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                await self.fetch(generation: gen)
                do { try await sleep(Self.interval) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    func refresh() async { await fetch(generation: generation) }

    private func fetch(generation gen: Int) async {
        fetchSeq += 1
        let mine = fetchSeq
        do {
            let list = try await api.activeWorkers(board: slug)
            guard gen == generation, mine > appliedFetch else { return }
            appliedFetch = mine
            workers = list.workers
            checkedAt = list.checkedAt
            state = .ready
            syncError = nil
        } catch {
            guard gen == generation, mine > appliedFetch else { return }
            if case PluginREST.Failure.pluginUnavailable = error { state = .unavailable; return }
            let text = KanbanBoardModel.describe(error)
            if state == .ready { syncError = text } else { state = .failed(text) }
        }
    }

    // MARK: inspect

    /// Loads the run record, the process stats and the log tail together; each part that fails is named,
    /// the others still show.
    func inspect(_ w: KanbanActiveWorker) async {
        inspecting = w.runId
        defer { if inspecting == w.runId { inspecting = nil } }
        let api = self.api, slug = self.slug
        async let run = Self.attempt { try await api.run(w.runId, board: slug) }
        async let process = Self.attempt { try await api.inspectRun(w.runId, board: slug) }
        async let log = Self.attempt { try await api.log(taskId: w.taskId, board: slug, tailBytes: KanbanAPI.defaultLogTail) }
        let (r, p, l) = await (run, process, log)
        var out = Inspection(worker: w, run: r.value, process: p.value, log: l.value)
        if let e = r.error { out.problems.append("Run not loaded: \(e)") }
        if let e = p.error { out.problems.append("Process not inspected: \(e)") }
        if let e = l.error { out.problems.append("Log not loaded: \(e)") }
        inspection = out
    }

    func closeInspection() { inspection = nil }

    private static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> (value: T?, error: String?) {
        do { return (try await body(), nil) } catch { return (nil, KanbanBoardModel.describe(error)) }
    }

    // MARK: terminate / reclaim (the view confirms first)

    @discardableResult
    func terminate(_ w: KanbanActiveWorker) async -> Bool {
        await act(w, what: "Terminate “\(w.taskTitle)”", done: "Terminated the run of “\(w.taskTitle)”.") { api, slug in
            try await api.terminateRun(w.runId, board: slug, reason: Self.terminateReason)
        }
    }

    @discardableResult
    func reclaim(_ w: KanbanActiveWorker) async -> Bool {
        await act(w, what: "Reclaim “\(w.taskTitle)”", done: "Reclaimed “\(w.taskTitle)”: it goes back to Ready.") { api, slug in
            try await api.reclaim(w.taskId, board: slug, reason: nil)
        }
    }

    private func act(_ w: KanbanActiveWorker, what: String, done: String,
                     _ call: @escaping @Sendable (any KanbanService, String) async throws -> Void) async -> Bool {
        guard !busy.contains(w.runId) else { return false }
        busy.insert(w.runId)
        defer { busy.remove(w.runId) }
        error = nil; notice = nil
        do {
            try await call(api, slug)
            notice = done
            if inspection?.worker.runId == w.runId { inspection = nil }
            onChanged?()
            await refresh()
            return true
        } catch {
            self.error = "\(what) failed: \(KanbanBoardModel.describe(error))"
            await refresh()
            return false
        }
    }

    func dismissMessages() { error = nil; notice = nil }
}
