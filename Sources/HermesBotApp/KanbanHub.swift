import Foundation
import HermesGatewayKit

// Kanban state of one connection: the board list for the sidebar (refreshed on connect and on a slow
// beat), the per-board models, and the dispatcher (`hermes gateway`) status for K8. AppModel owns one hub
// and calls `connect` / `disconnect`; nothing here outlives a connection.

/// One sidebar row: a non-archived board with its running / blocked counts.
struct KanbanSidebarRow: Equatable, Identifiable {
    let slug: String
    let name: String
    let running: Int
    let blocked: Int
    let total: Int
    var id: String { slug }
}

@MainActor
final class KanbanHub: ObservableObject {
    enum Availability: Equatable {
        /// Not connected or not asked yet.
        case unknown
        case available
        /// The kanban plugin is not served (disabled in Hermes, or too old).
        case off
        /// The last board list request failed for another reason (kept quiet: the sidebar keeps old rows).
        case failed(String)
    }

    /// Board list cadence: cheap, and boards change rarely. Slower while the plugin is off or failing.
    static let refreshInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 60

    @Published private(set) var boards: [KanbanBoardSummary] = []
    @Published private(set) var availability: Availability = .unknown
    let dispatcher = DispatcherStatusModel()
    private(set) var api: (any KanbanService)?
    /// Not published: created lazily while the detail pane is built.
    private var models: [String: KanbanBoardModel] = [:]
    private var loop: Task<Void, Never>?
    private var generation = 0
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.sleep = sleep
    }

    var rows: [KanbanSidebarRow] { Self.sidebarRows(boards) }

    /// Archived boards are hidden; server order is kept.
    static func sidebarRows(_ boards: [KanbanBoardSummary]) -> [KanbanSidebarRow] {
        boards.filter { !$0.archived }.map {
            KanbanSidebarRow(slug: $0.slug, name: $0.name, running: $0.counts["running"] ?? 0,
                             blocked: $0.counts["blocked"] ?? 0, total: $0.total)
        }
    }

    /// The sidebar's muted line instead of board rows, or nil when there are rows.
    static func sidebarPlaceholder(connected: Bool, availability: Availability, rows: Int) -> String? {
        guard rows == 0 else { return nil }
        guard connected else { return "Not loaded yet" }
        switch availability {
        case .unknown: return "Not loaded yet"
        case .available: return "No boards"
        case .off: return "Kanban is off in Hermes"
        case .failed: return "Boards not loaded"
        }
    }

    func summary(_ slug: String) -> KanbanBoardSummary? { boards.first { $0.slug == slug } }

    // MARK: lifecycle

    /// A new connection: `api` is nil when the backend gives no REST access (the section then says so).
    func connect(api: (any KanbanService)?, gateway: GatewayStatus?) {
        disconnect()
        self.api = api
        dispatcher.attach(gateway)
        guard api != nil else { return }
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.refreshLoopStep(gen) else { return }
                do { try await sleep(wait) } catch { return }
            }
        }
    }

    /// Connection lost or app quitting: every board stops polling and the list empties.
    func disconnect() {
        generation += 1
        loop?.cancel()
        loop = nil
        for m in models.values { m.stop() }
        models = [:]
        api = nil
        boards = []
        availability = .unknown
        dispatcher.attach(nil)
    }

    private func refreshLoopStep(_ gen: Int) async -> TimeInterval? {
        guard gen == generation else { return nil }
        await refreshBoards()
        guard gen == generation else { return nil }
        return availability == .available ? Self.refreshInterval : Self.idleInterval
    }

    func refreshBoards() async {
        guard let api else { return }
        let gen = generation
        do {
            let list = try await api.boards(includeArchived: false)
            guard gen == generation else { return }
            if boards != list.boards { boards = list.boards }
            availability = .available
        } catch {
            guard gen == generation else { return }
            if case PluginREST.Failure.pluginUnavailable = error {
                boards = []
                availability = .off
            } else {
                availability = .failed(KanbanBoardModel.describe(error))
            }
        }
    }

    /// The board's model, created on first use (nil when not connected).
    func model(for slug: String) -> KanbanBoardModel? {
        if let m = models[slug] { return m }
        guard let api else { return nil }
        let m = KanbanBoardModel(slug: slug, api: api)
        models[slug] = m
        return m
    }
}

// MARK: - dispatcher (K8)

/// `hermes gateway` runs the kanban dispatcher: without it, ready + assigned cards never start.
@MainActor
final class DispatcherStatusModel: ObservableObject {
    @Published private(set) var state: GatewayStatus.State?
    @Published private(set) var starting = false
    /// Outcome of the last Start, in plain words.
    @Published private(set) var startResult: String?
    @Published private(set) var startFailed = false
    private(set) var status: GatewayStatus?

    /// The record may appear a moment after `hermes gateway start` returns: one re-check after this.
    static let settleDelay: TimeInterval = 2

    func attach(_ status: GatewayStatus?) {
        self.status = status
        state = nil
        starting = false
        startResult = nil
        startFailed = false
    }

    /// Reads the record and the LaunchAgent (file system only; off the main actor).
    func refresh() async {
        guard let status else { return }
        let s = await Task.detached { status.state() }.value
        guard self.status != nil else { return }
        state = s
    }

    func start() async {
        guard let status, !starting else { return }
        starting = true
        startResult = nil
        startFailed = false
        do {
            try await status.start()
            startResult = "Dispatcher started."
        } catch {
            startFailed = true
            startResult = "Start failed: \(Redaction.describe(error))"
        }
        starting = false
        await refresh()
        if !startFailed, DispatcherChip.kind(state: state, starting: false) != .running {
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            await refresh()
        }
    }
}

/// What the board header's dispatcher chip shows.
enum DispatcherChip {
    enum Kind: Equatable {
        case checking
        case running
        case stopped
        case starting
        case notInstalled
        case unknown(String)
    }

    static func kind(state: GatewayStatus.State?, starting: Bool) -> Kind {
        if starting { return .starting }
        switch state {
        case nil: return .checking
        case .running?: return .running
        case .installedNotRunning?: return .stopped
        case .notInstalled?: return .notInstalled
        case .unknown(let why)?: return .unknown(why)
        }
    }

    static func label(_ kind: Kind) -> String {
        switch kind {
        case .checking: return "Checking dispatcher…"
        case .running: return "Dispatcher running"
        case .stopped: return "Dispatcher stopped"
        case .starting: return "Starting dispatcher…"
        case .notInstalled: return "Dispatcher not installed"
        case .unknown: return "Dispatcher status unknown"
        }
    }

    /// The chip asks for the user (attention role) when cards cannot run.
    static func needsAttention(_ kind: Kind) -> Bool {
        switch kind {
        case .stopped, .notInstalled: return true
        default: return false
        }
    }

    static let explanation = "Cards only run while hermes gateway runs: it hosts the kanban dispatcher, which hands ready, assigned cards to their bots."
}
