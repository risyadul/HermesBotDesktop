import Foundation
import XCTest
@testable import HermesGatewayKit

/// A4 / A5 / A6 / A17 at the protocol level: roster activity from `profiles.list {include_sessions: true}`,
/// section fields in `ui_meta`, needs-attention classification and the read-only transcript route. Fakes
/// only: nothing reaches a real gateway or profile.
final class BotRosterActivityTests: XCTestCase {
    private func row(canonical: JSONValue? = nil, last: JSONValue? = nil, worker: JSONValue? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": "alpha"]
        if let canonical { o["canonical_session"] = canonical }
        if let last { o["last_session"] = last }
        if let worker { o["worker_session"] = worker }
        return .object(o)
    }

    // MARK: A4 activity

    func testActivityIsTheNewerOfBotChatAndNewestSession() {
        let a = BotRosterActivity(row: row(canonical: ["id": "c1", "resolved_id": "c2", "preview": "hi", "last_active": 200],
                                           last: ["id": "s1", "title": "Cron", "preview": "ran", "last_active": 100]))
        XCTAssertEqual(a.activitySession?.id, "c1")
        XCTAssertEqual(a.lastActive, 200)
        let b = BotRosterActivity(row: row(canonical: ["id": "c1", "last_active": 50], last: ["id": "s1", "last_active": 100]))
        XCTAssertEqual(b.activitySession?.id, "s1")
        XCTAssertEqual(b.lastActive, 100)
        XCTAssertEqual(BotRosterActivity(row: row()).lastActive, 0)
        XCTAssertNil(BotRosterActivity(row: row(last: ["id": "", "last_active": 9])).last, "a row without an id is no session")
    }

    func testAgeIncludesWorkerRunsButUnreadAndSortDoNot() {
        let a = BotRosterActivity(row: row(canonical: ["id": "c", "last_active": 100], worker: ["id": "w", "last_active": 400]))
        XCTAssertEqual(a.ageStamp, 400)
        XCTAssertEqual(a.lastActive, 100)
    }

    func testPreviewIsTheBotChatsElseTheNewestSessions() {
        let a = BotRosterActivity(row: row(canonical: ["id": "c", "preview": "from chat", "last_active": 1],
                                           last: ["id": "s", "preview": "from cron", "last_active": 9]))
        XCTAssertEqual(a.preview?.text, "from chat", "preview identity = click identity (#88200)")
        let b = BotRosterActivity(row: row(last: ["id": "s", "preview": "from cron", "last_active": 9]))
        XCTAssertEqual(b.preview?.text, "from cron")
        XCTAssertNil(BotRosterActivity(row: row(canonical: ["id": "c", "preview": "  \n "])).preview)
    }

    func testPreviewStripsBotToBotPrefixKeepsSenderFoldsAndCuts() {
        XCTAssertEqual(BotPreview("Message from 🤖 Scout (@scout): found it"), BotPreview(text: "found it", fromBot: "scout"))
        XCTAssertEqual(BotPreview("message from agent 'Planner': plan\nready"), BotPreview(text: "plan ready", fromBot: "planner"))
        XCTAssertEqual(BotPreview("**Done** with `make`"), BotPreview(text: "Done with make"))
        // Regression (live UI test): a file send showed its raw local path ("MEDIA:/Users/…") in the row.
        XCTAssertEqual(BotPreview("MEDIA:/Users/someone/shots/login.png"), BotPreview(text: "📎 login.png"))
        XCTAssertEqual(BotPreview("Here it is\nMEDIA:/tmp/report.pdf"), BotPreview(text: "Here it is 📎 report.pdf"))
        XCTAssertEqual(BotPreview("## Heading"), BotPreview(text: "Heading"))
        XCTAssertEqual(BotPreview("Message from 🤖 Scout (@scout):")?.text, "…")
        let long = BotPreview(String(repeating: "a", count: 500))
        XCTAssertEqual(long?.text.count, BotPreview.limit)
        XCTAssertTrue(long?.text.hasSuffix("…") ?? false)
    }

