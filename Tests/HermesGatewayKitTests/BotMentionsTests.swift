import XCTest
@testable import HermesGatewayKit

/// B1 mention resolution (parity with Desktop `data.ts` / the mention middleware) and B5 transcript
/// timestamps and turn durations.
final class BotMentionsTests: XCTestCase {
    private let alpha = Bot(["name": "alpha"])!
    private let research = Bot(["name": "research", "ui_meta": ["hermes-bots": ["title": "Research Buddy"]]])!
    private let primary = Bot(["name": "default", "display_name": "Hermes"])!
    private let writer = Bot(["name": "writer", "display_name": "Ink"])!
    private var roster: [Bot] { [alpha, research, primary, writer] }

    // MARK: forms and tags

    func testHandleIsTheProfileNameAndHermesForTheDefaultProfile() {
        XCTAssertEqual(BotMentions.handle(alpha), "alpha")
        XCTAssertEqual(BotMentions.handle(primary), "hermes")
    }

    func testNameFormsSlugAndCollapseWithoutReservedWords() {
        XCTAssertEqual(BotMentions.nameForms("Research Buddy"), ["research-buddy", "researchbuddy"])
        XCTAssertEqual(BotMentions.nameForms("  Ink "), ["ink"])
        XCTAssertEqual(BotMentions.nameForms("Hermes"), [], "a friendly name cannot claim @hermes")
        XCTAssertEqual(BotMentions.nameForms("All"), [])
        XCTAssertEqual(BotMentions.nameForms("!!!"), [])
        XCTAssertEqual(BotMentions.nameForms(nil), [])
    }

    func testTagPrefersTheFriendlySlugThenTheHandle() {
        XCTAssertEqual(BotMentions.tag(research), "research-buddy")
        XCTAssertEqual(BotMentions.tag(writer), "ink")
        XCTAssertEqual(BotMentions.tag(alpha), "alpha")
        XCTAssertEqual(BotMentions.tag(primary), "hermes", "the title Hermes is reserved: the handle is used")
    }

    // MARK: resolve

    func testResolvesHandlesNamesAndFriendlyFormsInOrderWithoutDuplicates() {
        let hit = BotMentions.resolve("@Ink and @research-buddy, then @alpha and @writer again", roster: roster, selfName: "zeta")
        XCTAssertEqual(hit.map(\.name), ["writer", "research", "alpha"])
        XCTAssertEqual(BotMentions.resolve("ask @hermes", roster: roster, selfName: "zeta").map(\.name), ["default"])
        XCTAssertEqual(BotMentions.resolve("ask @researchbuddy", roster: roster, selfName: "zeta").map(\.name), ["research"])
    }

    func testTheChatsOwnBotIsNeverResolved() {
        XCTAssertEqual(BotMentions.resolve("@alpha @ink", roster: roster, selfName: "alpha").map(\.name), ["writer"])
    }

    func testUnknownMentionsEmailsAndCodeAreIgnored() {
        let text = "mail me@alpha.dev, `@alpha` in code\n```\n@writer\n```\nand @nobody"
        XCTAssertEqual(BotMentions.resolve(text, roster: roster, selfName: "zeta"), [])
    }

    func testAFormTwoBotsShareResolvesToNeither() {
        let twin = Bot(["name": "ink"])!
        XCTAssertEqual(BotMentions.resolve("@ink", roster: [writer, twin], selfName: "zeta"), [],
                       "writer's friendly form `ink` collides with the profile `ink`")
        XCTAssertEqual(BotMentions.resolve("@writer", roster: [writer, twin], selfName: "zeta").map(\.name), ["writer"])
    }

    // MARK: note

