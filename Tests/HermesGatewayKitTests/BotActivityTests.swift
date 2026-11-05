import Foundation
import XCTest
@testable import HermesGatewayKit

/// `BotActivityAPI` decoding/requests, the `BotActivityFeed` reducer (merge, cursor, cap, member phases) and
/// the plugin install RPCs (`plugins.manage`) against the in-process `FakeGateway`.
final class BotActivityTests: XCTestCase {
    private func row(_ key: String, rev: Int, ts: Double = 100, updated: Double? = nil, room: String? = "hba-r1",
                     member: String? = nil, bot: String? = "alice", status: String? = "ok", kind: String = "tool") -> BotActivityRow {
        BotActivityRow(key: key, rev: rev, ts: ts, updated: updated ?? ts, bot: bot, roomId: room, memberId: member,
                       kind: kind, status: status)
    }

    private func page(_ rows: [BotActivityRow], rev: Int, since: Int, limit: Int = 300) -> BotActivityPage {
        BotActivityPage(rows: rows, rev: rev, now: nil, since: since, limit: limit)
    }

    // MARK: - API

    func testActivityRequestAndRowDecoding() async throws {
        let json = #"""
        {"rows":[
          {"key":"k1","rev":5,"ts":1760000000.5,"updated":1760000001.25,"bot":"alice","session_id":"s","turn_id":"u",
           "room_id":"hba-r1","thread_id":"main","member_id":null,"kind":"tool","status":"ok","title":"terminal",
           "args":{"command":"ls"},"result":"plain text","text":null,"duration_ms":120},
          {"key":"k2","rev":6,"ts":1760000002,"updated":1760000002,"kind":"reasoning","status":"streaming","text":"thinking",
           "args":null,"result":{"a":[1]}},
          {"rev":7,"kind":"tool"}
        ],"rev":42,"now":1760000003.0}
        """#
        let port = PluginStub.routes(["GET /api/plugins/bot-activity/activity": .init(json: json)])
        let api = BotActivityAPI(rest: PluginStub.rest(port: port, plugin: "bot-activity"))
        let p = try await api.activity(room: "hba-r1", since: 3, limit: 5000)
        XCTAssertEqual(p.rows.map(\.key), ["k1", "k2"], "a row without key is dropped")
        XCTAssertEqual(p.rev, 42)
        XCTAssertEqual(p.now, 1760000003.0)
        XCTAssertEqual(p.since, 3)
        XCTAssertEqual(p.limit, 1000, "limit is clamped to MAX_LIMIT")
        let k1 = p.rows[0]
        XCTAssertEqual(k1.args, ["command": "ls"])
        XCTAssertEqual(k1.result, .string("plain text"))
        XCTAssertEqual(k1.durationMs, 120)
        XCTAssertNil(k1.memberId)
        XCTAssertEqual(k1.threadId, "main")
        XCTAssertNil(p.rows[1].args)
        XCTAssertEqual(p.rows[1].result, ["a": [1]])
        XCTAssertEqual(p.rows[1].text, "thinking")
        let seen = try XCTUnwrap(StubURLProtocol.requests(port: port).first)
        XCTAssertEqual(PluginStub.query(seen), ["since": "3", "limit": "1000", "room": "hba-r1"])
    }

    func testBotsSetupAndRollOut() async throws {
        let port = PluginStub.routes([
            "GET /api/plugins/bot-activity/bots": .init(json: #"{"bots":[{"bot":"alice","title":"Alice","last_seen":5.5,"active":[{"key":"k","kind":"turn","status":"running","title":"t","ts":1,"updated":2,"room_id":"hba-r1","thread_id":null}]}],"now":9}"#),
            "GET /api/plugins/bot-activity/setup": .init(json: #"{"profiles":[{"bot":"alice","title":"Alice","installed":true,"enabled":true,"outdated":false,"opted_out":false,"tracked":true},{"bot":"bob","installed":false,"enabled":false,"outdated":false,"opted_out":false,"tracked":false}],"untracked":["bob"],"outdated":[],"opted_out":[]}"#),
            "POST /api/plugins/bot-activity/setup": .init(json: #"{"results":[{"bot":"bob","ok":true,"changed":true,"restart_needed":false,"via":"copy"}],"ok":true}"#),
        ])
        let api = BotActivityAPI(rest: PluginStub.rest(port: port, plugin: "bot-activity"))
        let bots = try await api.bots()
        XCTAssertEqual(bots.first?.active.first?.status, "running")
        XCTAssertEqual(bots.first?.lastSeen, 5.5)
        let setup = try await api.setupStatus()
        XCTAssertEqual(setup.profiles.map(\.tracked), [true, false])
        XCTAssertTrue(setup.needsRollOut)
        let r = try await api.rollOut(bots: ["bob"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.results.first?.changed, true)
        _ = try await api.rollOut()
        let posts = StubURLProtocol.requests(port: port).filter { $0.method == "POST" }
        XCTAssertEqual(posts.map(\.body), [["bots": ["bob"]], [:]])
    }

    // MARK: - feed

    func testLaterRevReplacesEarlierAndOlderNeverOverwrites() {
        var feed = BotActivityFeed()
        feed.apply(page([row("a", rev: 1, status: "running"), row("b", rev: 2)], rev: 2, since: 0))
        feed.apply(page([row("a", rev: 3, status: "ok")], rev: 3, since: 2))
        XCTAssertEqual(feed.rows.first { $0.key == "a" }?.status, "ok")
        feed.apply(page([row("a", rev: 1, status: "running")], rev: 3, since: 0))  // a stale replay
        XCTAssertEqual(feed.rows.first { $0.key == "a" }?.status, "ok")
        XCTAssertEqual(feed.rows.count, 2)
    }

    func testAnEqualRevNeverOverwrites() {
        var feed = BotActivityFeed()
        feed.apply(page([row("a", rev: 3, status: "ok")], rev: 3, since: 0))
        feed.apply(page([row("a", rev: 3, status: "running")], rev: 3, since: 0))  // a replay of the same rev
        XCTAssertEqual(feed.rows.first { $0.key == "a" }?.status, "ok", "the copy already held stays")
    }

    func testCursorFollowsServerRevUnlessPageWasCut() {
        var feed = BotActivityFeed()
        feed.apply(page([row("a", rev: 4)], rev: 50, since: 0, limit: 1))
        XCTAssertEqual(feed.cursor, 50, "initial page: jump to the store max")
        feed.apply(page([row("b", rev: 51), row("c", rev: 52)], rev: 90, since: 50, limit: 2))
        XCTAssertEqual(feed.cursor, 52, "a full incremental page resumes from the last rev received")
        feed.apply(page([row("d", rev: 53)], rev: 90, since: 52, limit: 2))
        XCTAssertEqual(feed.cursor, 90, "a short page has everything: the store max is safe")
        feed.apply(page([], rev: 10, since: 0))
        XCTAssertEqual(feed.cursor, 90, "never moves backwards")
    }

    func testCapacityIsPerRoomAndDropsOldestUpdated() {
        var feed = BotActivityFeed(capacity: 2)
        feed.apply(page([row("r1a", rev: 1, ts: 1), row("r1b", rev: 2, ts: 2), row("r1c", rev: 3, ts: 3),
                         row("r2a", rev: 4, ts: 1, room: "hba-r2")], rev: 4, since: 0))
        XCTAssertEqual(Set(feed.rows.map(\.key)), ["r1b", "r1c", "r2a"])
        XCTAssertEqual(feed.rows.map(\.key), ["r2a", "r1b", "r1c"], "chronological by ts, then rev")
    }

    func testRoomFeedDropsRowsOfOtherRoomsButKeepsTheCursor() {
        var feed = BotActivityFeed()
        feed.apply(page([row("mine", rev: 1), row("other", rev: 2, room: "hba-r2"), row("none", rev: 3, room: nil)], rev: 3, since: 0),
                   room: "hba-r1")
        XCTAssertEqual(feed.rows.map(\.key), ["mine"])
        XCTAssertEqual(feed.cursor, 3)
    }

    func testTotalCapacityBoundsTheWholeFeed() {
        var feed = BotActivityFeed(capacity: 10, totalCapacity: 3)
        feed.apply(page((1...5).map { row("r\($0)", rev: $0, ts: Double($0), room: "hba-r\($0 % 2)") }, rev: 5, since: 0))
        XCTAssertEqual(feed.rows.map(\.key), ["r3", "r4", "r5"], "the oldest updated rows go first, across rooms")
        XCTAssertEqual(BotActivityFeed().totalCapacity, BotActivityFeed.defaultTotalCapacity)
    }

    func testMemberPhasesUseThePluginFreshnessWindows() {
        let now = 10_000.0
        func phase(_ rows: [BotActivityRow]) -> (BotActivityPhase, String?) {
            let (p, current) = BotActivityFeed.phase(of: rows, now: now)
            return (p, current?.key)
        }
        let a = phase([row("a1", rev: 1, ts: now - 100, member: "m-a", status: "ok"),
                       row("a2", rev: 2, ts: now - 60, member: "m-a", status: "running")])
        XCTAssertEqual(a.0, .running)
        XCTAssertEqual(a.1, "a2")
        XCTAssertEqual(phase([row("b1", rev: 3, ts: now - 10, member: "m-b", bot: "bob", status: "streaming", kind: "reasoning")]).0,
                       .streaming)
        XCTAssertEqual(phase([row("c1", rev: 4, ts: now - 40, member: "m-c", bot: "carol", status: "streaming", kind: "message")]).0,
                       .idle, "a stream quiet for > 30 s is done")
        XCTAssertEqual(phase([row("d1", rev: 5, ts: now - 1000, member: "m-d", bot: "dave", status: "running")]).0,
                       .idle, "running but stale (> 15 min) is abandoned")
        let e = phase([row("e0", rev: 5, ts: now - 6, member: "m-e", bot: "erin", status: "running"),
                       row("e1", rev: 6, ts: now - 5, member: "m-e", bot: "erin", status: "waiting"),
                       row("e2", rev: 7, ts: now - 4, member: "m-e", bot: "erin", status: "error")])
        XCTAssertEqual(e.0, .waiting, "waiting wins over running")
        XCTAssertEqual(e.1, "e1")
    }

    // MARK: - plugin install RPCs

    func testPluginStateFromManageListRows() {
        XCTAssertEqual(BotActivityPluginManager.state(fromRows: [["name": "other"]]), .notInstalled)
        let rows: [JSONValue] = [["name": "bot-activity", "key": "bot-activity", "status": "not enabled", "version": "0.1.0", "source": "user"]]
        let s = BotActivityPluginManager.state(fromRows: rows)
        XCTAssertEqual(s, .installed(status: "not enabled", version: "0.1.0", source: "user", pinnedSHA: nil))
        XCTAssertFalse(s.isEnabled)
        XCTAssertFalse(s.isPinnedCopy, "no install record (a manual/dev copy): not provably the reviewed commit")
        XCTAssertTrue(BotActivityPluginManager.state(fromRows: [["name": "bot-activity", "status": "enabled"]]).isEnabled)
    }

    func testOnlyACopyPinnedToTheReviewedCommitIsProvenance() {
        func state(_ sha: String?) -> BotActivityPluginManager.State {
            var row: [String: JSONValue] = ["name": "bot-activity", "status": "disabled", "source": "user"]
            if let sha { row["pinned_sha"] = .string(sha) }
            return BotActivityPluginManager.state(fromRows: [.object(row)])
        }
        XCTAssertTrue(state(BotActivityPluginManager.pinnedRef).isPinnedCopy)
        XCTAssertTrue(state(BotActivityPluginManager.pinnedRef.uppercased()).isPinnedCopy, "SHA case does not matter")
        XCTAssertFalse(state("0000000000000000000000000000000000000000").isPinnedCopy, "another commit (a branch, a fork's head)")
        XCTAssertFalse(state("").isPinnedCopy)
        XCTAssertFalse(state(nil).isPinnedCopy)
        XCTAssertFalse(BotActivityPluginManager.State.notInstalled.isPinnedCopy)
    }

    func testInstallListRemoveUsePluginsManage() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, params in
            guard method == "plugins.manage" else { return nil }
            switch params["action"]?.string {
            case "list": return ["plugins": [["name": "bot-activity", "status": "enabled", "version": "0.1.0", "source": "user"]]]
            case "install": return ["ok": true, "plugin_name": "bot-activity", "enabled": true]
            case "toggle": return ["ok": true, "name": "bot-activity"]
            case "remove": return ["ok": true]
            default: return ["__error": ["code": 4017, "message": "unknown"]]
            }
        }
        let client = Parity.client(gw)
        try await client.connect(timeout: 10)
        defer { client.close() }
        let m = BotActivityPluginManager(client: client)
        let state = try await m.botActivityState()
        XCTAssertTrue(state.isEnabled)
        try await m.installBotActivity()
        try await m.installBotActivity(force: true)
        try await m.enableBotActivity()
        try await m.removeBotActivity()
        let calls = gw.received.filter { $0["method"]?.string == "plugins.manage" }.compactMap { $0["params"] }
        XCTAssertEqual(calls, [
            ["action": "list"],
            ["action": "install", "repo": "https://github.com/risyadul/hermes-bot-activity",
             "ref": "da1c9d10eb228cd6f0a93e255ee92c8c3a6717f2", "enable": true],
            ["action": "install", "repo": "https://github.com/risyadul/hermes-bot-activity",
             "ref": "da1c9d10eb228cd6f0a93e255ee92c8c3a6717f2", "enable": true, "force": true],
            ["action": "toggle", "name": "bot-activity", "enable": true],
            ["action": "remove", "name": "bot-activity"],
        ])
        XCTAssertEqual(BotActivityPluginManager.pinnedRef.count, 40, "a full commit SHA")
        XCTAssertGreaterThanOrEqual(BotActivityPluginManager.installTimeout, 180)
    }
}
