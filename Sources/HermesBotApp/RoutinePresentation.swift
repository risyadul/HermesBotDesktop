import Foundation
import HermesGatewayKit

// Routines (roadmap A15), presentation rules: the schedule picker and the words a routine shows, mirroring
// Hermes Desktop's Routines pane (`apps/desktop/src/plugins/hermes-bots/cron.tsx`: `composeSchedule`,
// `scheduleSummary`, `scheduleLabel`, `routineDetailRows`, `routineDetailIssue`, `routineLastResult`) and
// its English strings. Pure, so every rule is tested without a window.

/// The create form's schedule picker: frequency first, then only the detail that frequency needs. Detail
/// fields stay text (typed digits) and are coerced only when the schedule string is composed, as Desktop's.
struct RoutineSchedule: Equatable {
    enum Frequency: String, CaseIterable, Identifiable {
        case once, hourly, daily, weekdays, weekly, monthly, interval, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .once: return "Once, in…"
            case .hourly: return "Every hour"
            case .daily: return "Every day"
            case .weekdays: return "Weekdays"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            case .interval: return "Interval"
            case .advanced: return "Advanced…"
            }
        }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case m, h, d
        var id: String { rawValue }
        var word: String {
            switch self {
            case .m: return "minute(s)"
            case .h: return "hour(s)"
            case .d: return "day(s)"
            }
        }
        var fromNow: String {
            switch self {
            case .m: return "minutes from now"
            case .h: return "hours from now"
            case .d: return "days from now"
            }
        }
    }

    var frequency = Frequency.daily
    /// "H:M" (Desktop's time ids: every half hour, "9:0" = 9:00).
    var time = "9:0"
    /// Cron day number: "1" Monday … "6" Saturday, "0" Sunday.
    var weekday = "1"
    var monthday = "1"
    var intervalN = "2"
    var intervalUnit = Unit.h
    var onceN = "30"
    var onceUnit = Unit.m
    /// "Stop after N runs"; blank = forever.
    var repeatN = ""
    /// Advanced: the raw schedule string.
    var raw = ""

    /// The picker's half-hour slots (Desktop's `TIMES`).
    static let times: [(id: String, hour: Int, minute: Int)] = (0..<24).flatMap { h in [0, 30].map { ("\(h):\($0)", h, $0) } }
    /// Weekdays in menu order, Monday first.
    static let weekdays: [(id: String, label: String)] = [
        ("1", "Monday"), ("2", "Tuesday"), ("3", "Wednesday"), ("4", "Thursday"), ("5", "Friday"), ("6", "Saturday"), ("0", "Sunday"),
    ]

    /// Digits only, at most `max` of them (the fields' input filter).
    static func digits(_ text: String, max: Int) -> String { String(text.filter { ("0"..."9").contains($0) }.prefix(max)) }

    private static func count(_ text: String) -> Int { Swift.max(1, Int(text) ?? 1) }

    var needsTime: Bool { [.daily, .weekdays, .weekly, .monthly].contains(frequency) }
    /// "Stop after N runs" is offered for repeating schedules only.
    var offersRepeat: Bool { frequency != .once && frequency != .advanced }

    private var hourMinute: (Int, Int) {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (9, 0)
    }

    /// The Hermes schedule string (`composeSchedule`).
    var composed: String {
        let (h, m) = hourMinute
        switch frequency {
        case .once: return "\(Self.count(onceN))\(onceUnit.rawValue)"
        case .hourly: return "every 1h"
        case .daily: return "\(m) \(h) * * *"
        case .weekdays: return "\(m) \(h) * * 1-5"
        case .weekly: return "\(m) \(h) * * \(weekday.isEmpty ? "1" : weekday)"
        case .monthly: return "\(m) \(h) \(monthday.isEmpty ? "1" : monthday) * *"
        case .interval: return "every \(Self.count(intervalN))\(intervalUnit.rawValue)"
        case .advanced: return raw
        }
    }

    /// The `repeat` sent with `add`: nil for once / advanced or a blank field, else at least 1.
    var repeatCount: Int? {
        guard offersRepeat, !repeatN.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Self.count(repeatN)
    }

    /// One plain sentence for the picker's state (`scheduleSummary`); `timeLabel` is the chosen time as shown.
    func summary(timeLabel: String) -> String {
        let cap = repeatCount.map { ", \($0) time(s) total" } ?? ""
        switch frequency {
        case .once: return "Runs once, \(Self.count(onceN)) \(onceUnit.word) from now"
        case .hourly: return "Runs at the top of every hour" + cap
        case .daily: return "Runs every day at \(timeLabel)" + cap
        case .weekdays: return "Runs Monday–Friday at \(timeLabel)" + cap
        case .weekly:
            let day = Self.weekdays.first { $0.id == weekday }?.label ?? Self.weekdays[0].label
            return "Runs every \(day) at \(timeLabel)" + cap
        case .monthly: return "Runs on day \(monthday.isEmpty ? "1" : monthday) of each month at \(timeLabel)" + cap
        case .interval: return "Runs every \(Self.count(intervalN)) \(intervalUnit.word)" + cap
        case .advanced: return "Raw schedule — every Nm/Nh/Nd or 5-field cron"
        }
    }

    /// A slot's label in the user's clock style (9:00 AM / 09:00).
    static func timeLabel(_ id: String, locale: Locale = .current) -> String {
        let parts = id.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        c.year = 2000; c.month = 1; c.day = 1
        c.hour = parts.count == 2 ? parts[0] : 9
        c.minute = parts.count == 2 ? parts[1] : 0
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return Calendar(identifier: .gregorian).date(from: c).map(f.string(from:)) ?? id
    }
}