    func testNoteNamesEachTaggedBotAndTellsTheModelToUseMessageAgent() throws {
        let note = try XCTUnwrap(BotMentions.note(for: [research, alpha]))
        XCTAssertTrue(note.hasPrefix(BotMentions.notePrefix))
        XCTAssertTrue(note.contains(#"@research = agent profile "research" ("Research Buddy"); @alpha = agent profile "alpha"."#))
        XCTAssertTrue(note.contains("message_agent tool"))
        XCTAssertTrue(note.contains("never forward the user\u{2019}s text verbatim"))
        XCTAssertTrue(note.hasSuffix("say so.]"))
        XCTAssertNil(BotMentions.note(for: []))
    }

    func testAnnotateAppendsTheNoteOnlyWhenABotIsTagged() {
        XCTAssertEqual(BotMentions.annotate("hello", roster: roster, selfName: "zeta"), "hello")
        XCTAssertEqual(BotMentions.annotate("hi @nobody", roster: roster, selfName: "zeta"), "hi @nobody")
        let out = BotMentions.annotate("ask @ink to draft", roster: roster, selfName: "zeta")
        XCTAssertTrue(out.hasPrefix("ask @ink to draft\n\n[@mentions resolved"))
        XCTAssertEqual(BotMentions.stripNote(out), "ask @ink to draft")
    }

    func testStripNoteLeavesOtherTextAlone() {
        XCTAssertEqual(BotMentions.stripNote("plain [text]"), "plain [text]")
        XCTAssertEqual(BotMentions.stripNote("no note"), "no note")
    }

    // MARK: transcript (B1 history, B5)

    func testHistoryTimestampsAreDecodedAndMentionNotesStripped() {
        let annotated = BotMentions.annotate("ask @ink", roster: roster, selfName: "zeta")
        let history = ChatHistoryMessage.decode([
            ["role": "user", "text": .string(annotated), "timestamp": .number(1_700_000_000.5)],
            ["role": "assistant", "text": "done", "timestamp": 1_700_000_010],
            ["role": "assistant", "text": "no stamp"],
            ["role": "assistant", "text": "bad stamp", "timestamp": -1],
        ])
        XCTAssertEqual(history[0].timestamp, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertNil(history[2].timestamp)
        XCTAssertNil(history[3].timestamp)
        var t = ChatTranscript()
        t.seed(history: history)
        XCTAssertEqual(t.lines[0].text, "ask @ink", "the note sent to the model is not shown as the user's words")
        XCTAssertEqual(t.lines[1].at, Date(timeIntervalSince1970: 1_700_000_010))
        XCTAssertNil(t.lines[2].at)
        XCTAssertNil(t.lines[1].turnDuration, "history carries no turn duration")
    }

    func testALocalTurnStampsItsReplyWithCompletionTimeAndDuration() throws {
        var t = ChatTranscript()
        let before = Date()
        _ = t.beginTurn("hi")
        XCTAssertNotNil(t.lines[0].at)
        t.apply(.started)
        t.apply(.delta("Hel"))
        t.apply(.completed(ChatCompletion(text: "Hello")))
        let reply = try XCTUnwrap(t.lines.last)
        XCTAssertEqual(reply.role, .bot)
        XCTAssertEqual(reply.turnDuration, 1, "a turn under a second still reads 1s, like Desktop")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reply.at), before)
    }

    func testTheDurationGoesOnTheLastReplyTextOfTheTurn() {
        var t = ChatTranscript()
        _ = t.beginTurn("hi")
        t.apply(.interim("First part", alreadyStreamed: false))
        t.apply(.toolStarted(ToolStart(toolId: "t1", name: "terminal")))
        t.apply(.completed(ChatCompletion(text: "Second part")))
        let replies = t.lines.filter { $0.role == .bot }
        XCTAssertEqual(replies.map(\.text), ["First part", "Second part"])
        XCTAssertNil(replies[0].turnDuration)
        XCTAssertNotNil(replies[1].turnDuration)
    }

    func testARemoteTurnIsTimedFromItsFirstEventButAJoinedTurnIsNot() {
        var remote = ChatTranscript()
        remote.apply(.delta("from Desktop"))
        remote.apply(.completed(ChatCompletion(text: "from Desktop")))
        XCTAssertNotNil(remote.lines.last?.turnDuration)

        var joined = ChatTranscript()
        joined.resumeRunningTurn(InflightTurn(user: "q", assistant: "partial"))
        joined.apply(.completed(ChatCompletion(text: "partial and the rest")))
        XCTAssertNil(joined.lines.last?.turnDuration, "the start of a joined turn was never seen here")
        XCTAssertNotNil(joined.lines.last?.at)
    }

    func testAJoinedTurnShowsTheUsersWordsWithoutTheNote() {
        var t = ChatTranscript()
        t.resumeRunningTurn(InflightTurn(user: BotMentions.annotate("ask @ink", roster: roster, selfName: "zeta"), assistant: ""))
        XCTAssertEqual(t.lines.first?.text, "ask @ink")
    }
}
