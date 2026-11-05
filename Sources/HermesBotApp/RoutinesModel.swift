import Foundation
import HermesGatewayKit

// Routines (roadmap A15): one bot's scheduled jobs (`cron.manage`, HermesGatewayKit Routines.swift), loaded
// while the Routines sheet is open and refreshed every 20 s like Desktop's pane. Pause/Resume shows at once
// (an overlay until the server agrees) and is rolled back with an error when refused. Like Desktop's
// `loadRoutines`, an active legacy delegated job is paused on load (its failure never fails the list).

@MainActor
final class RoutinesModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }

    /// The form's fields that are not the schedule.
    struct Draft: Equatable {
        var title = ""
        var instruction = ""
        var schedule = RoutineSchedule()
        var continuity = false
        var deliverToBotChat = false
    }

    static let interval: TimeInterval = 20

    let bot: String
    /// The profile a gateway without profile scoping runs jobs in (`hermes serve`'s launch profile).
    let launchProfile: String
    let api: RoutinesAPI
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var phase: Phase = .loading
    /// Every job the store returned, and the ones shown for this bot.
    @Published private(set) var all: [RoutineJob] = []
    @Published private(set) var jobs: [RoutineJob] = []
    /// The profile the gateway proved it scoped the store to (nil on an older gateway).
    @Published private(set) var scoped: String?
    /// The last refresh failed while a list was shown (it stays on screen).
    @Published private(set) var refreshError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var notice: String?
    /// Pause/Resume sent and not yet confirmed by a list: job id → wanted active state.
    @Published private(set) var pendingActive: [String: Bool] = [:]
    /// Jobs with an action in flight.
    @Published private(set) var busy: Set<String> = []

    private(set) var generation = 0
    private var loop: Task<Void, Never>?
    private var loadSeq = 0
    private var appliedLoad = 0

    init(bot: String, launchProfile: String = Routines.launchProfile, api: RoutinesAPI,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.bot = bot; self.launchProfile = launchProfile; self.api = api; self.sleep = sleep
    }

    var isPolling: Bool { loop != nil }
    var filterHint: String? { Routines.filterHint(all: all, shown: jobs) }
    /// The profile new routines run in (decides the prompt shape, `Routines.prompt`).
    var activeProfile: String { Routines.promptProfile(scoped: scoped, bot: bot, launchProfile: launchProfile) }

    func job(_ id: String) -> RoutineJob? { jobs.first { $0.id == id } }
    func isActive(_ job: RoutineJob) -> Bool { pendingActive[job.id] ?? Routines.isActive(job) }
    func dismissMessages() { actionError = nil; notice = nil }

    // MARK: loading

    func start() {
        guard loop == nil else { return }
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                await self.load(generation: gen)
                do { try await sleep(Self.interval) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    func refresh() async { await load(generation: generation) }

    private func load(generation gen: Int) async {
        loadSeq += 1
        let mine = loadSeq
        do {
            var list = try await api.list(profile: bot)
            list = await pauseLegacy(list)
            guard gen == generation, mine > appliedLoad else { return }
            appliedLoad = mine
            all = list.jobs
            scoped = list.scoped
            jobs = Routines.jobs(for: bot, in: list)
            // A wanted state the server now reports is no longer pending.
            pendingActive = pendingActive.filter { id, wanted in
                guard let j = jobs.first(where: { $0.id == id }) else { return false }
                return Routines.isActive(j) != wanted
            }
            phase = .ready
            refreshError = nil
        } catch {
            guard gen == generation, mine > appliedLoad else { return }
            let text = Redaction.describe(error)
            if phase == .ready { refreshError = text } else { phase = .failed(text) }
        }
    }

    /// Pauses every active legacy delegated job (`loadRoutines`); only the jobs the gateway actually paused
    /// are shown paused, and a failed pause is retried by the next load.
    private func pauseLegacy(_ list: RoutineList) async -> RoutineList {
        let legacy = list.jobs.filter { Routines.isLegacyDelegated($0) && $0.enabled && $0.state != "paused" }
        guard !legacy.isEmpty else { return list }
        var paused: Set<String> = []
        for job in legacy {
            if (try? await api.perform(.pause, jobId: job.id, profile: bot)) != nil { paused.insert(job.id) }
        }
        return RoutineList(jobs: list.jobs.map { paused.contains($0.id) ? $0.markedPaused() : $0 }, scoped: list.scoped)
    }

    // MARK: actions

    /// Pause (`active: false`) or resume. Shows at once; rolled back with an error when refused.
    @discardableResult
    func setActive(_ job: RoutineJob, _ active: Bool) async -> Bool {
        guard !busy.contains(job.id), !Routines.isLegacyDelegated(job) else { return false }
        pendingActive[job.id] = active
        let ok = await act(job, active ? .resume : .pause, what: active ? "Resume" : "Pause")
        if !ok { pendingActive[job.id] = nil }
        return ok
    }

    /// Deletes the routine (the view asks first).
    @discardableResult
    func remove(_ job: RoutineJob) async -> Bool {
        guard !busy.contains(job.id) else { return false }
        let ok = await act(job, .remove, what: "Delete")
        if ok { notice = "Deleted “\(Routines.title(job.name))”." }
        return ok
    }

    private func act(_ job: RoutineJob, _ action: RoutinesAPI.Action, what: String) async -> Bool {
        busy.insert(job.id)
        defer { busy.remove(job.id) }
        actionError = nil; notice = nil
        do {
            try await api.perform(action, jobId: job.id, profile: bot)
            await refresh()
            return true
        } catch {
            actionError = "\(what) “\(Routines.title(job.name))” failed: \(Redaction.describe(error))"
            return false
        }
    }

    /// Why the form cannot be sent yet, or nil.
    static func blocker(_ d: Draft) -> String? {
        if let e = Routines.inputError(title: d.title, instruction: d.instruction) { return e }
        if d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the routine a name." }
        if d.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what the bot should do." }
        if d.schedule.composed.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a schedule." }
        return nil
    }

    /// The `add` request for a draft (Desktop's payload: `RoutineCreateRequest.params`).
    func request(_ d: Draft) -> RoutineCreateRequest {
        RoutineCreateRequest(bot: bot, title: d.title, instruction: d.instruction, schedule: d.schedule.composed,
                             repeatCount: d.schedule.repeatCount, continuity: d.continuity,
                             deliverToBotChat: d.deliverToBotChat, activeProfile: activeProfile)
    }

    /// Creates the routine. Returns an error text (the form stays open), or nil on success.
    func create(_ d: Draft) async -> String? {
        if let blocker = Self.blocker(d) { return blocker }
        do {
            try await api.add(request(d))
        } catch {
            return Redaction.describe(error)
        }
        notice = "Routine created: \(d.title.trimmingCharacters(in: .whitespacesAndNewlines))"
        actionError = nil
        await refresh()
        return nil
    }
}
