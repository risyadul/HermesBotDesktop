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
    /// The pinned commit; `force` replaces a copy that is already there.
    func install(force: Bool) async throws
    /// Turns on a copy that is installed but disabled.
    func turnOn() async throws
    /// Removes the root copy (`<HERMES_HOME>/plugins/bot-activity`) only.
    func remove() async throws
}

/// Turning the plugin on/off in one bot profile (`BotActivityProfileSwitch`, the Hermes CLI, in production).
protocol BotActivityProfileToggle: Sendable {
    func setEnabled(_ enable: Bool, bot: String) async throws
}

extension BotActivityAPI: BotActivitySource {
    func page(room: String, since: Int) async throws -> BotActivityPage { try await activity(room: room, since: since) }
    func setup() async throws -> BotActivitySetup { try await setupStatus() }
    func rollOutAll() async throws -> BotActivityRollOut { try await rollOut(bots: nil) }
}

extension BotActivityPluginManager: BotActivityInstaller {
    func pluginState() async throws -> State { try await botActivityState() }
    func install(force: Bool) async throws { try await installBotActivity(force: force) }
    func turnOn() async throws { try await enableBotActivity() }
    func remove() async throws { try await removeBotActivity() }
}

extension BotActivityProfileSwitch: BotActivityProfileToggle {}

/// App-wide gate for the plugin actions (enable, roll-out, reinstall, turn off). They change Hermes for every
/// room, so the same request from a second room while one is in flight joins it (same progress, same outcome)
/// instead of starting another; a different action is refused (`busyMessage`) until it finishes.
@MainActor
final class BotActivityActionGate: ObservableObject {
    enum Action: Equatable { case enable, rollOut, reinstall, turnOff }

    struct Outcome: Equatable {
        /// Redaction-safe, per-bot where it applies.
        var error: String?
        /// The root copy was removed: the panel falls back to turn status.
        var removed = false
        /// An installed, disabled copy is not the reviewed commit: nothing was turned on.
        var unpinned = false
        /// The pinned commit replaced a copy that was not (reinstall): the "not the reviewed version" warning is over.
        var replaced = false
    }

    static let shared = BotActivityActionGate()
    static let busyMessage = "Another activity action is running; try again when it finishes."

    @Published private(set) var action: Action?
    @Published var stage: RoomActivityModel.EnableStage?
    private var task: Task<Outcome, Never>?

    var isBusy: Bool { task != nil }

    /// Runs `body` unless an action is already in flight: the same action is joined (its outcome awaited), a
    /// different one is refused without running.
    func run(_ action: Action, _ body: @escaping @MainActor () async -> Outcome) async -> Outcome {
        if let task {
            guard action == self.action else { return Outcome(error: Self.busyMessage) }
            return await task.value
        }
        self.action = action
        let t = Task { @MainActor [weak self] in
            let out = await body()
            // Cleared before any waiter resumes, so a joined room's follow-up poll is not gated.
            self?.task = nil
            self?.action = nil
            self?.stage = nil
            return out
        }
        task = t
        return await t.value
    }
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
        /// Enable found an installed, disabled copy that is not provably the reviewed commit (no install record
        /// pinning it to `BotActivityPluginManager.pinnedRef`): nothing was toggled. Reinstall replaces it.
        case unpinnedCopy
        case enabling
        case removing