    func testSortKeyIsNewestOfCreationAndLastMessageInMilliseconds() {
        XCTAssertEqual(BotRosterActivity.sortKey(lastActive: 10, created: nil), 10_000)
        XCTAssertEqual(BotRosterActivity.sortKey(lastActive: 10, created: 50_000), 50_000)
        XCTAssertEqual(BotRosterActivity.sortKey(lastActive: 0, created: nil), 0)
    }

    func testFetchAsksForSessionsOnceAndKeysByProfile() async throws {
        let calls = Calls()
        let result = try await BotRosterActivity.fetch { method, params in
            calls.add(method, params)
            return ["profiles": [["name": "alpha", "last_session": ["id": "s", "last_active": 5]], ["name": "beta"], ["junk": 1]]]
        }
        XCTAssertEqual(calls.all.map(\.0), ["profiles.list"])
        XCTAssertEqual(calls.all.first?.1, ["include_sessions": true])
        XCTAssertEqual(result.keys.sorted(), ["alpha", "beta"])
        XCTAssertEqual(result["alpha"]?.lastActive, 5)
    }

    // MARK: A17 recent session

    func testRecentSessionIsNewestListedSessionNeverTheBotChat() {
        let a = BotRosterActivity(row: row(canonical: ["id": "c1", "resolved_id": "c2"], last: ["id": "s1", "title": "Daily digest"]))
        XCTAssertEqual(a.recentSession?.id, "s1")
        XCTAssertEqual(a.recentSession?.title, "Daily digest")
        XCTAssertNil(BotRosterActivity(row: row(canonical: ["id": "c1"], last: ["id": "c1"])).recentSession)
        XCTAssertNil(BotRosterActivity(row: row(canonical: ["id": "c1", "resolved_id": "c2"], last: ["id": "c2"])).recentSession)
        XCTAssertNil(BotRosterActivity(row: row(canonical: ["id": "c1"])).recentSession, "a new bot has only its Bot Chat")
    }

    // MARK: A5 section fields

    func testSectionFieldsAndCreatedAreReadFromUiMeta() {
        let meta = BotUIMeta(row: ["ui_meta": ["hermes-bots": ["sectionId": "sec-1", "sectionName": " Clients ", "created": 1_700_000_000_000]]])
        XCTAssertEqual(meta, BotUIMeta(sectionId: "sec-1", sectionName: "Clients", created: 1_700_000_000_000))
        let blank = BotUIMeta(row: ["ui_meta": ["hermes-bots": ["sectionId": "  ", "sectionName": .null, "created": 0]]])
        XCTAssertEqual(blank, BotUIMeta())
    }

    func testSectionWriteMergesOverServerNamespaceAndClearsWithNulls() async throws {
        let gw = BotMetaSyncTests.FakeGateway(
            lists: [["profiles": [["name": "alpha", "ui_meta": ["hermes-bots": ["pinned": true, "title": "A", "chat": "x"]],
                                   "ui_meta_revisions": ["hermes-bots": 2]]]]],
            configures: [["applied": ["ui_meta": true]]])
        let filed = try await BotMetaSync.save(name: "alpha", patch: ["sectionId": "sec-1", "sectionName": "Clients"], call: gw.call)
        XCTAssertEqual(filed, .persisted(BotUIMeta(pinned: true, sectionId: "sec-1", sectionName: "Clients")))
        XCTAssertEqual(gw.configureParams.first?["ui_meta"]?["hermes-bots"],
                       ["pinned": true, "title": "A", "sectionId": "sec-1", "sectionName": "Clients"])
        let cleared = try await BotMetaSync.save(name: "alpha", patch: ["sectionId": .null, "sectionName": .null], call: gw.call)
        XCTAssertEqual(cleared, .persisted(BotUIMeta(pinned: true)))
        XCTAssertEqual(gw.configureParams.last?["ui_meta"]?["hermes-bots"]?["sectionId"], .null, "Desktop clears with an explicit null")
    }

    // MARK: A6 attention

