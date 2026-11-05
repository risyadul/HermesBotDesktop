import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A15 presentation: the schedule picker's composed strings and read-backs (Desktop `composeSchedule` /
/// `scheduleSummary`), schedule labels, last result, delivery, timestamps, overdue, detail rows, the issue
/// line and the background hint. Pure, headless.
final class RoutinePresentationTests: XCTestCase {
    private func schedule(_ f: RoutineSchedule.Frequency, _ edit: (inout RoutineSchedule) -> Void = { _ in }) -> RoutineSchedule {
        var s = RoutineSchedule()
        s.frequency = f
        edit(&s)
        return s
    }

    func testComposedScheduleForEveryFrequency() {
        XCTAssertEqual(schedule(.once).composed, "30m", "defaults: 30 minutes from now")
        XCTAssertEqual(schedule(.once) { $0.onceN = "2"; $0.onceUnit = .d }.composed, "2d")
        XCTAssertEqual(schedule(.once) { $0.onceN = "" }.composed, "1m", "a blank count is 1")
        XCTAssertEqual(schedule(.once) { $0.onceN = "0" }.composed, "1m", "never zero")
        XCTAssertEqual(schedule(.hourly).composed, "every 1h")
        XCTAssertEqual(schedule(.daily).composed, "0 9 * * *")
        XCTAssertEqual(schedule(.daily) { $0.time = "17:30" }.composed, "30 17 * * *")
        XCTAssertEqual(schedule(.weekdays) { $0.time = "8:0" }.composed, "0 8 * * 1-5")
        XCTAssertEqual(schedule(.weekly) { $0.weekday = "0" }.composed, "0 9 * * 0")
        XCTAssertEqual(schedule(.monthly) { $0.monthday = "15" }.composed, "0 9 15 * *")
        XCTAssertEqual(schedule(.monthly) { $0.monthday = "" }.composed, "0 9 1 * *")
        XCTAssertEqual(schedule(.interval).composed, "every 2h")
        XCTAssertEqual(schedule(.interval) { $0.intervalN = "45"; $0.intervalUnit = .m }.composed, "every 45m")
        XCTAssertEqual(schedule(.advanced) { $0.raw = "0 */4 * * *" }.composed, "0 */4 * * *")
        XCTAssertEqual(schedule(.advanced).composed, "")
    }

    func testStopAfterIsOnlyForRepeatingSchedules() {
        XCTAssertNil(schedule(.daily).repeatCount, "blank = forever")
        XCTAssertEqual(schedule(.daily) { $0.repeatN = "3" }.repeatCount, 3)
        XCTAssertEqual(schedule(.interval) { $0.repeatN = "0" }.repeatCount, 1)
        XCTAssertNil(schedule(.once) { $0.repeatN = "3" }.repeatCount)
        XCTAssertNil(schedule(.advanced) { $0.repeatN = "3" }.repeatCount)
        XCTAssertFalse(schedule(.once).offersRepeat)
        XCTAssertTrue(schedule(.hourly).offersRepeat)
    }

    func testSummaryReadsTheStateBack() {
        XCTAssertEqual(schedule(.once).summary(timeLabel: "9:00 AM"), "Runs once, 30 minute(s) from now")
        XCTAssertEqual(schedule(.hourly) { $0.repeatN = "4" }.summary(timeLabel: "x"), "Runs at the top of every hour, 4 time(s) total")
        XCTAssertEqual(schedule(.daily).summary(timeLabel: "9:00 AM"), "Runs every day at 9:00 AM")
        XCTAssertEqual(schedule(.weekdays).summary(timeLabel: "9:00 AM"), "Runs Monday–Friday at 9:00 AM")
        XCTAssertEqual(schedule(.weekly) { $0.weekday = "3" }.summary(timeLabel: "9:00 AM"), "Runs every Wednesday at 9:00 AM")
        XCTAssertEqual(schedule(.monthly) { $0.monthday = "2" }.summary(timeLabel: "9:00 AM"), "Runs on day 2 of each month at 9:00 AM")
        XCTAssertEqual(schedule(.interval).summary(timeLabel: "x"), "Runs every 2 hour(s)")
        XCTAssertEqual(schedule(.advanced).summary(timeLabel: "x"), "Raw schedule — every Nm/Nh/Nd or 5-field cron")
    }

