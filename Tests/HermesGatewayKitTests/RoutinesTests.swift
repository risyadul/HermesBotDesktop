import Foundation
import XCTest
@testable import HermesGatewayKit

/// A15 `cron.manage` rules and wire shapes, checked against Hermes Desktop's Routines pane (`cron.tsx`:
/// `[bot:<name>]` naming, `routinePrompt`, the `add` payload, `selectRoutineJobs`) and the gateway contract
/// (`CronManageParams`, `CronJobRow`). The RPC is a recording closure: nothing reaches a real Hermes.
final class RoutinesTests: XCTestCase {
    static func job(_ id: String, name: String, prompt: String = "Do the thing", enabled: Bool = true,
                    state: String? = "scheduled", extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["job_id": .string(id), "name": .string(name), "prompt_preview": .string(prompt),
                                      "schedule": "every 60m", "repeat": "forever", "deliver": "local", "enabled": .bool(enabled)]
        if let state { o["state"] = .string(state) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    // MARK: decoding

    func testJobDecodesTheListRowLeniently() throws {
        let j = try XCTUnwrap(RoutineJob(json: Self.job("j1", name: "[bot:alice] Brief", extra: [
            "next_run_at": "2026-11-06T09:00:00+07:00", "last_status": "delivery_failed", "last_delivery_error": "no chat",
            "paused_reason": "", "model": "m-1", "continuity": true, "brand_new": [1],
        ])))
        XCTAssertEqual(j.id, "j1")
        XCTAssertEqual(j.schedule, "every 60m")
        XCTAssertEqual(j.repeatText, "forever")
        XCTAssertEqual(j.deliver, "local")
        XCTAssertEqual(j.nextRunAt, "2026-11-06T09:00:00+07:00")
        XCTAssertEqual(j.lastStatus, "delivery_failed")
        XCTAssertEqual(j.lastDeliveryError, "no chat")
        XCTAssertNil(j.pausedReason, "empty reads as unset")
        XCTAssertTrue(j.continuity)
        XCTAssertEqual(j.raw["brand_new"], [1])
        XCTAssertNil(RoutineJob(json: ["name": "no id"]))
        XCTAssertEqual(RoutineJob(json: ["job_id": "x", "repeat": 3])?.repeatText, "3")
        let minimal = try XCTUnwrap(RoutineJob(json: ["job_id": "y"]))
        XCTAssertTrue(minimal.enabled, "enabled defaults to true, as the gateway's")
        XCTAssertFalse(minimal.continuity)
    }

    func testListReplyCarriesScoped() {
        let l = RoutineList(json: ["success": true, "count": 1, "jobs": [Self.job("j1", name: "A"), ["no": "id"]], "scoped": "alice"])
        XCTAssertEqual(l.jobs.map(\.id), ["j1"])
        XCTAssertEqual(l.scoped, "alice")
        XCTAssertNil(RoutineList(json: ["jobs": []]).scoped, "older gateways omit it")
    }

    // MARK: naming

    func testBotTagAndTitle() {
        XCTAssertEqual(Routines.taggedBot("[bot:Alice-2] Morning"), "alice-2")
        XCTAssertEqual(Routines.taggedBot("[BOT:bob]Plain"), "bob")
        XCTAssertNil(Routines.taggedBot("Morning [bot:alice]"))
        XCTAssertNil(Routines.taggedBot("[bot:-bad] x"), "a tag starts with a letter or digit")
        XCTAssertEqual(Routines.title("[bot:alice]   Morning"), "Morning")
        XCTAssertEqual(Routines.title("Untagged"), "Untagged")
        XCTAssertEqual(Routines.title("[bot:alice] "), Routines.untitled)
        XCTAssertEqual(Routines.title(""), Routines.untitled)
    }

    func testLegacyDelegatedJobsAreNeverActive() {
        let legacy = RoutineJob(json: Self.job("j", name: "[bot:alice] Old", prompt: "You are running the scheduled routine \"Old\" for …"))!
        XCTAssertTrue(Routines.isLegacyDelegated(legacy))
        XCTAssertFalse(Routines.isActive(legacy))
        let untagged = RoutineJob(json: Self.job("k", name: "Old", prompt: "You are running the scheduled routine \"Old\""))!
        XCTAssertFalse(Routines.isLegacyDelegated(untagged), "only tagged jobs count")
        let v2 = RoutineJob(json: Self.job("v", name: "[bot:alice] New", prompt: Routines.safeMarker + "You are running the scheduled routine"))!
        XCTAssertFalse(Routines.isLegacyDelegated(v2), "today's delegation starts with the safe marker")
        XCTAssertFalse(Routines.isActive(RoutineJob(json: Self.job("p", name: "x", state: "paused"))!))
        XCTAssertFalse(Routines.isActive(RoutineJob(json: Self.job("d", name: "x", enabled: false, state: nil))!))
        XCTAssertTrue(Routines.isActive(RoutineJob(json: Self.job("a", name: "x"))!))
    }

    func testMarkedPausedOverlay() {
        let j = RoutineJob(json: Self.job("j", name: "[bot:a] x"))!.markedPaused()
        XCTAssertFalse(j.enabled)
        XCTAssertEqual(j.state, "paused")
        XCTAssertEqual(j.id, "j")
    }

    // MARK: prompt + payload (exactly Desktop's)

    func testPromptIsThePlainInstructionInTheBotsOwnProfile() {
        XCTAssertEqual(Routines.prompt(bot: "alice", title: "T", instruction: "Summarise", activeProfile: "Alice"), "Summarise")
    }

    func testPromptDelegatesWithQuotedArgumentsElsewhere() {
        let p = Routines.prompt(bot: "alice", title: "Bob's brief", instruction: "Say 'hi'", activeProfile: "default")
        XCTAssertEqual(p, "[bot-mode:routine:v2] You are running the scheduled routine \"Bob's brief\" for agent 'alice'. "
            + "Execute it AS that agent so the run lands in its own history: run this in the terminal and relay the output:\n\n"
            + "hermes -p 'alice' chat -c 'Routine: Bob'\"'\"'s brief' -q '[Scheduled routine] Say '\"'\"'hi'\"'\"''\n\n"
            + "If the command fails, report the error instead.")
        XCTAssertEqual(Routines.shellQuote("a'b"), "'a'\"'\"'b'")
    }

    func testPromptProfileFollowsTheProvenScope() {
        XCTAssertEqual(Routines.promptProfile(scoped: "Alice", bot: "alice"), "alice")
        XCTAssertEqual(Routines.promptProfile(scoped: nil, bot: "alice"), "default")
        XCTAssertEqual(Routines.promptProfile(scoped: "bob", bot: "alice", launchProfile: "home"), "home")
    }

    func testAddPayloadWithEveryOption() {
        let r = RoutineCreateRequest(bot: "alice", title: "  Brief ", instruction: " Summarise \n", schedule: " 0 9 * * 1-5 ",
                                     repeatCount: 5, continuity: true, deliverToBotChat: true, activeProfile: "alice")
        XCTAssertEqual(r.params, ["action": "add", "name": "[bot:alice] Brief", "schedule": "0 9 * * 1-5", "prompt": "Summarise",
                                  "profile": "alice", "repeat": 5, "continuity": true, "deliver": "bot-chat"])
    }

    func testAddPayloadLeavesUnsetOptionsOut() {
        let r = RoutineCreateRequest(bot: "alice", title: "Brief", instruction: "Go", schedule: "30m", activeProfile: "alice")
        XCTAssertEqual(r.params, ["action": "add", "name": "[bot:alice] Brief", "schedule": "30m", "prompt": "Go", "profile": "alice"])
        let delegated = RoutineCreateRequest(bot: "alice", title: "Brief", instruction: "Go", schedule: "30m", activeProfile: "default")
        XCTAssertTrue(delegated.params["prompt"]?.string?.hasPrefix(Routines.safeMarker) ?? false)
    }

    func testInputErrorRefusesNUL() {
        XCTAssertEqual(Routines.inputError(title: "a\0b", instruction: "x"), "Job name cannot contain NUL (U+0000).")
        XCTAssertEqual(Routines.inputError(title: "a", instruction: "x\0"), "Job instruction cannot contain NUL (U+0000).")
        XCTAssertNil(Routines.inputError(title: "a", instruction: "b"))
    }

    // MARK: which jobs show

    func testScopedListShowsEveryJobUnscopedFiltersByTag() {
        let jobs = [Self.job("1", name: "[bot:alice] A"), Self.job("2", name: "[bot:bob] B"), Self.job("3", name: "Untagged")]
            .compactMap(RoutineJob.init(json:))
        XCTAssertEqual(Routines.jobs(for: "alice", in: RoutineList(jobs: jobs, scoped: "alice")).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(Routines.jobs(for: "alice", in: RoutineList(jobs: jobs, scoped: nil)).map(\.id), ["1"])
        XCTAssertEqual(Routines.jobs(for: "default", in: RoutineList(jobs: jobs, scoped: nil)).map(\.id), ["3"],
                       "untagged jobs belong to default")
        XCTAssertEqual(Routines.jobs(for: "alice", in: RoutineList(jobs: jobs, scoped: "bob")).map(\.id), ["1"],
                       "a scope for another profile proves nothing")
    }

    func testFilterHintOnlyWhenJobsExistButNoneShow() {
        let one = [RoutineJob(json: Self.job("1", name: "[bot:bob] B"))!]
        XCTAssertNotNil(Routines.filterHint(all: one, shown: []))
        XCTAssertNil(Routines.filterHint(all: [], shown: []))
        XCTAssertNil(Routines.filterHint(all: one, shown: one))
    }

    // MARK: API

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(String, JSONValue)] = []
        var reply: JSONValue = ["success": true]
        var calls: [(String, JSONValue)] { lock.withLock { _calls } }
        func record(_ m: String, _ p: JSONValue) -> JSONValue { lock.withLock { _calls.append((m, p)); return reply } }
    }

    func testCallsCarryTheProfileAndDesktopsParams() async throws {
        let rec = Recorder()
        rec.reply = ["success": true, "jobs": [Self.job("1", name: "[bot:alice] A")], "scoped": "alice"]
        let api = RoutinesAPI { m, p in rec.record(m, p) }
        let list = try await api.list(profile: "alice")
        XCTAssertEqual(list.jobs.count, 1)
        try await api.perform(.pause, jobId: "1", profile: "alice")
        try await api.perform(.resume, jobId: "1", profile: "alice")
        try await api.perform(.remove, jobId: "1", profile: "alice")
        XCTAssertEqual(rec.calls.map(\.0), Array(repeating: "cron.manage", count: 4))
        XCTAssertEqual(rec.calls.map(\.1), [
            ["action": "list", "include_disabled": true, "profile": "alice"],
            ["action": "pause", "name": "1", "profile": "alice"],
            ["action": "resume", "name": "1", "profile": "alice"],
            ["action": "remove", "name": "1", "profile": "alice"],
        ])
    }

    func testToolLevelFailureThrowsWithTheGatewaysWords() async {
        let api = RoutinesAPI { _, _ in ["success": false, "error": "Job with ID or name '9' not found."] }
        do { try await api.perform(.pause, jobId: "9", profile: "alice"); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? RoutinesAPI.Failure, .init(message: "Job with ID or name '9' not found."))
            XCTAssertEqual(Redaction.describe(error), "Job with ID or name '9' not found.")
        }
    }
}
