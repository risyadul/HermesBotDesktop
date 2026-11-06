import Foundation

// Routines (roadmap A15): a bot's Hermes cron jobs over `cron.manage` (`tui_gateway/methods_tools.py`,
// contract `tui_gateway/contracts/tools_commands.py` `CronManageParams` / `CronJobRow`). The rules and the
// exact request payloads follow Hermes Desktop's Routines pane (`apps/desktop/src/plugins/hermes-bots/cron.tsx`):
// jobs are named `[bot:<name>] <title>`, every call carries `profile` so the gateway uses that bot's own cron
// store, and a gateway that does not prove the scope (`scoped` missing from the list reply) falls back to the
// `[bot:<name>]` name filter. The scheduler that fires the jobs runs inside `hermes serve` (it ticks every
// local profile's store, `hermes_cli/web_server.py` `_start_desktop_cron_ticker`).

/// One job as `cron.manage {action: "list"}` returns it (`tools/cronjob_job_args.py` `_format_job`).
/// Lenient: only `job_id` is required.
public struct RoutineJob: Sendable, Equatable, Identifiable {
    public let id: String
    /// The full stored name, `[bot:<name>] <title>` for routines made by Hermes Desktop or this app.
    public let name: String
    /// The first 100 characters of the prompt (the gateway adds "..." when it is longer).
    public let promptPreview: String
    /// The schedule as Hermes displays it (`schedule_display`: "every 60m", "0 9 * * 1-5", "once in 30m").
    public let schedule: String
    /// "forever", "once", "3 times", "1/3" (`_repeat_display`).
    public let repeatText: String?
    public let deliver: String?
    public let nextRunAt: String?
    public let lastRunAt: String?
    public let lastStatus: String?
    public let lastError: String?
    public let lastFireError: String?
    public let lastDeliveryError: String?
    public let enabled: Bool
    public let state: String?
    public let pausedReason: String?
    public let model: String?
    public let workdir: String?
    public let continuity: Bool

    public init?(json j: JSONValue) {
        guard let id = j["job_id"]?.nonEmptyString else { return nil }
        self.id = id
        name = j["name"]?.string ?? ""
        promptPreview = j["prompt_preview"]?.string ?? j["prompt"]?.string ?? ""
        schedule = j["schedule"]?.string ?? ""
        repeatText = j["repeat"].flatMap { v in v.nonEmptyString ?? v.intValue.map(String.init) }
        deliver = j["deliver"]?.nonEmptyString
        nextRunAt = j["next_run_at"]?.nonEmptyString
        lastRunAt = j["last_run_at"]?.nonEmptyString
        lastStatus = j["last_status"]?.nonEmptyString
        lastError = j["last_error"]?.nonEmptyString
        lastFireError = j["last_fire_error"]?.nonEmptyString
        lastDeliveryError = j["last_delivery_error"]?.nonEmptyString
        enabled = j["enabled"]?.bool ?? true
        state = j["state"]?.nonEmptyString
        pausedReason = j["paused_reason"]?.nonEmptyString
        model = j["model"]?.nonEmptyString
        workdir = j["workdir"]?.nonEmptyString
        continuity = j["continuity"]?.bool ?? false
        raw = j
    }

    /// The row as received (forward-compatible access to unmodelled fields).
    public let raw: JSONValue

    /// A copy marked paused (the legacy-job overlay after the app paused it, as Desktop's `loadRoutines`).
    public func markedPaused() -> RoutineJob {
        guard case .object(var o) = raw else { return self }
        o["enabled"] = .bool(false)
        o["state"] = .string("paused")
        return RoutineJob(json: .object(o)) ?? self
    }
}

/// `cron.manage {action: "list"}`: the jobs, and `scoped` = the profile the gateway scoped the store to
/// (older gateways ignore `profile` and omit it).
public struct RoutineList: Sendable, Equatable {
    public let jobs: [RoutineJob]
    public let scoped: String?

    public init(jobs: [RoutineJob], scoped: String?) {
        self.jobs = jobs; self.scoped = scoped
    }

    public init(json j: JSONValue) {
        jobs = (j["jobs"]?.array ?? []).compactMap(RoutineJob.init(json:))
        scoped = j["scoped"]?.nonEmptyString
    }
}