    func testPickerDetailsAndInputFilter() {
        XCTAssertEqual(RoutineSchedule.times.count, 48)
        XCTAssertEqual(RoutineSchedule.times.first?.id, "0:0")
        XCTAssertEqual(RoutineSchedule.times.last?.id, "23:30")
        XCTAssertEqual(RoutineSchedule.weekdays.map(\.id), ["1", "2", "3", "4", "5", "6", "0"])
        XCTAssertTrue(schedule(.monthly).needsTime)
        XCTAssertFalse(schedule(.interval).needsTime)
        XCTAssertEqual(RoutineSchedule.digits("1a2-3 456", max: 4), "1234")
        XCTAssertEqual(RoutineSchedule.digits("٣3", max: 4), "3", "ASCII digits only")
        XCTAssertEqual(RoutineSchedule.timeLabel("17:30", locale: Locale(identifier: "en_GB")), "17:30")
    }

    func testScheduleLabel() {
        XCTAssertEqual(RoutineText.scheduleLabel("once in 30m"), "Once (30m)")
        XCTAssertEqual(RoutineText.scheduleLabel("2h"), "Once (2h)")
        XCTAssertEqual(RoutineText.scheduleLabel("every 1440m"), "Daily")
        XCTAssertEqual(RoutineText.scheduleLabel("every 2880m"), "Every 2 days")
        XCTAssertEqual(RoutineText.scheduleLabel("every 60m"), "Hourly")
        XCTAssertEqual(RoutineText.scheduleLabel("every 120m"), "Every 2h")
        XCTAssertEqual(RoutineText.scheduleLabel("every 45m"), "Every 45m")
        XCTAssertEqual(RoutineText.scheduleLabel("0 9 * * *"), "0 9 * * *")
    }

    func testLastResultAndDelivery() {
        XCTAssertEqual(RoutineText.lastResult("ok"), "Succeeded")
        XCTAssertEqual(RoutineText.lastResult("error"), "Failed")
        XCTAssertEqual(RoutineText.lastResult("delivery_failed"), "Ran, but delivery failed")
        XCTAssertEqual(RoutineText.lastResult("blocked_config"), "Blocked by configuration (not run)")
        XCTAssertEqual(RoutineText.lastResult("weird"), "weird", "unknown passes through")
        XCTAssertNil(RoutineText.lastResult(" "))
        XCTAssertEqual(RoutineText.deliverLabel("bot-chat"), "Bot Chat (the bot answers)")
        XCTAssertEqual(RoutineText.deliverLabel("bot-chat:alice"), "Bot Chat (the bot answers)")
        XCTAssertEqual(RoutineText.deliverLabel("local"), "Run history only")
        XCTAssertEqual(RoutineText.deliverLabel("telegram"), "telegram")
        XCTAssertNil(RoutineText.deliverLabel(nil))
    }

    func testTimestampsParsePythonIsoformat() throws {
        let utc = try XCTUnwrap(RoutineText.date("2026-11-06T09:00:00+00:00"))
        XCTAssertEqual(RoutineText.date("2026-11-06T16:00:00.123456+07:00"), utc, "microseconds and offset")
        XCTAssertEqual(RoutineText.date("2026-11-06T09:00:00Z"), utc)
        XCTAssertEqual(RoutineText.date("2026-11-06T09:00:00"), utc, "no zone reads as UTC")
        XCTAssertNil(RoutineText.date("soon"))
        XCTAssertNil(RoutineText.date(nil))
        XCTAssertEqual(RoutineText.relative(utc, now: utc.addingTimeInterval(-300)), "in 5m")
        XCTAssertEqual(RoutineText.relative(utc, now: utc.addingTimeInterval(3 * 3600)), "3h ago")
        XCTAssertEqual(RoutineText.relative(utc, now: utc.addingTimeInterval(20)), "now")
        XCTAssertTrue(RoutineText.timestamp("2026-11-06T09:00:00Z", now: utc)?.hasPrefix("now · ") ?? false)
    }

