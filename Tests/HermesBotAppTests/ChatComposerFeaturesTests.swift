import AppKit
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B1 (@mentions: autocomplete, the note on every send path, nothing sent to the tagged bot), B12 (prompt
/// history, per-bot drafts). Headless, FakeChatLink only: no prompt reaches a real bot.
@MainActor
final class ChatComposerFeaturesTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!
    private let ink = Bot(["name": "writer", "display_name": "Ink"])!
    private let alpha = Bot(["name": "alpha"])!
    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "hba.tests.drafts.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func ready(_ link: FakeChatLink, drafts: ChatDraftStore? = nil) async throws -> ChatModel {
        let m = ChatModel(bot: bot, opener: { _ in link }, drafts: drafts)
        m.log = { _ in }
        m.drainFallbackDelay = 10_000_000
        let roster = [bot, ink, alpha]
        m.roster = { roster }
        m.open()
        try await waitUntil { m.isReady }
        return m
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sends(_ link: FakeChatLink) -> [String] { link.calls.filter { $0.hasPrefix("send:") } }

    // MARK: B1 mention note on send

    func testSubmitAppendsTheMentionNoteForTheModelButShowsTheTypedText() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "ask @ink to draft the notes"
        XCTAssertTrue(m.submit())
        XCTAssertEqual(m.lines.last?.text, "ask @ink to draft the notes", "the user line is what was typed")
        try await waitUntil { !self.sends(link).isEmpty }
        let sent = try XCTUnwrap(sends(link).first)
        XCTAssertTrue(sent.hasPrefix("send:ask @ink to draft the notes\n\n[@mentions resolved from the Bot Mode roster"))
        XCTAssertTrue(sent.contains(#"@writer = agent profile "writer" ("Ink")"#))
        XCTAssertTrue(sent.contains("message_agent"))
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("send:") }.count, 1, "nothing is sent to the tagged bot by the app")
    }

    func testAPromptWithoutARosterMentionIsSentUnchanged() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "email me@alpha.dev or ask @fake or @nobody"
        XCTAssertTrue(m.submit())
        try await waitUntil { !self.sends(link).isEmpty }
        XCTAssertEqual(sends(link), ["send:email me@alpha.dev or ask @fake or @nobody|"], "self and unknown tags add no note")
    }

    func testSteerAndQueuedSendsCarryTheNoteToo() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        m.draft = "start"
        XCTAssertTrue(m.submit())
        m.draft = "loop in @alpha"
        XCTAssertEqual(m.composerAction, .steer)
        XCTAssertTrue(m.primaryAction())
        try await waitUntil { link.calls.contains { $0.hasPrefix("redirect:") } }
        let redirect = try XCTUnwrap(link.calls.first { $0.hasPrefix("redirect:") })
        XCTAssertTrue(redirect.hasPrefix("redirect:loop in @alpha\n\n[@mentions resolved"))
        XCTAssertTrue(m.lines.contains { $0.role == .user && $0.text == "loop in @alpha" })

        m.draft = "then @ink"
        XCTAssertTrue(m.queueOrSend())
        XCTAssertEqual(m.queue.first?.text, "then @ink", "the queue keeps the typed text")
        link.emit(.completed(ChatCompletion(text: "done")))
        try await waitUntil { self.sends(link).count == 2 }
        XCTAssertTrue(sends(link)[1].hasPrefix("send:then @ink\n\n[@mentions resolved"))
    }

    // MARK: B1 autocomplete

    func testCompletionOffersRosterBotsButNotTheChatsOwnBot() async throws {
        let m = try await ready(FakeChatLink())
        XCTAssertEqual(m.mentionCandidates.map(\.name), ["writer", "alpha"])
        XCTAssertEqual(BotMentionCompletion.matches("hey @", candidates: m.mentionCandidates).map(\.name), ["writer", "alpha"])
        XCTAssertEqual(BotMentionCompletion.matches("hey @in", candidates: m.mentionCandidates).map(\.name), ["writer"])
        XCTAssertEqual(BotMentionCompletion.matches("hey @wri", candidates: m.mentionCandidates).map(\.name), ["writer"],
                       "the profile name matches too")
        XCTAssertEqual(BotMentionCompletion.matches("hey @fa", candidates: m.mentionCandidates), [])
        XCTAssertEqual(BotMentionCompletion.matches("mail a@in", candidates: m.mentionCandidates), [], "mid-word @ is not a mention")
        XCTAssertEqual(BotMentionCompletion.matches("@ink done", candidates: m.mentionCandidates), [], "only a trailing @word")
        XCTAssertTrue(m.mentionHandles.isSuperset(of: ["ink", "writer", "alpha"]))
        XCTAssertFalse(m.mentionHandles.contains("fake"))
    }

    func testInsertReplacesTheTrailingQueryWithTheTag() {
        var draft = "please ask @in"
        BotMentionCompletion.insert(ink, candidates: [ink, alpha], into: &draft)
        XCTAssertEqual(draft, "please ask @ink ")
        var bare = "@"
        BotMentionCompletion.insert(alpha, candidates: [ink, alpha], into: &bare)
        XCTAssertEqual(bare, "@alpha ")
    }

    func testASharedTagInsertsTheHandleInstead() {
        let twin = Bot(["name": "ink"])!
        XCTAssertEqual(BotMentionCompletion.insertion(ink, candidates: [ink, twin]), "writer")
        XCTAssertEqual(BotMentionCompletion.insertion(ink, candidates: [ink, alpha]), "ink")
    }

    func testCompletionIsCappedAtEight() {
        let many = (0..<12).map { Bot(["name": .string("bot\($0)")])! }
        XCTAssertEqual(BotMentionCompletion.matches("@bot", candidates: many).count, BotMentionCompletion.limit)
    }

    // MARK: B12 prompt history

    func testHistoryRingIsTheUsersMessagesNewestFirst() {
        var t = ChatTranscript()
        t.seed(history: [
            ChatHistoryMessage(role: .user, text: "first"),
            ChatHistoryMessage(role: .assistant, text: "ok"),
            ChatHistoryMessage(role: .user, text: "[System: background job finished]"),
            ChatHistoryMessage(role: .user, text: "second\n\nAttached: a.png"),
            ChatHistoryMessage(role: .user, text: "Attached: b.png"),
            ChatHistoryMessage(role: .user, text: "second"),
        ])
        XCTAssertEqual(PromptHistory.ring(t.lines), ["second", "first"],
                       "notices and file-only rows are skipped, attachment lists dropped, repeats folded")
    }

    func testUpRecallsOlderMessagesAndDownComesBackToTheDraft() async throws {
        let link = FakeChatLink(history: [
            ChatHistoryMessage(role: .user, text: "one"), ChatHistoryMessage(role: .assistant, text: "a"),
            ChatHistoryMessage(role: .user, text: "two"), ChatHistoryMessage(role: .assistant, text: "b"),
        ])
        let m = try await ready(link)
        m.draft = "half typed"
        XCTAssertTrue(m.recallOlder())
        XCTAssertEqual(m.draft, "two")
        XCTAssertTrue(m.recallOlder())
        XCTAssertEqual(m.draft, "one")
        XCTAssertFalse(m.recallOlder(), "the oldest message stays")
        XCTAssertEqual(m.draft, "one")
        XCTAssertTrue(m.recallNewer())
        XCTAssertEqual(m.draft, "two")
        XCTAssertTrue(m.recallNewer())
        XCTAssertEqual(m.draft, "half typed", "past the newest, the draft from before comes back")
        XCTAssertFalse(m.recallNewer(), "↓ does nothing when not browsing")
    }

    func testEditingARecalledMessageEndsBrowsing() async throws {
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "one"), ChatHistoryMessage(role: .user, text: "two")])
        let m = try await ready(link)
        XCTAssertTrue(m.recallOlder())
        m.draft = "two, edited"
        XCTAssertFalse(m.recallNewer(), "an edited recall is the user's text now")
        XCTAssertEqual(m.draft, "two, edited")
        XCTAssertTrue(m.recallOlder())
        XCTAssertEqual(m.draft, "two", "↑ starts again from the newest, keeping the edit to come back to")
        XCTAssertTrue(m.recallNewer())
        XCTAssertEqual(m.draft, "two, edited")
    }

    func testSentMessagesJoinTheHistory() async throws {
        let link = FakeChatLink()
        let m = try await ready(link)
        XCTAssertFalse(m.recallOlder(), "no history yet")
        m.draft = "hello there"
        XCTAssertTrue(m.submit())
        link.emit(.completed(ChatCompletion(text: "hi")))
        try await waitUntil { !m.busy }
        XCTAssertTrue(m.recallOlder())
        XCTAssertEqual(m.draft, "hello there")
    }

    func testHistoryIsOffWhileAQueuedMessageIsEdited() async throws {
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "one")])
        let m = try await ready(link)
        m.queue = [QueuedMessage(text: "queued", attachments: [])]
        m.queueParked = true
        m.beginQueueEdit(m.queue[0].id)
        XCTAssertFalse(m.recallOlder())
        XCTAssertEqual(m.draft, "queued")
    }

    func testCaretRule() {
        XCTAssertTrue(PromptHistory.caretAllows(up: true, caret: NSRange(location: 0, length: 0), length: 5))
        XCTAssertFalse(PromptHistory.caretAllows(up: true, caret: NSRange(location: 2, length: 0), length: 5))
        XCTAssertFalse(PromptHistory.caretAllows(up: true, caret: NSRange(location: 0, length: 3), length: 5), "a selection is not a caret")
        XCTAssertTrue(PromptHistory.caretAllows(up: false, caret: NSRange(location: 5, length: 0), length: 5))
        XCTAssertFalse(PromptHistory.caretAllows(up: false, caret: NSRange(location: 4, length: 0), length: 5))
        XCTAssertTrue(PromptHistory.caretAllows(up: true, caret: NSRange(location: 0, length: 0), length: 0))
        XCTAssertTrue(PromptHistory.caretAllows(up: false, caret: NSRange(location: 0, length: 0), length: 0))
    }

    // MARK: B12 drafts

    func testDraftsPersistPerBotAcrossModels() async throws {
        let store = ChatDraftStore(defaults: suite)
        let m = try await ready(FakeChatLink(), drafts: store)
        m.draft = "unsent thought"
        XCTAssertEqual(store.draft(for: "fake"), "unsent thought")
        XCTAssertEqual(store.draft(for: "writer"), "", "drafts are per bot")
        let relaunched = ChatModel(bot: bot, opener: { _ in FakeChatLink() }, drafts: store)
        XCTAssertEqual(relaunched.draft, "unsent thought", "the next launch starts with the draft")
    }

    func testSendingClearsTheSavedDraft() async throws {
        let store = ChatDraftStore(defaults: suite)
        let m = try await ready(FakeChatLink(), drafts: store)
        m.draft = "go"
        XCTAssertTrue(m.submit())
        XCTAssertEqual(store.draft(for: "fake"), "")
        XCTAssertNil((suite.dictionary(forKey: ChatDraftStore.key) as? [String: Any])?["fake"], "a blank draft is removed")
    }

    func testAQueuedMessageBeingEditedIsNotSavedAsTheDraft() async throws {
        let store = ChatDraftStore(defaults: suite)
        let m = try await ready(FakeChatLink(), drafts: store)
        m.draft = "mine"
        m.queue = [QueuedMessage(text: "queued text", attachments: [])]
        m.queueParked = true
        m.beginQueueEdit(m.queue[0].id)
        m.draft = "queued text, edited"
        XCTAssertEqual(store.draft(for: "fake"), "mine")
        m.cancelQueueEdit()
        XCTAssertEqual(m.draft, "mine")
        XCTAssertEqual(store.draft(for: "fake"), "mine")
    }

    func testDraftsAreSizeCapped() {
        let store = ChatDraftStore(defaults: suite)
        store.save("short", for: "a")
        store.save(String(repeating: "x", count: ChatDraftStore.maxChars + 1), for: "a")
        XCTAssertEqual(store.draft(for: "a"), "", "an oversized draft is not kept (and replaces the older one)")
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<(ChatDraftStore.maxBots + 3) {
            store.save("draft \(i)", for: "bot\(i)", now: start.addingTimeInterval(Double(i)))
        }
        let kept = suite.dictionary(forKey: ChatDraftStore.key) ?? [:]
        XCTAssertEqual(kept.count, ChatDraftStore.maxBots)
        XCTAssertEqual(store.draft(for: "bot0"), "", "the least recently edited drafts go first")
        XCTAssertEqual(store.draft(for: "bot\(ChatDraftStore.maxBots + 2)"), "draft \(ChatDraftStore.maxBots + 2)")
    }

    func testTheAppStoreIsOffUnderTests() {
        XCTAssertNil(ChatDraftStore.app, "tests never write the real defaults")
    }
}
