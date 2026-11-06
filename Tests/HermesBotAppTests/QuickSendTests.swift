import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A `QuickSender` over in-memory chats (`FakeChatLink`) and rooms (`FakeRoomActions`): no gateway, no real
/// prompt or room message ever goes out. Shared by the macOS integration tests (D3, D4, D6, D7, D12).
@MainActor
final class QuickSendFixture {
    let bots = [Bot(["name": "alpha", "display_name": "Alpha"])!, Bot(["name": "beta", "display_name": "Beta"])!]
    var links: [String: FakeChatLink] = [:]
    var chats: [String: ChatModel] = [:]
    let rooms: FakeRoomActions
    var connected = true
    var nudged: [String] = []

    init(rooms: [RoomSummary] = [RoomFixtures.room()]) {
        self.rooms = FakeRoomActions(rooms: rooms)
        for bot in bots { links[bot.name] = FakeChatLink() }
    }

    func link(_ name: String) -> FakeChatLink { links[name]! }

    func chat(_ bot: Bot) -> ChatModel {
        if let c = chats[bot.name] { return c }
        let link = links[bot.name]!
        let c = ChatModel(bot: bot, opener: { _ in link })
        c.log = { _ in }
        chats[bot.name] = c
        return c
    }

    var roomList: [RoomSummary] = [RoomFixtures.room()]

    var sender: QuickSender {
        var s = QuickSender(connected: { [unowned self] in connected }, bots: { [unowned self] in connected ? bots : [] },
                            rooms: { [unowned self] in roomList }, chat: { [unowned self] in chat($0) },
                            roomActions: { [unowned self] in rooms }, roomSent: { [unowned self] in nudged.append($0) })
        s.step = 5_000_000
        s.openTimeout = 2
        return s
    }

    /// The fake bot answers the running turn with `text`.
    func reply(_ bot: String, _ text: String) {
        link(bot).emit(.delta(text))
        link(bot).emit(.completed(ChatCompletion(text: text)))
    }

    /// Sent prompts of one bot (`send:<text>|<files>` calls of its link).
    func sent(_ bot: String) -> [String] { link(bot).calls.filter { $0.hasPrefix("send:") } }
}

@MainActor
final class QuickSendTests: XCTestCase {
    // MARK: QuickReply (pure)

    private func lines(_ roles: [(ChatLine.Role, String)]) -> [ChatLine] { roles.map { ChatLine(role: $0.0, text: $0.1) } }

    func testReplyStateFollowsTheTurnAfterItsUserLine() {
        let base = lines([(.user, "old"), (.bot, "old reply"), (.user, "new")])
        let id = base[2].id
        XCTAssertEqual(QuickReply.state(lines: base, after: id, busy: true), .waiting, "the previous reply is not this one")
        let streaming = base + lines([(.tool, "search"), (.bot, "partial")])
        XCTAssertEqual(QuickReply.state(lines: streaming, after: id, busy: true), .streaming("partial"))
        let done = base + lines([(.bot, "first"), (.tool, "x"), (.bot, "second")])
        XCTAssertEqual(QuickReply.state(lines: done, after: id, busy: false), .done("first\n\nsecond"))
        let failed = base + lines([(.error, "quota exceeded")])
        XCTAssertEqual(QuickReply.state(lines: failed, after: id, busy: false), .failed("quota exceeded"))
        let next = done + lines([(.user, "another"), (.bot, "not ours")])
        XCTAssertEqual(QuickReply.state(lines: next, after: id, busy: true), .done("first\n\nsecond"),
                       "a later message in the chat starts another turn: ours is over")
        XCTAssertEqual(QuickReply.state(lines: base, after: UUID(), busy: false), .failed("The message did not go out."))
    }

    // MARK: Bot Chat

    func testSendOpensTheChatAndSubmitsWithoutTouchingTheComposer() async throws {
        let f = QuickSendFixture()
        let chat = f.chat(f.bots[0])
        chat.draft = "half-typed"
        let turn = try await f.sender.send("  what's new?  ", toBot: "alpha")
        XCTAssertTrue(chat.isReady, "sending opens (resumes) the Bot Chat")
        await eventually { f.sent("alpha") == ["send:what's new?|"] }
        XCTAssertEqual(chat.draft, "half-typed", "the composer draft stays")
        XCTAssertEqual(chat.lines.first { $0.id == turn.userLine }?.text, "what's new?")
        XCTAssertTrue(f.sent("beta").isEmpty)
    }

    func testReplyReturnsTheTurnsText() async throws {
        let f = QuickSendFixture()
        let s = f.sender
        let turn = try await s.send("hi", toBot: "alpha")
        await eventually { !f.sent("alpha").isEmpty }
        f.reply("alpha", "hello there")
        let reply = try await s.reply(turn, timeout: 5)
        XCTAssertEqual(reply, "hello there")
    }