/// A new routine as the create form fills it. `params` is exactly what Desktop's `CreateRoutineDialog` sends.
public struct RoutineCreateRequest: Sendable, Equatable {
    public var bot: String
    public var title: String
    public var instruction: String
    /// A Hermes schedule string (`RoutineSchedule.compose`).
    public var schedule: String
    /// "Stop after N runs"; nil = forever (never sent for once / advanced).
    public var repeatCount: Int?
    public var continuity: Bool
    /// True: `deliver: "bot-chat"` (the result is posted into the bot's Bot Chat and the bot answers it);
    /// false: the run's own history only (nothing sent, the gateway's default).
    public var deliverToBotChat: Bool
    /// The profile whose store and runtime run the job (`Routines.promptProfile`): the bot itself unless the
    /// gateway could not prove the profile scope.
    public var activeProfile: String

    public init(bot: String, title: String, instruction: String, schedule: String, repeatCount: Int? = nil,
                continuity: Bool = false, deliverToBotChat: Bool = false, activeProfile: String) {
        self.bot = bot; self.title = title; self.instruction = instruction; self.schedule = schedule
        self.repeatCount = repeatCount; self.continuity = continuity; self.deliverToBotChat = deliverToBotChat
        self.activeProfile = activeProfile
    }

    /// `cron.manage {action: "add", name, schedule, prompt, profile?, repeat?, continuity?, deliver?}`.
    public var params: JSONValue {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = self.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var o: [String: JSONValue] = [
            "action": "add",
            "name": .string("[bot:\(bot)] \(title)"),
            "schedule": .string(schedule.trimmingCharacters(in: .whitespacesAndNewlines)),
            "prompt": .string(Routines.prompt(bot: bot, title: title, instruction: instruction, activeProfile: activeProfile)),
        ]
        if !bot.isEmpty { o["profile"] = .string(bot) }
        if let repeatCount { o["repeat"] = .number(Double(max(1, repeatCount))) }
        if continuity { o["continuity"] = .bool(true) }
        if deliverToBotChat { o["deliver"] = "bot-chat" }
        return .object(o)
    }
}

/// Pure routine rules shared by the model and the views (Desktop `cron.tsx`).
public enum Routines {
    public static let untitled = "Untitled job"
    /// Marks a delegated prompt this app (and Desktop) writes today.
    public static let safeMarker = "[bot-mode:routine:v2] "
    /// The prompt opening of the old delegated routines Desktop pauses for security.
    public static let legacyDelegatedPrefix = "You are running the scheduled routine \""
    /// The profile a gateway that ignores `profile` runs jobs in (the launch profile of `hermes serve`).
    public static let launchProfile = "default"