    func testAttentionClassesFollowDesktop() {
        let cases: [(String, BotAttentionReason?)] = [
            ("provider_quota_limit", .quota),
            ("missing_config", .missingConfig),
            ("No LLM provider configured", .missingConfig),
            ("Missing API key for openrouter", .missingConfig),
            ("HTTP 401 Unauthorized", .providerAuth),
            ("Invalid API key", .providerAuth),
            ("credentials are expired", .providerAuth),
            ("insufficient credits on your account", .quota),
            ("HTTP 402 Payment Required", .quota),
            ("You exceeded your current quota", .quota),
            ("The agent is blocked by policy", .agentBlocked),
            ("rate limit exceeded (429)", nil),
            ("502 Bad Gateway", nil),
            ("request timed out", nil),
            ("Quota temporarily unavailable", nil),
            ("something odd", nil),
            ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(BotAttentionReason.classify(text), expected, text)
        }
    }

    func testReasonCodeWinsOverTextAndMessageIsKept() {
        XCTAssertNil(BotAttention(failure: "401 unauthorized", reasonCode: "provider_rate_limit"), "a typed transient code never badges")
        let a = BotAttention(failure: "boom", reasonCode: "provider_auth_or_access")
        XCTAssertEqual(a?.reason, .providerAuth)
        XCTAssertEqual(a?.message, "boom")
        XCTAssertEqual(BotAttention(failure: String(repeating: "quota ", count: 100))?.message.count, 200)
        XCTAssertEqual(BotAttentionReason.missingConfig.hint, "Provider not configured — run hermes model")
    }

    // MARK: A17 read-only transcript

    func testTranscriptURLIsTheReadOnlyMessagesRoute() throws {
        let url = try XCTUnwrap(SessionTranscriptREST.url(base: URL(string: "http://127.0.0.1:9119")!, sessionId: "2026 a/b", profile: "alpha"))
        XCTAssertEqual(url.path(percentEncoded: true), "/api/sessions/2026%20a%2Fb/messages")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query, [URLQueryItem(name: "profile", value: "alpha"), URLQueryItem(name: "inline_images", value: "false")])
        XCTAssertNil(SessionTranscriptREST.url(base: URL(string: "http://h")!, sessionId: "", profile: "alpha"))
    }

    func testTranscriptDecodeReadsStoredRows() throws {
        let body: JSONValue = ["session_id": "s", "messages": [
            ["role": "user", "content": "steer marker", "display_content": "my words"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "t"]]],
            ["role": "tool", "content": "{\"ok\":true}", "tool_name": "terminal"],
            ["role": "assistant", "content": "done"],
            ["role": "user", "content": "[System: nudge]", "display_kind": "hidden"],
        ]]
        let history = try SessionTranscriptREST.decode(status: 200, body: body)
        XCTAssertEqual(history.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(history[0].text, "my words")
        XCTAssertEqual(history[1].toolName, "terminal")
        XCTAssertEqual(history[2].text, "done")
    }

    func testTranscriptDecodeFailures() {
        XCTAssertThrowsError(try SessionTranscriptREST.decode(status: 404, body: ["detail": "Session not found"])) {
            XCTAssertEqual($0 as? SessionTranscriptREST.Failure, .notFound)
        }
        XCTAssertThrowsError(try SessionTranscriptREST.decode(status: 503, body: nil)) {
            XCTAssertEqual($0 as? SessionTranscriptREST.Failure, .http(503))
        }
        XCTAssertThrowsError(try SessionTranscriptREST.decode(status: 200, body: ["messages": "x"])) {
            XCTAssertEqual($0 as? SessionTranscriptREST.Failure, .badResponse)
        }
    }

    func testNoRESTAccessIsUnavailableWithoutARequest() async {
        do {
            _ = try await SessionTranscriptREST.messages(nil, sessionId: "s", profile: "p")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? SessionTranscriptREST.Failure, .unavailable)
        }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, JSONValue)] = []
    func add(_ m: String, _ p: JSONValue) { lock.withLock { calls.append((m, p)) } }
    var all: [(String, JSONValue)] { lock.withLock { calls } }
}