    func testReplyTimesOutWhileTheTurnRuns() async throws {
        let f = QuickSendFixture()
        let s = f.sender
        let turn = try await s.send("hi", toBot: "alpha")
        do {
            _ = try await s.reply(turn, timeout: 0.1)
            XCTFail("no reply arrived")
        } catch let e as QuickSendError {
            XCTAssertEqual(e, .timedOut("Alpha"))
        }
        XCTAssertTrue(turn.chat.busy, "the turn keeps running in the Bot Chat")
    }

    func testSendRefusedWhileAReplyRunsAndForUnknownBotsOrOffline() async throws {
        let f = QuickSendFixture()
        let s = f.sender
        _ = try await s.send("one", toBot: "alpha")
        await XCTAssertThrowsQuick(.busy("Alpha")) { _ = try await s.send("two", toBot: "alpha") }
        await XCTAssertThrowsQuick(.unknownBot("zeta")) { _ = try await s.send("hi", toBot: "zeta") }
        await XCTAssertThrowsQuick(.empty) { _ = try await s.send("   ", toBot: "beta") }
        f.connected = false
        await XCTAssertThrowsQuick(.notConnected) { _ = try await s.send("hi", toBot: "beta") }
        await eventually { f.sent("alpha").count == 1 }
        XCTAssertEqual(f.sent("alpha"), ["send:one|"], "only the first went out")
        XCTAssertTrue(f.sent("beta").isEmpty)
    }

    func testFailedOpenIsReported() async throws {
        let f = QuickSendFixture()
        var s = f.sender
        s.chat = { bot in
            let c = ChatModel(bot: bot, opener: { _ in throw GatewayClient.ClientError.notConnected })
            c.log = { _ in }
            return c
        }
        do {
            _ = try await s.send("hi", toBot: "alpha")
            XCTFail("the chat cannot open")
        } catch let e as QuickSendError {
            guard case .failed = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: rooms

    func testRoomSendPostsOnMainAndNudgesTheRoom() async throws {
        let f = QuickSendFixture()
        try await f.sender.send(" status? ", toRoom: "hba-test-0")
        XCTAssertEqual(f.rooms.sends.map(\.text), ["status?"])
        XCTAssertEqual(f.rooms.sends.map(\.thread), [RoomThreads.main])
        XCTAssertEqual(f.nudged, ["hba-test-0"])
    }

    func testRoomSendRefusals() async throws {
        let f = QuickSendFixture()
        let s = f.sender
        await XCTAssertThrowsQuick(.unknownRoom("nope")) { try await s.send("hi", toRoom: "nope") }
        await XCTAssertThrowsQuick(.tooLong) {
            try await s.send(String(repeating: "x", count: RoomComposer.maxTextBytes + 1), toRoom: "hba-test-0")
        }
        f.rooms.failSend(GatewayClient.RPCError(code: 4100, message: "boom", data: nil))
        do {
            try await s.send("hi", toRoom: "hba-test-0")
            XCTFail("the send failed")
        } catch let e as QuickSendError {
            guard case .failed(let why) = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(why.contains("may not have been posted"))
        }
        XCTAssertTrue(f.nudged.isEmpty)
    }

    // MARK: prefill (Services "Open in Composer")

    func testPrefillAppendsToTheDraftAndNeverSends() async throws {
        let f = QuickSendFixture()
        let chat = f.chat(f.bots[1])
        chat.checkFile = { ChatAttachments.Checked(url: $0, name: $0.lastPathComponent, kind: .file, bytes: 1) }
        chat.draft = "note:"
        try await f.sender.prefill(.bot("beta"), text: "selected text", files: [URL(fileURLWithPath: "/tmp/a.txt")],
                                   roomModel: { _ in nil })
        XCTAssertEqual(chat.draft, "note:\n\nselected text")
        XCTAssertEqual(chat.pending.map(\.name), ["a.txt"])
        XCTAssertTrue(f.sent("beta").isEmpty, "nothing is sent")

        let room = RoomModel(room: RoomFixtures.room(), api: f.rooms)
        try await f.sender.prefill(.room("hba-test-0"), text: "for the room", files: [], roomModel: { _ in room })
        XCTAssertEqual(room.drafts[RoomThreads.main], "for the room")
        XCTAssertTrue(f.rooms.sends.isEmpty)
        XCTAssertEqual(QuickSender.appending("b", to: "  "), "b")
    }
}

/// Asserts that `body` throws exactly `expected`.
@MainActor
func XCTAssertThrowsQuick(_ expected: QuickSendError, file: StaticString = #filePath, line: UInt = #line,
                          _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let e as QuickSendError {
        XCTAssertEqual(e, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}
