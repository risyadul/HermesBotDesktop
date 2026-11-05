import Foundation
import HermesGatewayKit

// Per-room Activity panel (roadmap C1.3 + C1.10). Hosted-room members run in hidden sessions whose tool
// and reasoning events never reach `groups.log`; the optional `bot-activity` plugin records them keyed by
// the app's room ids. `RoomActivityModel` polls `GET /activity?room=&since=` while the panel shows that
// room, merges pages with `BotActivityFeed`, and maps rows to the room's members. Without the plugin the
// panel falls back to the turn states `RoomPresentation.memberStates` already derives from the timeline.

/// The plugin's REST side, as the panel uses it (`BotActivityAPI` in production, a fake in tests).
protocol BotActivitySource: Sendable {
    func page(room: String, since: Int) async throws -> BotActivityPage
    func setup() async throws -> BotActivitySetup
    func rollOutAll() async throws -> BotActivityRollOut
}

/// Installing and removing the plugin (`BotActivityPluginManager` over `plugins.manage` in production).
protocol BotActivityInstaller: Sendable {
    func pluginState() async throws -> BotActivityPluginManager.State
    func install() async throws
    /// Turns on a copy that is installed but disabled.
    func turnOn() async throws
    func remove() async throws
}

extension BotActivityAPI: BotActivitySource {
    func page(room: String, since: Int) async throws -> BotActivityPage { try await activity(room: room, since: since) }
    func setup() async throws -> BotActivitySetup { try await setupStatus() }
    func rollOutAll() async throws -> BotActivityRollOut { try await rollOut(bots: nil) }
}

extension BotActivityPluginManager: BotActivityInstaller {
    func pluginState() async throws -> State { try await botActivityState() }
    func install() async throws { try await installBotActivity() }
    func turnOn() async throws { try await enableBotActivity() }
    func remove() async throws { try await removeBotActivity() }
}

/// One room member's slice of the activity feed, ready for the panel.
struct MemberActivity: Equatable, Identifiable {
    let member: RoomMember
    let phase: BotActivityPhase
    /// The row behind `phase` (nil when idle).
    let current: BotActivityRow?
    /// Newest first.
    let items: [ActivityItem]
    var id: String { member.memberId }
}

@MainActor
final class RoomActivityModel: ObservableObject {
    enum PluginState: Equatable {
        /// Not polled yet.
        case unknown
        case ready
        /// The plugin is not installed or not enabled (`PluginREST.Failure.pluginUnavailable`).
        case pluginMissing
        /// Working, but these profiles carry no (or an outdated) copy: `POST /setup` would change them.
        case needsRollOut([String])
        /// The last poll failed for another reason (Redaction-safe text); the next success clears it.
        case error(String)
        case enabling
        case removing

        var isBusy: Bool { self == .enabling || self == .removing }
    }

    enum EnableStage: Equatable { case installing, rollingOut }

    nonisolated static let pollInterval: Duration = .seconds(2)
    nonisolated static let maxBackoff: Duration = .seconds(30)

    let roomId: String
    @Published private(set) var members: [RoomMember]
    @Published private(set) var pluginState: PluginState = .unknown
    @Published private(set) var enableStage: EnableStage?
    /// A failed enable / roll-out / remove, until the next action or `dismissActionError()`.
    @Published private(set) var actionError: String?
    @Published private(set) var memberActivity: [MemberActivity] = []
    /// At least one page arrived since the plugin was last found missing.
    @Published private(set) var loaded = false
    /// Open/closed Thought and tool rows, kept while the panel is hidden and shown again.
    let disclosure = DisclosureStore()

    private let source: any BotActivitySource
    private let installer: any BotActivityInstaller
    private let interval: Duration
    private(set) var feed = BotActivityFeed()
    /// Server clock minus local clock (the plugin's `now`), so freshness uses the server's notion of time.
    private var clockSkew: Double = 0
    private var rollOutBots: [String] = []
    private var setupChecked = false
    /// Stable `ChatLine`s per row key: tool and Thought rows keep their identity (and disclosure) across polls.
    private var lines: [String: ChatLine] = [:]
    private var failures = 0
    private var loop: Task<Void, Never>?
    /// Bumped by every start/stop: a poll answered for an older generation is dropped.
    private(set) var generation = 0
    private(set) var droppedStale = 0
    private var shutDown = false