/// The words a routine shows.
enum RoutineText {
    /// Mirrors `hermes_cli/cron.py` `_OVERDUE_GRACE_SECONDS` (Desktop's `NEXT_RUN_OVERDUE_GRACE_MS`).
    static let overdueGrace: TimeInterval = 15 * 60

    /// Hermes' schedule string in words (`scheduleLabel`): "Once (30m)", "Daily", "Every 2h", or as is.
    static func scheduleLabel(_ schedule: String) -> String {
        if let m = schedule.wholeMatch(of: /once in (.+)/) { return "Once (\(m.1))" }
        if let m = schedule.wholeMatch(of: /(\d+)([mhd])/) { return "Once (\(m.1)\(m.2))" }
        if let m = schedule.wholeMatch(of: /every (\d+)m/), let minutes = Int(m.1) {
            if minutes > 0, minutes % 1440 == 0 { return minutes == 1440 ? "Daily" : "Every \(minutes / 1440) days" }
            if minutes > 0, minutes % 60 == 0 { return minutes == 60 ? "Hourly" : "Every \(minutes / 60)h" }
            return "Every \(minutes)m"
        }
        return schedule
    }

    /// The scheduler's `last_status` spelled out (`routineLastResult`); an unknown one passes through.
    static func lastResult(_ status: String?) -> String? {
        guard let raw = status?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw {
        case "ok": return "Succeeded"
        case "error": return "Failed"
        case "delivery_failed": return "Ran, but delivery failed"
        case "blocked_config": return "Blocked by configuration (not run)"
        default: return raw
        }
    }

    /// Where results go: Bot Chat for `bot-chat[:name]`, the run history for `local`, else Hermes' own target.
    static func deliverLabel(_ deliver: String?) -> String? {
        guard let d = deliver?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if d == "bot-chat" || d.hasPrefix("bot-chat:") { return "Bot Chat (the bot answers)" }
        if d == "local" { return "Run history only" }
        return d
    }

