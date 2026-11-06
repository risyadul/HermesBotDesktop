import Foundation
import XCTest
@testable import HermesGatewayKit

/// The canonical "Bot Chat": find → resume, create only on confirmed absence, 4022 adopt, fail closed,
/// no close/delete/rename on teardown, 4090 typed error.
final class CanonicalBotChatTests: XCTestCase {
    private static let found: JSONValue = ["sessions": [["id": "st-root", "resolved_id": "st-tip", "title": "Bot Chat",
                                                          "root_title": "Bot Chat", "message_count": 3]]]
    private static let resumed: JSONValue = [
        "session_id": "rt-9", "stored_session_id": "st-tip", "resumed": true, "info": [:],
        "messages": [["role": "user", "text": "hi"],
                     ["role": "assistant", "text": ""],
                     ["role": "tool", "name": "terminal", "context": "ls"],
                     ["role": "assistant", "text": "hello!"],
                     ["role": "system", "text": "note", "display_kind": "hidden"]],
        "open_requests": [["id": "srq-open1", "method": "approval", "params": ["session_id": "rt-9", "command": "rm"]]],
    ]

    private func params(_ gw: FakeGateway, _ method: String, nth: Int = 0) -> JSONValue? {
        gw.received.filter { $0["method"]?.string == method }.dropFirst(nth).first?["params"]
    }

    private func afterCapabilities(_ gw: FakeGateway) -> [String] { Array(Parity.methods(gw).dropFirst()) }

    func testFoundChatIsResumedAtTheTipAndTeardownSendsNothing() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume": return Self.resumed
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot, cols: 96)
        XCTAssertEqual(afterCapabilities(gw), ["session.list", "session.resume"])
        XCTAssertEqual(params(gw, "session.list"), ["profile": "fake", "title": "Bot Chat", "include_hidden": true, "limit": 200])
        XCTAssertEqual(params(gw, "session.resume"), ["session_id": "st-tip", "profile": "fake", "cols": 96, "source": "desktop",
                                                      "close_on_disconnect": false, "inline_images": false])
        XCTAssertTrue(s.isCanonical)
        XCTAssertEqual(s.sessionId, "rt-9", "the runtime id from the resume reply")
        XCTAssertEqual(s.storedSessionId, "st-tip")
        XCTAssertEqual(s.history, [ChatHistoryMessage(role: .user, text: "hi"),
                                   ChatHistoryMessage(role: .tool, text: "", toolName: "terminal", toolContext: "ls"),
                                   ChatHistoryMessage(role: .assistant, text: "hello!")])
        XCTAssertEqual(s.openRequests.map(\.id), ["srq-open1"])

        let notes = await s.close(deleteStored: true)
        s.detach()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(afterCapabilities(gw), ["session.list", "session.resume"], "no close/delete/title on teardown")
        XCTAssertEqual(notes.count, 1)
    }

    func testLookupFailureFailsClosed() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in m == "session.list" ? ["__error": ["code": 5006, "message": "db locked"]] : Parity.defaults(m) }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        do { _ = try await BotChatSession.openCanonical(backend, bot: Parity.bot); XCTFail("opened") }
        catch BotChatError.lookupFailed(let why) { XCTAssertTrue(why.contains("5006"), why) }
        XCTAssertEqual(afterCapabilities(gw), ["session.list"], "never mint on a failed lookup")
    }

    func testEmptyLookupWithRosterCanonicalIsUnconfirmed() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return ["sessions": []]
            case "profiles.list": return ["profiles": [["name": "fake", "canonical_session": ["id": "st-root"]]]]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        do { _ = try await BotChatSession.openCanonical(backend, bot: Parity.bot); XCTFail("opened") }
        catch BotChatError.absenceUnconfirmed {}
        XCTAssertEqual(afterCapabilities(gw), ["session.list", "profiles.list"])
        XCTAssertEqual(params(gw, "profiles.list"), ["include_sessions": true])
    }

    func testConfirmedAbsenceCreatesThenTitles() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return ["sessions": []]
            case "profiles.list": return ["profiles": [["name": "fake", "canonical_session": nil], ["name": "other",
                                                         "canonical_session": ["id": "st-other"]]]]
            case "session.create": return ["session_id": "rt-new", "stored_session_id": "st-new", "messages": [], "info": [:]]
            case "session.title": return ["title": "Bot Chat", "pending": false]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        XCTAssertEqual(afterCapabilities(gw), ["session.list", "profiles.list", "session.create", "session.title"])
        XCTAssertEqual(params(gw, "session.create"), ["profile": "fake", "title": "Bot Chat", "hidden": true,
                                                      "follow_profile_config": true, "close_on_disconnect": false,
                                                      "source": "desktop", "cols": 100])
        XCTAssertEqual(params(gw, "session.title"), ["session_id": "rt-new", "title": "Bot Chat"])
        XCTAssertEqual(s.sessionId, "rt-new")
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertFalse(Parity.methods(gw).contains("prompt.submit"), "no kickoff prompt")
    }

    func testTitleInUseAdoptsTheWinner() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let lists = Collector<Int>()
        gw.responder = { m, _ in
            switch m {
            case "session.list": return lists.bump(1) == 1 ? ["sessions": []] : Self.found
            case "profiles.list": return ["profiles": [["name": "fake"]]]
            case "session.title":
                return ["__error": ["code": 4022, "message": "Title 'Bot Chat' is already in use by session st-root"]]
            case "session.resume": return Self.resumed
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        XCTAssertEqual(afterCapabilities(gw),
                       ["session.list", "profiles.list", "session.create", "session.title", "session.list", "session.resume"])
        XCTAssertEqual(s.sessionId, "rt-9", "the winner, not the stray lazy session")
        XCTAssertFalse(Parity.methods(gw).contains("session.close"), "the stray is abandoned, not closed")
    }

    func testConcurrentOpensShareOneFlight() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume": return Self.resumed
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        async let a = BotChatSession.openCanonical(backend, bot: Parity.bot)
        async let b = BotChatSession.openCanonical(backend, bot: Parity.bot)
        let (s1, s2) = try await (a, b)
        XCTAssertTrue(s1 === s2)
        XCTAssertEqual(Parity.methods(gw).filter { $0 == "session.resume" }.count, 1)
    }

    func testResumeRetriesOnceOnSettlingCodes() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let resumes = Collector<Int>()
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume":
                return resumes.bump(1) == 1 ? ["__error": ["code": 4009, "message": "session disconnect interrupt settling"]] : Self.resumed
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        XCTAssertEqual(s.sessionId, "rt-9")
        XCTAssertEqual(resumes.all.count, 2)
    }

    func testSessionNotOwnedIsTyped() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "session.list": return Self.found
            case "session.resume": return Self.resumed
            case "prompt.submit":
                return ["__error": ["code": 4090, "message": "session is active elsewhere", "data": ["reason": "SESSION_NOT_OWNED"]]]
            default: return Parity.defaults(m)
            }
        }
        let backend = try await Parity.backend(gw)
        defer { backend.client.close() }
        let s = try await BotChatSession.openCanonical(backend, bot: Parity.bot)
        do { try await s.send("hi"); XCTFail("sent") }
        catch let e as BotChatError {
            XCTAssertEqual(e, .sessionNotOwned(bot: "Fake"))
            XCTAssertTrue(Redaction.describe(e).contains("Open it in the Hermes app that runs it"))
        }
    }
}