    init(roomId: String, members: [RoomMember], source: any BotActivitySource, installer: any BotActivityInstaller,
         interval: Duration = RoomActivityModel.pollInterval) {
        self.roomId = roomId; self.members = members; self.source = source; self.installer = installer
        self.interval = interval
    }

    var isPolling: Bool { loop != nil }
    /// Server-adjusted epoch seconds.
    var now: Double { Date().timeIntervalSince1970 + clockSkew }

    func setMembers(_ m: [RoomMember]) {
        guard m != members else { return }
        members = m
        rebuild()
    }

    // MARK: polling

    /// The panel is on screen for this room: poll now, then every `interval` (backing off on errors).
    func start() {
        guard loop == nil, !shutDown else { return }
        generation += 1
        let gen = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                let wait = await self.poll()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Panel hidden, room switched or connection lost: no poll result of the current loop is applied.
    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// App quit / backend lost: polling never restarts.
    func shutdown() {
        shutDown = true
        stop()
    }

    /// One `GET /activity` for the current generation; returns the wait before the next one.
    @discardableResult
    func poll() async -> Duration {
        guard !pluginState.isBusy else { return interval }
        let gen = generation
        do {
            let page = try await source.page(room: roomId, since: feed.cursor)
            guard gen == generation else { droppedStale += 1; return interval }
            if let serverNow = page.now { clockSkew = serverNow - Date().timeIntervalSince1970 }
            feed.apply(page)
            loaded = true
            failures = 0
            if !setupChecked { await checkSetup(gen) }
            guard gen == generation else { return interval }
            if !pluginState.isBusy { pluginState = rollOutBots.isEmpty ? .ready : .needsRollOut(rollOutBots) }
            rebuild()
            return interval
        } catch {
            guard gen == generation else { droppedStale += 1; return interval }
            failures += 1
            if !pluginState.isBusy {
                if case PluginREST.Failure.pluginUnavailable = error {
                    pluginState = .pluginMissing
                    resetFeed()
                } else {
                    pluginState = .error(Redaction.describe(error))
                }
            }
            return backoff()
        }
    }

    private func backoff() -> Duration {
        let factor = 1 << min(failures, 4)
        return min(interval * factor, Self.maxBackoff)
    }

    /// `GET /setup` once per load: which bots `rollOut()` would still change. A failure keeps the feed as is.
    private func checkSetup(_ gen: Int) async {
        do {
            let setup = try await source.setup()
            guard gen == generation else { return }
            rollOutBots = Array(Set(setup.untracked + setup.outdated)).sorted()
            setupChecked = true
        } catch {
            AppModel.shared.log("room \(roomId): bot-activity setup check failed: \(Redaction.describe(error))")
        }
    }

    private func resetFeed() {
        feed = BotActivityFeed()
        lines = [:]
        loaded = false
        setupChecked = false
        rollOutBots = []
        rebuild()
    }

    private func rebuild() {
        let built = Self.memberActivity(rows: feed.rows, members: members, now: now, lines: lines)
        lines = built.lines
        if built.members != memberActivity { memberActivity = built.members }
    }

    // MARK: enable / roll out / remove

    var canEnable: Bool {
        switch pluginState {
        case .pluginMissing, .error: return true
        default: return false
        }
    }

    /// Opt-in: install the pinned plugin (or turn on an installed-but-disabled copy), roll it out to every
    /// bot profile with `POST /setup`, then poll again.
    func enable() async {
        guard !pluginState.isBusy else { return }
        let before = pluginState
        actionError = nil
        pluginState = .enabling
        enableStage = .installing
        do {
            switch try await installer.pluginState() {
            case .notInstalled: try await installer.install()
            case .installed(let status, _, _) where status != "enabled": try await installer.turnOn()
            case .installed: break
            }
            enableStage = .rollingOut
            let r = try await source.rollOutAll()
            if !r.ok { actionError = Self.rollOutFailure(r) }
        } catch {
            actionError = "Couldn't enable activity tracking: \(Redaction.describe(error))"
            if case .enabling = pluginState { pluginState = before }
        }
        await finishAction()
    }

    /// "Enable for N more bots": `POST /setup` for every untracked or outdated profile.
    func rollOut() async {
        guard !pluginState.isBusy else { return }
        let before = pluginState
        actionError = nil
        pluginState = .enabling
        enableStage = .rollingOut
        do {
            let r = try await source.rollOutAll()
            if !r.ok { actionError = Self.rollOutFailure(r) }
        } catch {
            actionError = "Couldn't turn activity tracking on for more bots: \(Redaction.describe(error))"
            pluginState = before
        }
        await finishAction()
    }

    /// "Turn off activity tracking": `plugins.manage remove`. The panel falls back to turn status.
    func turnOff() async {
        guard !pluginState.isBusy else { return }
        let before = pluginState
        actionError = nil
        pluginState = .removing
        do {
            try await installer.remove()
            resetFeed()
            pluginState = .pluginMissing
        } catch {
            actionError = "Couldn't turn off activity tracking: \(Redaction.describe(error))"
            pluginState = before
        }
        enableStage = nil
    }

    func dismissActionError() { actionError = nil }

    /// After enable/roll-out: setup is checked again and the panel re-polls at once.
    private func finishAction() async {
        enableStage = nil
        setupChecked = false
        if pluginState.isBusy { pluginState = .unknown }
        await poll()
    }

    nonisolated static func rollOutFailure(_ r: BotActivityRollOut) -> String {
        let failed = r.results.filter { !$0.ok }
        guard !failed.isEmpty else { return "Activity tracking could not be turned on for every bot." }
        let names = failed.map { r in r.error.map { "\(r.bot) (\($0))" } ?? r.bot }.joined(separator: ", ")
        return "Activity tracking could not be turned on for: \(names)."
    }

    // MARK: mapping (pure)

    /// The room member a row belongs to: its `member_id` when that is a member of this room, else the
    /// member whose profile is the row's `bot`; nil (ignored) for a bot that is not in the room.
    nonisolated static func memberId(for row: BotActivityRow, members: [RoomMember]) -> String? {
        if let m = row.memberId, members.contains(where: { $0.memberId == m }) { return m }
        if let bot = row.bot, let m = members.first(where: { $0.profile == bot }) { return m.memberId }
        return nil
    }

    /// Per-member view state in room member order. `lines` carries the stable `ChatLine`s of earlier
    /// builds; the returned map keeps only rows still in the feed.
    nonisolated static func memberActivity(rows: [BotActivityRow], members: [RoomMember], now: Double,
                                           lines: [String: ChatLine] = [:])
        -> (members: [MemberActivity], lines: [String: ChatLine]) {
        var byMember: [String: [BotActivityRow]] = [:]
        for row in rows {
            guard let id = memberId(for: row, members: members) else { continue }
            byMember[id, default: []].append(row)
        }
        var kept: [String: ChatLine] = [:]
        let out = members.map { m -> MemberActivity in
            let rows = byMember[m.memberId] ?? []
            let (phase, current) = BotActivityFeed.phase(of: rows, now: now)
            let items = rows.reversed().map { row -> ActivityItem in
                let item = ActivityPresentation.item(row, now: now, reusing: lines[row.key])
                if let line = item.line { kept[row.key] = line }
                return item
            }
            return MemberActivity(member: m, phase: phase, current: current, items: items)
        }
        return (out, kept)
    }
}

// MARK: - app wiring

extension AppModel {
    /// The Activity model of a room, one per room for the life of the connection (like `roomModel`).
    /// nil without a backend or plugin REST access.
    func activityModel(for room: RoomModel) -> RoomActivityModel? {
        if let m = activityModels[room.id] { return m }
        guard let backend, let access = backend.sessionREST else { return nil }
        let m = RoomActivityModel(roomId: room.id, members: room.room.members, source: BotActivityAPI(access: access),
                                  installer: BotActivityPluginManager(client: backend.client))
        activityModels[room.id] = m
        return m
    }
}