    /// Python `isoformat()` timestamps ("2026-11-06T09:00:00.123456+07:00", "…Z", or without a zone = UTC).
    static func date(_ iso: String?) -> Date? {
        guard var s = iso?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacing(/\.\d+/, with: "", maxReplacements: 1)
        if s.wholeMatch(of: /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/) != nil { s += "Z" }
        s = s.replacingOccurrences(of: " ", with: "T")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// "in 5m", "3h ago", "now".
    static func relative(_ date: Date, now: Date) -> String {
        let delta = Int(date.timeIntervalSince(now).rounded())
        let magnitude = abs(delta)
        guard magnitude >= 60 else { return "now" }
        let text = KanbanAge.short(magnitude)
        return delta > 0 ? "in \(text)" : "\(text) ago"
    }

    /// "in 5m · 6 Nov 2026 at 09:00", or nil when absent or unreadable.
    static func timestamp(_ iso: String?, now: Date) -> String? {
        guard let d = date(iso) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(relative(d, now: now)) · \(f.string(from: d))"
    }

    /// The effective state (`jobState`): explicit state, else from `enabled`.
    static func state(_ job: RoutineJob) -> String { job.state ?? (job.enabled ? "scheduled" : "disabled") }

    /// The stored next run sits past the scheduler's grace: the scheduler did not fire it (`nextRunOverdueMs`).
    static func isOverdue(_ job: RoutineJob, now: Date) -> Bool {
        let s = state(job)
        guard !["paused", "completed", "disabled"].contains(s), let at = date(job.nextRunAt) else { return false }
        return now.timeIntervalSince(at) > overdueGrace
    }

    /// The row's right-hand line: next run (or overdue since), or why there is none.
    static func nextLine(_ job: RoutineJob, active: Bool, now: Date) -> String {
        guard active else { return "paused" }
        guard let at = date(job.nextRunAt) else { return state(job) == "completed" ? "completed" : "no next run" }
        return (isOverdue(job, now: now) ? "Overdue since " : "Next ") + relative(at, now: now)
    }

    struct Row: Equatable { let label: String; let value: String }

    /// The facts the list already carries, as label/value rows (`routineDetailRows`); an absent value drops
    /// its row, so nothing is invented.
    static func detailRows(_ job: RoutineJob, active: Bool, now: Date) -> [Row] {
        let label = scheduleLabel(job.schedule)
        let raw = job.schedule.trimmingCharacters(in: .whitespaces)
        let cells: [(String, String?)] = [
            ("Status", active ? "Active" : "Paused"),
            ("Schedule", label),
            ("Schedule (raw)", !raw.isEmpty && raw != label ? raw : nil),
            ("Repeat", job.repeatText),
            (isOverdue(job, now: now) ? "Overdue since" : "Next run", active ? timestamp(job.nextRunAt, now: now) : nil),
            ("Last run", timestamp(job.lastRunAt, now: now)),
            ("Last result", lastResult(job.lastStatus)),
            ("Send results to", deliverLabel(job.deliver)),
            ("Continuity", job.continuity ? "Each run sees the previous run’s output" : nil),
            ("Model", job.model),
            ("Working directory", job.workdir),
        ]
        return cells.compactMap { name, value in
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return Row(label: name, value: v)
        }
    }

    /// Why a routine is not doing what the user expects (`routineDetailIssue`, plus the run's own error).
    static func issue(_ job: RoutineJob) -> String? {
        [job.lastFireError, job.lastDeliveryError, job.pausedReason, job.lastError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    static let legacyUnsafe = "Paused for security: delete and recreate this legacy job before running it again."

    /// Routines fire from the scheduler inside `hermes serve`. When this app started that backend, it stops
    /// on quit and so do the routines.
    static func backgroundHint(ownsBackend: Bool) -> String? {
        guard ownsBackend else { return nil }
        return "Routines run only while Hermes runs. This app started Hermes and stops it when you quit; turn on "
            + "Settings → Keep Hermes running in the background to keep routines running."
    }
}
