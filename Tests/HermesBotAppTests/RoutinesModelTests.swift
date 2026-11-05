import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// In-memory `cron.manage` for `RoutinesModel` tests: keeps jobs, applies pause/resume/remove/add, records
/// every call's params, and fails or answers without `scoped` on demand. Every name is a placeholder.
final class FakeCron: @unchecked Sendable {
    struct State {
        var jobs: [JSONValue] = []
        /// nil = an older gateway that omits `scoped`.
        var scopes = true
        var listError: Error?
        var actionFailure: String?
        var pauseFailure: String?
        var calls: [JSONValue] = []
        var nextId = 0
    }

    private let lock = NSLock()
    private var state = State()

    @discardableResult
    func with<R>(_ body: (inout State) throws -> R) rethrows -> R { try lock.withLock { try body(&state) } }

    var calls: [JSONValue] { with { $0.calls } }
    func actions(_ name: String) -> [JSONValue] { calls.filter { $0["action"]?.string == name } }

    lazy var api = RoutinesAPI { [unowned self] method, params in try self.handle(method, params) }

    private func handle(_ method: String, _ p: JSONValue) throws -> JSONValue {
        precondition(method == "cron.manage")
        return try with { s in
            s.calls.append(p)
            let id = p["name"]?.string ?? ""
            func update(_ fields: [String: JSONValue]) -> Bool {
                guard let i = s.jobs.firstIndex(where: { $0["job_id"]?.string == id }), case .object(var o) = s.jobs[i] else { return false }
                for (k, v) in fields { o[k] = v }
                s.jobs[i] = .object(o)
                return true
            }
            switch p["action"]?.string {
            case "list":
                if let e = s.listError { throw e }
                var r: [String: JSONValue] = ["success": true, "count": .number(Double(s.jobs.count)), "jobs": .array(s.jobs)]
                if s.scopes, let profile = p["profile"] { r["scoped"] = profile }
                return .object(r)
            case "pause":
                if let f = s.pauseFailure ?? s.actionFailure { return ["success": false, "error": .string(f)] }
                return update(["enabled": false, "state": "paused"]) ? ["success": true] : ["success": false, "error": "not found"]
            case "resume":
                if let f = s.actionFailure { return ["success": false, "error": .string(f)] }
                return update(["enabled": true, "state": "scheduled"]) ? ["success": true] : ["success": false, "error": "not found"]
            case "remove":
                if let f = s.actionFailure { return ["success": false, "error": .string(f)] }
                s.jobs.removeAll { $0["job_id"]?.string == id }
                return ["success": true]
            case "add":
                if let f = s.actionFailure { return ["success": false, "error": .string(f)] }
                s.nextId += 1
                s.jobs.append(["job_id": .string("new\(s.nextId)"), "name": p["name"] ?? "", "prompt_preview": p["prompt"] ?? "",
                               "schedule": p["schedule"] ?? "", "enabled": true, "state": "scheduled"])
                return ["success": true]
            default:
                return ["success": false, "error": "unknown"]
            }
        }
    }

    static func job(_ id: String, _ name: String, prompt: String = "Do it", enabled: Bool = true, state: String = "scheduled") -> JSONValue {
        ["job_id": .string(id), "name": .string(name), "prompt_preview": .string(prompt), "schedule": "every 60m",
         "enabled": .bool(enabled), "state": .string(state)]
    }
}

@MainActor
final class RoutinesModelTests: XCTestCase {
    private func fake(_ jobs: [JSONValue] = [FakeCron.job("a1", "[bot:alice] Brief"), FakeCron.job("b1", "[bot:bob] Other"),
                                             FakeCron.job("u1", "Untagged")]) -> FakeCron {
        let f = FakeCron()
        f.with { $0.jobs = jobs }
        return f
    }

    private func model(_ f: FakeCron) -> RoutinesModel { RoutinesModel(bot: "alice", api: f.api) }

