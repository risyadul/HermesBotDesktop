import Combine
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

@MainActor
final class ComposerIsolationTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!

    func testBotDraftPublishesOnlyToEditorsAndNotTranscriptSubscribers() {
        let model = ChatModel(bot: bot, opener: { _ in FakeChatLink() })
        let firstEditor = model.composerDraft
        let secondEditor = model.composerDraft
        var transcriptChanges = 0
        var editorChanges = 0
        let transcript = model.objectWillChange.sink { transcriptChanges += 1 }
        let editor = firstEditor.objectWillChange.sink { editorChanges += 1 }
        for i in 0..<100 { model.draft = "Typing \(i)" }
        XCTAssertEqual(transcriptChanges, 0)
        XCTAssertEqual(editorChanges, 100)
        XCTAssertTrue(firstEditor === secondEditor)
        XCTAssertEqual(secondEditor.text, "Typing 99")
        secondEditor.text = "Prefilled from another window"
        XCTAssertEqual(model.draft, "Prefilled from another window")
        withExtendedLifetime([transcript, editor]) {}
    }

    func testRoomDraftsAreSharedPerThreadWithoutInvalidatingRoomOrOtherEditors() {
        let model = RoomModel(room: RoomFixtures.room(), api: FakeRoomActions(rooms: [RoomFixtures.room()]))
        let main = model.draftStates.state(for: RoomThreads.main)
        let thread = model.draftStates.state(for: "thread-a")
        var roomChanges = 0
        var mainChanges = 0
        let roomSubscription = model.objectWillChange.sink { roomChanges += 1 }
        let mainSubscription = main.objectWillChange.sink { mainChanges += 1 }
        model.setDraft("reply", thread: "thread-a")
        XCTAssertEqual(thread.text, "reply")
        XCTAssertEqual(roomChanges, 0)
        XCTAssertEqual(mainChanges, 0)
        XCTAssertTrue(thread === model.draftStates.state(for: "thread-a"))
        model.drafts = [RoomThreads.main: "main text", "thread-a": "changed"]
        XCTAssertEqual(main.text, "main text")
        XCTAssertEqual(thread.text, "changed")
        XCTAssertEqual(roomChanges, 0)
        withExtendedLifetime([roomSubscription, mainSubscription]) {}
        model.shutdown()
    }

    func testPendingSaveIsCoalescedAndClearCannotBeResurrected() async throws {
        let name = "hba.tests.debounce.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChatDraftStore(defaults: defaults)
        let model = ChatModel(bot: bot, opener: { _ in FakeChatLink() }, drafts: store)
        model.draftPersistence?.delay = 10_000_000
        for i in 0..<100 { model.draft = "text \(i)" }
        XCTAssertEqual(store.draft(for: bot.name), "", "editing does not persist every character")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.draft(for: bot.name), "text 99")
        model.draft = "must never return"
        model.draft = ""
        XCTAssertEqual(store.draft(for: bot.name), "")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.draft(for: bot.name), "")
    }

    func testQueueEditAndCloseFlushOnlyOwnDraft() async throws {
        let name = "hba.tests.queue-draft.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChatDraftStore(defaults: defaults)
        let model = ChatModel(bot: bot, opener: { _ in FakeChatLink() }, drafts: store)
        model.draftPersistence?.delay = 10_000_000
        model.draft = "my unsent draft"
        model.queue = [QueuedMessage(text: "queued", attachments: [])]
        model.beginQueueEdit(model.queue[0].id)
        model.draft = "editing queued text"
        model.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.draft(for: bot.name), "my unsent draft")
        model.draft = "closed model must not schedule another save"
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.draft(for: bot.name), "my unsent draft")
    }

    func testFlushValidatesSecretAndOversizeDraftsAndCancelsOlderWrites() async throws {
        let name = "hba.tests.draft-rules.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChatDraftStore(defaults: defaults)
        let model = ChatModel(bot: bot, opener: { _ in FakeChatLink() }, drafts: store)
        model.draftPersistence?.delay = 10_000_000
        model.draft = "safe"
        model.flushDraft()
        XCTAssertEqual(store.draft(for: bot.name), "safe")
        model.draft = "Bearer abcdefghijklmnopqrstuvwxyz123456"
        model.flushDraft()
        XCTAssertEqual(store.draft(for: bot.name), "")
        model.draft = String(repeating: "a", count: ChatDraftStore.maxChars + 1)
        model.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.draft(for: bot.name), "")
    }
}