    private func job(_ extra: [String: JSONValue]) -> RoutineJob {
        var o: [String: JSONValue] = ["job_id": "j", "name": "[bot:alice] Brief", "schedule": "every 60m", "enabled": true,
                                      "state": "scheduled", "repeat": "forever", "deliver": "bot-chat"]
        for (k, v) in extra { o[k] = v }
        return RoutineJob(json: .object(o))!
    }

    func testOverdueOnlyPastTheGraceAndOnlyWhenItShouldFire() throws {
        let now = try XCTUnwrap(RoutineText.date("2026-11-06T10:00:00Z"))
        XCTAssertFalse(RoutineText.isOverdue(job(["next_run_at": "2026-11-06T09:50:00Z"]), now: now), "within 15 min grace")
        XCTAssertTrue(RoutineText.isOverdue(job(["next_run_at": "2026-11-06T09:40:00Z"]), now: now))
        XCTAssertFalse(RoutineText.isOverdue(job(["next_run_at": "2026-11-06T09:40:00Z", "state": "paused"]), now: now))
        XCTAssertFalse(RoutineText.isOverdue(job(["next_run_at": "2026-11-06T09:40:00Z", "state": .null, "enabled": false]), now: now),
                       "disabled")
        XCTAssertEqual(RoutineText.nextLine(job(["next_run_at": "2026-11-06T09:40:00Z"]), active: true, now: now), "Overdue since 20m ago")
        XCTAssertEqual(RoutineText.nextLine(job(["next_run_at": "2026-11-06T11:00:00Z"]), active: true, now: now), "Next in 1h")
        XCTAssertEqual(RoutineText.nextLine(job(["next_run_at": "2026-11-06T11:00:00Z"]), active: false, now: now), "paused")
        XCTAssertEqual(RoutineText.nextLine(job([:]), active: true, now: now), "no next run")
    }

    func testDetailRowsShowOnlyWhatTheServerSent() throws {
        let now = try XCTUnwrap(RoutineText.date("2026-11-06T10:00:00Z"))
        let rows = RoutineText.detailRows(job(["next_run_at": "2026-11-06T11:00:00Z", "last_status": "ok", "continuity": true]),
                                          active: true, now: now)
        XCTAssertEqual(rows.map(\.label), ["Status", "Schedule", "Schedule (raw)", "Repeat", "Next run", "Last result",
                                           "Send results to", "Continuity"])
        XCTAssertEqual(rows[0].value, "Active")
        XCTAssertEqual(rows[1].value, "Hourly")
        XCTAssertEqual(rows[2].value, "every 60m")
        XCTAssertEqual(rows.first { $0.label == "Last result" }?.value, "Succeeded")
        let paused = RoutineText.detailRows(job(["next_run_at": "2026-11-06T11:00:00Z", "schedule": "0 9 * * *"]), active: false, now: now)
        XCTAssertEqual(paused.map(\.label), ["Status", "Schedule", "Repeat", "Send results to"],
                       "no next run while paused; no raw row when the label is the raw string")
        XCTAssertEqual(paused[0].value, "Paused")
    }

    func testIssueTakesTheFirstReason() {
        XCTAssertNil(RoutineText.issue(job([:])))
        XCTAssertEqual(RoutineText.issue(job(["last_error": "boom", "paused_reason": "paused by user"])), "paused by user")
        XCTAssertEqual(RoutineText.issue(job(["last_fire_error": " fire ", "last_delivery_error": "deliver"])), "fire")
        XCTAssertEqual(RoutineText.issue(job(["last_error": "boom"])), "boom")
    }

    func testBackgroundHintOnlyWhenTheAppOwnsTheBackend() {
        XCTAssertNotNil(RoutineText.backgroundHint(ownsBackend: true))
        XCTAssertTrue(RoutineText.backgroundHint(ownsBackend: true)!.contains("Keep Hermes running in the background"))
        XCTAssertNil(RoutineText.backgroundHint(ownsBackend: false), "attached (e.g. background Hermes): routines keep running")
    }
}