        var isBusy: Bool { self == .enabling || self == .removing }
    }

    enum EnableStage: Equatable { case installing, rollingOut }

    nonisolated static let pollInterval: Duration = .seconds(2)
    nonisolated static let maxBackoff: Duration = .seconds(30)
    /// After a failed `GET /setup`, polls skip it this long (an action or a reload checks again sooner).
    nonisolated static let setupRetryDelay: Duration = .seconds(60)

    let roomId: String
    @Published private(set) var members: [RoomMember]
    @Published private(set) var pluginState: PluginState = .unknown
    /// A failed enable / roll-out / remove, until the next action or `dismissActionError()`.
    @Published private(set) var actionError: String?
    @Published private(set) var memberActivity: [MemberActivity] = []
    /// At least one page arrived since the plugin was last found missing.
    @Published private(set) var loaded = false
    /// Open/closed Thought and tool rows, kept while the panel is hidden and shown again.
    let disclosure = DisclosureStore()

    private let source: any BotActivitySource
    private let installer: any BotActivityInstaller
    private let profiles: any BotActivityProfileToggle
    let gate: BotActivityActionGate
    private let interval: Duration
    private(set) var feed = BotActivityFeed()
    /// Server clock minus local clock (the plugin's `now`), so freshness uses the server's notion of time.
    private var clockSkew: Double = 0
    private var rollOutBots: [String] = []
    private var setupChecked = false
    /// A failed setup check is not retried before this (nil: no failure pending).
    private var setupRetryAt: ContinuousClock.Instant?
    /// The setup check has failed since its last success: logged once per streak.
    private var setupFailing = false
    /// Stable `ChatLine`s per row key: tool and Thought rows keep their identity (and disclosure) across polls.
    private var lines: [String: ChatLine] = [:]
    private(set) var failures = 0
    private var loop: Task<Void, Never>?
    /// Bumped by every start/stop: a poll answered for an older generation is dropped.
    private(set) var generation = 0
    private(set) var droppedStale = 0
    private var shutDown = false
    /// The panels showing this room (`start()` … `stop()`; D9: one per window) and whether their windows are
    /// on screen (`setVisible`).
    private var viewers = PaneViewers()
    /// Some panel shows this room.
    private var wanted: Bool { !viewers.isEmpty }
    /// A panel's window is on screen and the app not hidden.
    var visible: Bool { viewers.anyVisible }

    init(roomId: String, members: [RoomMember], source: any BotActivitySource, installer: any BotActivityInstaller,
         profiles: any BotActivityProfileToggle, gate: BotActivityActionGate = .shared,
         interval: Duration = RoomActivityModel.pollInterval) {
        self.roomId = roomId; self.members = members; self.source = source; self.installer = installer
        self.profiles = profiles; self.gate = gate; self.interval = interval
    }

    var isPolling: Bool { loop != nil }
    /// What the enable in flight (this room's or one it joined) is doing.
    var enableStage: EnableStage? { pluginState == .enabling ? gate.stage : nil }
    /// Server-adjusted epoch seconds.
    var now: Double { Date().timeIntervalSince1970 + clockSkew }

    func setMembers(_ m: [RoomMember]) {
        guard m != members else { return }
        members = m
        rebuild()
    }

    // MARK: polling

    /// The panel is on screen for this room: poll now, then every `interval` (backing off on errors), while
    /// the window is visible.
    func start(viewer: ObjectIdentifier = PaneViewers.anonymous) {
        viewers.add(viewer)
        guard visible else { return }
        startLoop()
    }

    /// A panel's window was occluded / the app hidden (false), or is back (true): polling pauses while no
    /// panel showing this room is on screen, and resumes when one is.
    func setVisible(_ v: Bool, viewer: ObjectIdentifier = PaneViewers.anonymous) {
        let before = visible
        viewers.setVisible(v, viewer)
        guard visible != before else { return }
        if visible {
            if wanted { startLoop() }
        } else {
            halt()
        }
    }

    private func startLoop() {
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

    /// "Try Again": a fresh loop that polls now, with the backoff reset (never a second poll beside the loop).
    func retry() {
        failures = 0
        guard wanted, visible, !shutDown else { return }
        halt()
        startLoop()
    }

    /// Panel hidden, room switched or connection lost: no poll result of the current loop is applied.
    func stop(viewer: ObjectIdentifier = PaneViewers.anonymous) {
        viewers.remove(viewer)
        guard !wanted || !visible else { return }  // another panel (window, D9) still shows the room
        halt()
    }

    private func halt() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// App quit / backend lost: polling never restarts.
    func shutdown() {
        shutDown = true
        viewers.removeAll()
        halt()
    }

    /// One `GET /activity` for the current generation; returns the wait before the next one.
    @discardableResult
    func poll() async -> Duration {
        guard !pluginState.isBusy, !gate.isBusy else { return interval }
        let gen = generation
        do {
            let page = try await source.page(room: roomId, since: feed.cursor)
            guard gen == generation else { droppedStale += 1; return interval }
            if let serverNow = page.now { clockSkew = serverNow - Date().timeIntervalSince1970 }
            feed.apply(page, room: roomId)
            loaded = true
            failures = 0
            if !setupChecked, setupRetryAt.map({ ContinuousClock.now >= $0 }) ?? true { await checkSetup(gen) }
            guard gen == generation else { return interval }
            if !pluginState.isBusy { pluginState = rollOutBots.isEmpty ? .ready : .needsRollOut(rollOutBots) }
            rebuild()
            return interval
        } catch {
            guard gen == generation else { droppedStale += 1; return interval }
            failures += 1
            if !pluginState.isBusy {
                if case PluginREST.Failure.pluginUnavailable = error {
                    // Kept until an action or a working plugin replaces it: the plugin is missing either way.
                    if pluginState != .unpinnedCopy { pluginState = .pluginMissing }
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

    /// `GET /setup` once per load: which bots `rollOut()` would still change. A failure keeps the feed as is
    /// and is not retried for `setupRetryDelay` (logged once per run of failures).
    private func checkSetup(_ gen: Int) async {
        do {
            let setup = try await source.setup()
            guard gen == generation else { return }
            rollOutBots = Array(Set(setup.untracked + setup.outdated)).sorted()
            setupChecked = true
            setupRetryAt = nil
            setupFailing = false
        } catch {
            guard gen == generation else { return }
            setupRetryAt = ContinuousClock.now + Self.setupRetryDelay
            guard !setupFailing else { return }
            setupFailing = true
            AppModel.shared.log("room \(roomId): bot-activity setup check failed: \(Redaction.describe(error))")
        }
    }

    /// The next poll checks `GET /setup` again, even within a failure's retry delay.
    private func recheckSetup() {
        setupChecked = false
        setupRetryAt = nil
    }

    private func resetFeed() {
        feed = BotActivityFeed()
        lines = [:]
        loaded = false
        recheckSetup()
        rollOutBots = []
        rebuild()
    }

    private func rebuild() {
        let built = Self.memberActivity(rows: feed.rows, members: members, now: now, lines: lines)
        lines = built.lines
        if built.members != memberActivity { memberActivity = built.members }
    }

    // MARK: enable / roll out / reinstall / turn off

    var canEnable: Bool {
        switch pluginState {
        case .pluginMissing, .error: return true
        default: return false
        }
    }

    /// Opt-in: install the pinned plugin (or turn on an installed-but-disabled copy that is provably the pinned
    /// one), turn it back on in profiles that have it disabled, roll it out to every bot with `POST /setup`,
    /// then poll again.
    func enable() async {
        let (source, installer, profiles, gate) = (source, installer, profiles, gate)
        await perform(.enable) {
            gate.stage = .installing
            do {
                let state = try await installer.pluginState()
                switch state {
                case .notInstalled: try await installer.install(force: false)
                case .installed(let status, _, _, _) where status != "enabled":
                    guard state.isPinnedCopy else { return .init(unpinned: true) }
                    try await installer.turnOn()
                case .installed: break
                }
                gate.stage = .rollingOut
                return try await Self.rollOutEverywhere(source: source, profiles: profiles)
            } catch {
                return .init(error: "Couldn't enable activity tracking: \(Redaction.describe(error))")
            }
        }
    }

    /// "Reinstall Pinned Version": replace the installed copy with the pinned commit (`force`), then the same
    /// roll-out as `enable()`.
    func reinstallPinned() async {
        guard pluginState == .unpinnedCopy else { return }
        let (source, installer, profiles, gate) = (source, installer, profiles, gate)
        await perform(.reinstall) {
            gate.stage = .installing
            do { try await installer.install(force: true) } catch {
                return .init(error: "Couldn't reinstall the Bot Activity plugin: \(Redaction.describe(error))")
            }
            gate.stage = .rollingOut
            do {
                var out = try await Self.rollOutEverywhere(source: source, profiles: profiles)
                out.replaced = true
                return out
            } catch {
                return .init(error: "Couldn't enable activity tracking: \(Redaction.describe(error))", replaced: true)
            }
        }
    }

    /// "Enable for N more bots": `POST /setup` for every untracked or outdated profile.
    func rollOut() async {
        let (source, gate) = (source, gate)
        await perform(.rollOut) {
            gate.stage = .rollingOut
            do {
                let r = try await source.rollOutAll()
                return .init(error: r.ok ? nil : Self.rollOutFailure(r))
            } catch {
                return .init(error: "Couldn't turn activity tracking on for more bots: \(Redaction.describe(error))")
            }
        }
    }

    /// "Turn off activity tracking": `hermes -p <bot> plugins disable bot-activity` for every profile that has a
    /// copy (`GET /setup`), then `plugins.manage remove` of the root copy. Profile copies stay on disk, inactive;
    /// Enable turns them back on. The panel falls back to turn status only when the root copy is gone.
    func turnOff() async {
        let (source, installer, profiles) = (source, installer, profiles)
        await perform(.turnOff) {
            let setup: BotActivitySetup
            do { setup = try await source.setup() } catch {
                return .init(error: "Couldn't turn off activity tracking: couldn't list the bots: \(Redaction.describe(error))")
            }
            var failed: [(bot: String, error: String?)] = []
            for p in setup.profiles where p.installed || p.tracked {
                do { try await profiles.setEnabled(false, bot: p.bot) } catch { failed.append((p.bot, Redaction.describe(error))) }
            }
            do { try await installer.remove() } catch {
                let partial = failed.isEmpty ? "" : " " + Self.botFailure("It also could not be turned off for", failed)
                return .init(error: "Couldn't turn off activity tracking: \(Redaction.describe(error)).\(partial)")
            }
            return .init(error: failed.isEmpty ? nil : Self.botFailure("Activity tracking was removed, but could not be turned off for", failed),
                         removed: true)
        }
    }

    func dismissActionError() { actionError = nil }

    /// Runs `body` through the app-wide gate (or joins the same action already in flight), then applies the
    /// outcome. Another action in flight refuses it with `BotActivityActionGate.busyMessage`.
    private func perform(_ action: BotActivityActionGate.Action,
                         _ body: @escaping @MainActor () async -> BotActivityActionGate.Outcome) async {
        guard !pluginState.isBusy else { return }
        if let running = gate.action, running != action {
            actionError = BotActivityActionGate.busyMessage
            return
        }
        let before = pluginState
        actionError = nil
        pluginState = action == .turnOff ? .removing : .enabling
        let out = await gate.run(action, body)
        actionError = out.error
        if out.removed {
            resetFeed()
            pluginState = .pluginMissing
        } else if out.unpinned {
            resetFeed()
            pluginState = .unpinnedCopy
        } else {
            pluginState = out.replaced ? .pluginMissing : before
            recheckSetup()
            await poll()
        }
    }

    /// Profiles that list the plugin in `plugins.disabled` (opted out, e.g. by Turn Off) are skipped by
    /// `POST /setup`, so they are turned back on with the CLI first; then `POST /setup` installs/refreshes the
    /// rest. Failures are collected per bot.
    nonisolated static func rollOutEverywhere(source: any BotActivitySource,
                                              profiles: any BotActivityProfileToggle) async throws -> BotActivityActionGate.Outcome {
        let setup = try await source.setup()
        var failed: [(bot: String, error: String?)] = []
        for bot in setup.optedOut {
            do { try await profiles.setEnabled(true, bot: bot) } catch { failed.append((bot, Redaction.describe(error))) }
        }
        let r = try await source.rollOutAll()
        failed += r.results.filter { !$0.ok }.map { ($0.bot, $0.error) }
        if failed.isEmpty { return .init(error: r.ok ? nil : rollOutFailure(r)) }
        return .init(error: botFailure("Activity tracking could not be turned on for", failed))
    }

    nonisolated static func rollOutFailure(_ r: BotActivityRollOut) -> String {
        let failed = r.results.filter { !$0.ok }
        guard !failed.isEmpty else { return "Activity tracking could not be turned on for every bot." }
        return botFailure("Activity tracking could not be turned on for", failed.map { ($0.bot, $0.error) })
    }

    /// "<lead>: bob (read-only profile), eve."
    nonisolated static func botFailure(_ lead: String, _ failed: [(bot: String, error: String?)]) -> String {
        "\(lead): " + failed.map { f in f.error.map { "\(f.bot) (\($0))" } ?? f.bot }.joined(separator: ", ") + "."
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
                                  installer: BotActivityPluginManager(client: backend.client), profiles: BotActivityProfileSwitch())
        activityModels[room.id] = m
        return m
    }
}