    /// `[bot:<name>]` at the start of a job name (case-insensitive, as Desktop's `BOT_TAG_RE`).
    static let botTag = try! NSRegularExpression(pattern: #"^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*"#, options: [.caseInsensitive])

    private static func tagMatch(_ name: String) -> NSTextCheckingResult? {
        botTag.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
    }

    /// The bot a job is tagged for, lowercased; nil when the name carries no tag.
    public static func taggedBot(_ name: String) -> String? {
        guard let m = tagMatch(name), let r = Range(m.range(at: 1), in: name) else { return nil }
        return name[r].lowercased()
    }

    /// The job name without its `[bot:<name>]` tag ("Untitled job" when nothing is left).
    public static func title(_ name: String) -> String {
        var out = name
        if let m = tagMatch(name), let r = Range(m.range, in: name) { out.removeSubrange(r) }
        return out.isEmpty ? untitled : out
    }

    /// A tagged job whose prompt still starts with the old delegation text (`isLegacyDelegatedRoutine`).
    public static func isLegacyDelegated(_ job: RoutineJob) -> Bool {
        taggedBot(job.name) != nil && job.promptPreview.hasPrefix(legacyDelegatedPrefix)
    }

    /// Active = runs on schedule: not a legacy job, not disabled, not paused (Desktop's row switch).
    public static func isActive(_ job: RoutineJob) -> Bool {
        !isLegacyDelegated(job) && job.enabled && job.state != "paused"
    }

    public static func normalizedProfile(_ profile: String?) -> String {
        profile?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// The profile a new routine runs in: the bot when the gateway proved it scopes `cron.manage` to the bot
    /// (the job then lives in the bot's own store and runs as the bot), else the launch profile.
    public static func promptProfile(scoped: String?, bot: String, launchProfile: String = Routines.launchProfile) -> String {
        normalizedProfile(scoped) == normalizedProfile(bot) && !normalizedProfile(bot).isEmpty ? bot : launchProfile
    }

    /// Single-quoted for a POSIX shell (`shellQuote`).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The prompt sent with `add` (`routinePrompt`): the plain instruction when the job runs in the bot's own
    /// profile, else the v2 delegation that runs it as the bot so the run lands in its history.
    public static func prompt(bot: String, title: String, instruction: String, activeProfile: String) -> String {
        if !normalizedProfile(bot).isEmpty, normalizedProfile(bot) == normalizedProfile(activeProfile) { return instruction }
        return "\(safeMarker)You are running the scheduled routine \"\(title)\" for agent '\(bot)'. "
            + "Execute it AS that agent so the run lands in its own history: run this in the terminal and relay the output:\n\n"
            + "hermes -p \(shellQuote(bot)) chat -c \(shellQuote("Routine: \(title)")) -q \(shellQuote("[Scheduled routine] \(instruction)"))\n\n"
            + "If the command fails, report the error instead."
    }

    /// NUL in a name or instruction is refused before sending (`routineInputError`).
    public static func inputError(title: String, instruction: String) -> String? {
        if title.contains("\0") { return "Job name cannot contain NUL (U+0000)." }
        if instruction.contains("\0") { return "Job instruction cannot contain NUL (U+0000)." }
        return nil
    }

    /// The jobs to show for `bot` (`selectRoutineJobs`): every job when the list was proven scoped to the bot,
    /// else only the jobs tagged for it (untagged jobs count as `default`'s).
    public static func jobs(for bot: String, in list: RoutineList) -> [RoutineJob] {
        let wanted = normalizedProfile(bot)
        if !wanted.isEmpty, normalizedProfile(list.scoped) == wanted { return list.jobs }
        return list.jobs.filter { (taggedBot($0.name) ?? "default") == wanted }
    }

    /// Why the list can be empty while the store has jobs (`routineFilterHint`), or nil.
    public static func filterHint(all: [RoutineJob], shown: [RoutineJob]) -> String? {
        guard shown.isEmpty, !all.isEmpty else { return nil }
        return "Scheduled jobs exist in this profile but none are tagged for this bot. Name a job \"[bot:<name>] …\" to show it here."
    }
}

/// `cron.manage` calls. `call` is the gateway RPC (`GatewayClient.call` in the app, a fake in tests).
public struct RoutinesAPI: Sendable {
    public typealias Call = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public static let method = "cron.manage"

    public enum Action: String, Sendable { case pause, resume, remove }

    /// The tool-level failure `cron.manage` returns inside a successful RPC reply (`{success: false, error}`).
    public struct Failure: Error, Equatable, RedactionSafeError {
        public let message: String
        public var description: String { message }
    }

    let call: Call

    public init(call: @escaping Call) { self.call = call }

    /// `{action: "list", include_disabled: true, profile}` (paused jobs are left out unless asked for).
    public func list(profile: String) async throws -> RoutineList {
        RoutineList(json: try await send(Self.listParams(profile: profile)))
    }

    /// `{action, name: <job_id>, profile}` for pause / resume / remove.
    public func perform(_ action: Action, jobId: String, profile: String) async throws {
        _ = try await send(Self.actionParams(action, jobId: jobId, profile: profile))
    }

    public func add(_ request: RoutineCreateRequest) async throws {
        _ = try await send(request.params)
    }

    static func listParams(profile: String) -> JSONValue {
        var o: [String: JSONValue] = ["action": "list", "include_disabled": true]
        if !profile.isEmpty { o["profile"] = .string(profile) }
        return .object(o)
    }

    static func actionParams(_ action: Action, jobId: String, profile: String) -> JSONValue {
        var o: [String: JSONValue] = ["action": .string(action.rawValue), "name": .string(jobId)]
        if !profile.isEmpty { o["profile"] = .string(profile) }
        return .object(o)
    }

    private func send(_ params: JSONValue) async throws -> JSONValue {
        let reply = try await call(Self.method, params)
        if reply["success"]?.bool == false {
            throw Failure(message: reply["error"]?.nonEmptyString ?? "cron.manage failed")
        }
        return reply
    }
}
