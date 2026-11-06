import Foundation
import HermesGatewayKit

// Kanban state of one connection: the board list for the sidebar (refreshed on connect and on a slow
// beat), the per-board models, and the app-wide dispatcher (`hermes gateway`) status for K8
// (DispatcherStatusModel.swift). AppModel owns one hub and calls `connect` / `disconnect`; nothing here but
// the dispatcher outlives a connection.
//
// Polling pauses while no main app window is on screen (`setActive`, fed by AppDelegate: app hidden, windows
// minimised or fully covered) and resumes, with a fresh fetch, when one is again.

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
        /// This connection gives no REST access (`Backend.sessionREST` is nil), so boards cannot be loaded.
        case noAccess
        /// The last board list request failed for another reason (kept quiet: the sidebar keeps old rows).
        case failed(String)
    }

    /// Board list cadence: cheap, and boards change rarely. Slower while the plugin is off or failing.
    static let refreshInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 60
    /// How often the dispatcher record is re-read while a board is on screen (a local file check).
    static let dispatcherInterval: TimeInterval = 10

    @Published private(set) var boards: [KanbanBoardSummary] = []
    @Published private(set) var availability: Availability = .unknown
    /// False while no app window is on screen: nothing polls.
    @Published private(set) var isActive = true
    let dispatcher: DispatcherStatusModel
    /// K7: the last board action's result line (KanbanBoardManagement.swift).
    @Published var boardNote: KanbanBoardNote?
    /// K9: a New Task sheet asked for from a message (KanbanIntegrations.swift).
    @Published var compose: KanbanComposeRequest?
    /// K9: watched cards and their watcher (notifications when one finishes or is blocked).
    let watches: KanbanWatchList
    let cardWatcher: KanbanCardWatcher
    /// K9: a watched card moved into Done or Blocked (AppModel posts it).
    var onCardEvent: ((KanbanCardEvent) -> Void)?
    /// The board whose model was asked for last (the default board of a composed task).
    private(set) var lastBoard: String?
    private(set) var api: (any KanbanService)?
    /// Called with the listed (non-archived) slugs after each successful board list: AppModel drops a
    /// selection whose board is gone.
    var onBoardsListed: ((Set<String>) -> Void)?
    /// Not published: created lazily while the detail pane is built.
    private var models: [String: KanbanBoardModel] = [:]
    private var loop: Task<Void, Never>?
    private var dispatcherLoop: Task<Void, Never>?
    private var dispatcherWatchers = 0
    private var generation = 0
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// `watches`: nil keeps watched cards in memory only (tests); the app passes UserDefaults-backed ones.
    init(dispatcher: DispatcherStatusModel = DispatcherStatusModel(), watches: KanbanWatchList? = nil,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.dispatcher = dispatcher
        self.sleep = sleep
        let watches = watches ?? KanbanWatchList(defaults: nil)
        self.watches = watches
        cardWatcher = KanbanCardWatcher(watches: watches, sleep: sleep)
        cardWatcher.boardName = { [weak self] slug in self?.summary(slug)?.name ?? slug }
        cardWatcher.onEvent = { [weak self] e in self?.onCardEvent?(e) }
    }

    var rows: [KanbanSidebarRow] { Self.sidebarRows(boards) }
    var isPolling: Bool { loop != nil }
    var isWatchingDispatcher: Bool { dispatcherLoop != nil }

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
        case .noAccess: return "Boards unavailable on this connection"
        case .failed: return "Boards not loaded"
        }
    }

    /// Hover help for the placeholder.
    static func sidebarPlaceholderHelp(_ availability: Availability) -> String {
        switch availability {
        case .off: return "Enable the kanban plugin in Hermes to see boards here."
        case .noAccess: return "This Hermes connection gives the app no REST access, which Kanban needs. Reconnecting to a current Hermes fixes it."
        default: return ""
        }
    }

    /// True while a main app window shows on screen: the app is not hidden and a main window (not Settings)
    /// is visible, not minimised and not fully covered.
    static func onScreen(appHidden: Bool, windows: [(main: Bool, visible: Bool, miniaturized: Bool, unoccluded: Bool)]) -> Bool {
        !appHidden && windows.contains { $0.main && $0.visible && !$0.miniaturized && $0.unoccluded }
    }

    func summary(_ slug: String) -> KanbanBoardSummary? { boards.first { $0.slug == slug } }

    // MARK: lifecycle

    /// A new connection: `api` is nil when the backend gives no REST access (`.noAccess`: the sidebar says so).
    func connect(api: (any KanbanService)?) {
        disconnect()
        self.api = api
        guard let api else {
            availability = .noAccess
            return
        }
        cardWatcher.start(api: api)
        if isActive {
            startLoop()
        } else {
            // Off screen (e.g. launched behind other windows): pausing stops the periodic refresh, but the
            // sidebar still gets its first list, or it would say "Not loaded yet" until the window shows.
            Task { [weak self] in await self?.refreshBoards() }
        }
    }

    /// Connection lost or app quitting: every board stops polling and the list empties.
    func disconnect() {
        generation += 1
        loop?.cancel()
        loop = nil
        for m in models.values { m.stop() }
        models = [:]
        cardWatcher.stop()
        compose = nil
        boardNote = nil
        api = nil
        boards = []
        availability = .unknown
        dispatcher.reset()
    }

    /// App windows left or came back on screen. Off: the board list, every board and the dispatcher stop
    /// polling (a board keeps wanting to poll). On: they start again, each with an immediate fetch.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for m in models.values { m.setSuspended(!active) }
        if active {
            if api != nil, loop == nil { startLoop() }
        } else {
            loop?.cancel()
            loop = nil
        }
        updateDispatcherLoop()
    }

    /// A board view appeared (`true`) or went away: the dispatcher record is re-read every
    /// `dispatcherInterval` while at least one is on screen and the app is active.
    func watchDispatcher(_ on: Bool) {
        dispatcherWatchers = max(0, dispatcherWatchers + (on ? 1 : -1))
        updateDispatcherLoop()
    }

    private func updateDispatcherLoop() {
        let wanted = dispatcherWatchers > 0 && isActive
        if wanted, dispatcherLoop == nil {
            let sleep = self.sleep, dispatcher = self.dispatcher
            dispatcherLoop = Task { [weak dispatcher] in
                while !Task.isCancelled {
                    guard let dispatcher else { return }
                    await dispatcher.refresh()
                    do { try await sleep(Self.dispatcherInterval) } catch { return }
                }
            }
        } else if !wanted {
            dispatcherLoop?.cancel()
            dispatcherLoop = nil
        }
    }

    private func startLoop() {
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.refreshLoopStep(gen) else { return }
                do { try await sleep(wait) } catch { return }
            }
        }
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
            if availability != .available { availability = .available }
            // A board deleted or archived elsewhere: its model stops and goes; the selection follows.
            let listed = Set(list.boards.filter { !$0.archived }.map(\.slug))
            for (slug, m) in models where !listed.contains(slug) {
                m.stop()
                models[slug] = nil
            }
            onBoardsListed?(listed)
        } catch {
            guard gen == generation else { return }
            if case PluginREST.Failure.pluginUnavailable = error {
                if !boards.isEmpty { boards = [] }
                if availability != .off { availability = .off }
            } else {
                let failed = Availability.failed(KanbanBoardModel.describe(error))
                if availability != failed { availability = failed }
            }
        }
    }

    /// The board's model, created on first use (nil when not connected).
    func model(for slug: String) -> KanbanBoardModel? {
        lastBoard = slug
        if let m = models[slug] { return m }
        guard let api else { return nil }
        let m = KanbanBoardModel(slug: slug, api: api)
        m.watches = watches
        m.onCreated = { [weak self] t in self?.cardWatcher.watch(slug, t) }
        m.setSuspended(!isActive)
        models[slug] = m
        return m
    }
}

// MARK: - dispatcher chip (K8)

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