    func testScopedListShowsTheWholeStore() async {
        let f = fake()
        let m = model(f)
        await m.refresh()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.scoped, "alice")
        XCTAssertEqual(m.jobs.map(\.id), ["a1", "b1", "u1"])
        XCTAssertEqual(f.calls, [["action": "list", "include_disabled": true, "profile": "alice"]])
        XCTAssertEqual(m.activeProfile, "alice")
    }

    func testOlderGatewayFallsBackToTheTagFilterWithAHint() async {
        let f = fake([FakeCron.job("b1", "[bot:bob] Other"), FakeCron.job("u1", "Untagged")])
        f.with { $0.scopes = false }
        let m = model(f)
        await m.refresh()
        XCTAssertNil(m.scoped)
        XCTAssertEqual(m.jobs, [])
        XCTAssertEqual(m.all.count, 2)
        XCTAssertNotNil(m.filterHint)
        XCTAssertEqual(m.activeProfile, "default")
    }

    func testFirstLoadFailureIsFailedLaterFailureKeepsTheList() async {
        let f = fake()
        f.with { $0.listError = GatewayClient.RPCError(code: 5023, message: "cron.manage failed", data: nil) }
        let m = model(f)
        await m.refresh()
        guard case .failed(let text) = m.phase else { return XCTFail("expected failed, got \(m.phase)") }
        XCTAssertTrue(text.contains("cron.manage failed"))
        f.with { $0.listError = nil }
        await m.refresh()
        XCTAssertEqual(m.phase, .ready)
        f.with { $0.listError = GatewayClient.ClientError.notConnected }
        await m.refresh()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.jobs.count, 3, "the last list stays")
        XCTAssertNotNil(m.refreshError)
    }

    func testActiveLegacyJobsArePausedOnLoad() async {
        let legacy = FakeCron.job("l1", "[bot:alice] Old", prompt: "You are running the scheduled routine \"Old\" for agent 'alice'")
        let f = fake([legacy, FakeCron.job("a1", "[bot:alice] Fine")])
        let m = model(f)
        await m.refresh()
        XCTAssertEqual(f.actions("pause"), [["action": "pause", "name": "l1", "profile": "alice"]])
        XCTAssertEqual(m.job("l1")?.state, "paused")
        XCTAssertFalse(m.isActive(m.job("l1")!))
        await m.refresh()
        XCTAssertEqual(f.actions("pause").count, 1, "an already paused legacy job is left alone")
    }

    func testAFailedLegacyPauseDoesNotFailTheList() async {
        let legacy = FakeCron.job("l1", "[bot:alice] Old", prompt: "You are running the scheduled routine \"Old\"")
        let f = fake([legacy])
        f.with { $0.pauseFailure = "store locked" }
        let m = model(f)
        await m.refresh()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.job("l1")?.state, "scheduled", "only jobs the gateway paused are shown paused")
        XCTAssertFalse(m.isActive(m.job("l1")!), "a legacy job never reads as active")
        let ok = await m.setActive(m.job("l1")!, true)
        XCTAssertFalse(ok, "a legacy job cannot be resumed")
    }

    func testPauseAndResume() async {
        let f = fake()
        let m = model(f)
        await m.refresh()
        let ok = await m.setActive(m.job("a1")!, false)
        XCTAssertTrue(ok)
        XCTAssertEqual(f.actions("pause"), [["action": "pause", "name": "a1", "profile": "alice"]])
        XCTAssertFalse(m.isActive(m.job("a1")!))
        XCTAssertEqual(m.pendingActive, [:], "the list caught up")
        await m.setActive(m.job("a1")!, true)
        XCTAssertEqual(f.actions("resume").count, 1)
        XCTAssertTrue(m.isActive(m.job("a1")!))
    }

    func testRefusedPauseRollsBackWithTheGatewaysWords() async {
        let f = fake()
        let m = model(f)
        await m.refresh()
        f.with { $0.actionFailure = "Job with ID or name 'a1' not found." }
        let ok = await m.setActive(m.job("a1")!, false)
        XCTAssertFalse(ok)
        XCTAssertTrue(m.isActive(m.job("a1")!), "rolled back")
        XCTAssertEqual(m.actionError, "Pause “Brief” failed: Job with ID or name 'a1' not found.")
        XCTAssertTrue(m.busy.isEmpty)
    }

    func testDeleteRemovesAndSaysSo() async {
        let f = fake()
        let m = model(f)
        await m.refresh()
        let ok = await m.remove(m.job("a1")!)
        XCTAssertTrue(ok)
        XCTAssertEqual(f.actions("remove"), [["action": "remove", "name": "a1", "profile": "alice"]])
        XCTAssertNil(m.job("a1"))
        XCTAssertEqual(m.notice, "Deleted “Brief”.")
    }

    func testCreateSendsDesktopsPayloadInTheBotsOwnStore() async {
        let f = fake([])
        let m = model(f)
        await m.refresh()
        var d = RoutinesModel.Draft(title: "Morning", instruction: "Summarise my inbox")
        d.schedule.frequency = .weekdays
        d.schedule.time = "8:30"
        d.schedule.repeatN = "10"
        d.continuity = true
        d.deliverToBotChat = true
        let error = await m.create(d)
        XCTAssertNil(error)
        XCTAssertEqual(f.actions("add"), [["action": "add", "name": "[bot:alice] Morning", "schedule": "30 8 * * 1-5",
                                           "prompt": "Summarise my inbox", "profile": "alice", "repeat": 10,
                                           "continuity": true, "deliver": "bot-chat"]])
        XCTAssertEqual(m.jobs.map { Routines.title($0.name) }, ["Morning"], "the list is fetched again")
        XCTAssertEqual(m.notice, "Routine created: Morning")
    }

    func testCreateOnAnUnscopedGatewayDelegatesToTheBot() async {
        let f = fake([])
        f.with { $0.scopes = false }
        let m = model(f)
        await m.refresh()
        var d = RoutinesModel.Draft(title: "Ping", instruction: "Say hi")
        d.schedule.frequency = .once
        _ = await m.create(d)
        let add = f.actions("add").first
        XCTAssertEqual(add?["schedule"], "30m")
        XCTAssertNil(add?["repeat"], "once never carries repeat")
        XCTAssertNil(add?["deliver"], "history only sends nothing")
        XCTAssertNil(add?["continuity"])
        XCTAssertEqual(add?["prompt"]?.string, Routines.prompt(bot: "alice", title: "Ping", instruction: "Say hi", activeProfile: "default"))
    }

    func testCreateBlockersAndGatewayRefusal() async {
        let f = fake([])
        let m = model(f)
        await m.refresh()
        XCTAssertEqual(RoutinesModel.blocker(.init(title: " ", instruction: "x")), "Give the routine a name.")
        XCTAssertEqual(RoutinesModel.blocker(.init(title: "x", instruction: "")), "Say what the bot should do.")
        var adv = RoutinesModel.Draft(title: "x", instruction: "y")
        adv.schedule.frequency = .advanced
        XCTAssertEqual(RoutinesModel.blocker(adv), "Enter a schedule.")
        XCTAssertEqual(RoutinesModel.blocker(.init(title: "a\0", instruction: "y")), "Job name cannot contain NUL (U+0000).")
        let blocked = await m.create(.init(title: "", instruction: "y"))
        XCTAssertEqual(blocked, "Give the routine a name.")
        XCTAssertTrue(f.actions("add").isEmpty, "nothing sent")
        f.with { $0.actionFailure = "Invalid schedule 'every banana'" }
        let refused = await m.create(.init(title: "x", instruction: "y"))
        XCTAssertEqual(refused, "Invalid schedule 'every banana'")
        XCTAssertNil(m.notice)
    }

    func testPollingStartsAndStops() async throws {
        let f = fake()
        let m = RoutinesModel(bot: "alice", api: f.api, sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
        m.start()
        XCTAssertTrue(m.isPolling)
        let end = Date().addingTimeInterval(5)
        while f.actions("list").count < 3, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(f.actions("list").count, 3)
        m.stop()
        XCTAssertFalse(m.isPolling)
        let after = f.actions("list").count
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertLessThanOrEqual(f.actions("list").count, after + 1)
    }
}
