import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Long histories must not be reformatted because a composer, sidebar or inspector invalidates the view.
/// These checks count actual snapshot reuse, rather than setting timing thresholds sensitive to the Mac.
@MainActor
final class TranscriptPresentationCacheTests: XCTestCase {
    private func chat() -> ChatModel {
        let model = ChatModel(bot: Bot(["name": "fake", "display_name": "Fake"])!, opener: { _ in FakeChatLink() })
        model.log = { _ in }
        model.transcript.seed(history: Self.history())
        return model
    }

    private static func history() -> [ChatHistoryMessage] {
        (0..<250).flatMap { turn in
            [ChatHistoryMessage(role: .user, text: "Review step \(turn): the long conversation must stay scrollable."),
             ChatHistoryMessage(role: .assistant, text: "## Step \(turn)\n\nInvestigating the source and preserving the existing behavior."),
             ChatHistoryMessage(role: .tool, text: "", toolName: "read_file", toolContext: "Read Sources/Example.swift"),
             ChatHistoryMessage(role: .tool, text: "", toolName: "terminal", toolContext: "Run regression tests"),
             ChatHistoryMessage(role: .assistant, text: "| Check | Result |\n| --- | --- |\n| Scroll | Stable |\n\n```swift\nlet step = \(turn)\n```",
                                reasoning: "Check the row identity, its content and its layout.")]
        }
    }

    func testLongBotHistoryReusesSnapshotForComposerAndPanelChanges() {
        let model = chat()
        let original = model.presentation
        XCTAssertGreaterThan(original.items.count, 1_000)
        XCTAssertFalse(original.fullResponses.isEmpty)
        XCTAssertTrue(original.items.contains { if case .tools = $0 { return true }; return false })

        model.draft = "Typing in the composer"
        model.routinesShown = true
        model.modelPickerShown = true
        for _ in 0..<100 { XCTAssertTrue(model.presentation === original) }

        let start = Date.timeIntervalSinceReferenceDate
        var count = 0
        for _ in 0..<20 { count += BotTranscriptPresentation(lines: model.lines, busy: model.busy).items.count }
        let rebuilt = Date.timeIntervalSinceReferenceDate - start
        let cachedStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<20 { count -= model.presentation.items.count }
        let cached = Date.timeIntervalSinceReferenceDate - cachedStart
        XCTAssertEqual(count, 0)
        print(String(format: "Presentation cache diagnostic: Bot Chat (%d items), 20 rebuilds %.3f ms, 20 cached accesses %.3f ms",
                     original.items.count, rebuilt * 1_000, cached * 1_000))
    }

    func testStreamingContentChangeInvalidatesSnapshotWithoutMovingTailRows() {
        let model = chat()
        XCTAssertNotNil(model.transcript.beginTurn("Keep investigating"))
        model.transcript.apply(.started)
        model.transcript.apply(.delta("Short first token"))
        let original = model.presentation
        let ids = original.items.map(\.id)

        model.transcript.apply(.delta(String(repeating: "\nA longer streamed paragraph.", count: 150)))
        let updated = model.presentation
        XCTAssertFalse(updated === original)
        XCTAssertEqual(updated.items.map(\.id), ids, "text changed without inserting/removing rows")
        XCTAssertNotEqual(updated.items.last, original.items.last)
        XCTAssertEqual(updated.tailStart, original.tailStart, "streaming must not reparent existing rows between lazy and eager stacks")
        XCTAssertTrue(model.presentation === updated)
    }

    func testFinishingTurnRefreshesChangedFileCardsEvenWithoutNewRows() {
        let model = chat()
        XCTAssertNotNil(model.transcript.beginTurn("Update the file"))
        model.transcript.apply(.toolStarted(ToolStart(toolId: "edit-1", name: "edit_file", args: ["path": "Example.swift"])))
        model.transcript.apply(.toolCompleted(ToolCompletion(toolId: "edit-1", name: "edit_file", inlineDiff: "-old\n+new")))
        let running = model.presentation
        let count = model.lines.count
        XCTAssertTrue(running.changedFiles.isEmpty, "the current turn is not finished")

        model.transcript.apply(.completed(ChatCompletion(text: nil)))
        let finished = model.presentation
        XCTAssertEqual(model.lines.count, count)
        XCTAssertFalse(finished === running)
        XCTAssertEqual(finished.changedFiles.values.flatMap { $0 }.map(\.path), ["Example.swift"])
        XCTAssertEqual(finished.lastID, finished.items.last?.id)
    }

    private static func roomEvents() -> [RoomEvent] {
        (1...1_200).map { seq in
            switch seq % 3 {
            case 1: return RoomFixtures.user(seq, "Review discussion \(seq)")
            case 2:
                let thread = seq % 5 == 0 ? RoomThreads.anchored(at: seq - 1) : RoomThreads.main
                return RoomFixtures.member(seq, "alpha", "## Result \(seq)\n\nThe thread remains readable while resizing the window.", thread: thread)
            default: return RoomFixtures.settled(seq, disc: "user:\(seq - 2)")
            }
        }
    }

    private func poll(_ model: RoomModel) async {
        let before = model.pollCount
        model.start()
        model.nudge()
        await eventually { model.pollCount > before }
        model.stopPolling()
    }

    func testLongRoomHistoryReusesSnapshotOnUnchangedPollAndRefreshesNewEvents() async {
        let room = RoomFixtures.room()
        let api = FakeRoomActions(rooms: [room])
        let events = Self.roomEvents()
        api.setEvents(room.roomId, events)
        let model = RoomModel(room: room, api: api)
        defer { model.shutdown() }
        await poll(model)
        let original = model.presentation
        XCTAssertEqual(original.rows.count, 1_200)
        XCTAssertFalse(original.threads.isEmpty)
        model.drafts[RoomThreads.main] = "Draft while reading older history"
        api.setDriver(room.roomId, RoomDriverStatus(working: false, counts: ["queued": 0]))
        await poll(model)
        XCTAssertTrue(model.presentation === original, "a status poll with no new events must keep the history indexes")
        for _ in 0..<100 { XCTAssertTrue(model.presentation === original) }

        let start = Date.timeIntervalSinceReferenceDate
        var count = 0
        for _ in 0..<20 { count += RoomTranscriptPresentation(timeline: model.timeline, room: model.room).rows.count }
        let rebuilt = Date.timeIntervalSinceReferenceDate - start
        let cachedStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<20 { count -= model.presentation.rows.count }
        let cached = Date.timeIntervalSinceReferenceDate - cachedStart
        XCTAssertEqual(count, 0)
        print(String(format: "Presentation cache diagnostic: Group Chat (%d rows), 20 rebuilds %.3f ms, 20 cached accesses %.3f ms",
                     original.rows.count, rebuilt * 1_000, cached * 1_000))

        api.setEvents(room.roomId, events + [RoomFixtures.user(1_201, "A new message")])
        await poll(model)
        XCTAssertFalse(model.presentation === original)
        XCTAssertEqual(model.presentation.rows.last?.id, 1_201)
        XCTAssertEqual(model.lines.last?.text, "A new message")
    }

    func testRoomRosterChangeRefreshesFallbackAuthorButMetadataDoesNotRebuildHistory() async {
        let room = RoomFixtures.room()
        let api = FakeRoomActions(rooms: [room])
        api.setEvents(room.roomId, [RoomFixtures.member(1, "alpha")])
        let model = RoomModel(room: room, api: api)
        defer { model.shutdown() }
        await poll(model)
        let original = model.presentation
        XCTAssertEqual(original.lines.first?.author, "Alpha")

        api.setRooms([RoomFixtures.room(name: "New room name", latestSeq: 1, revision: 2)])
        await poll(model)
        XCTAssertEqual(model.room.name, "New room name")
        XCTAssertTrue(model.presentation === original, "room name/revision metadata does not change message authors")

        let renamedMember = RoomSummary([
            "room_id": .string(room.roomId), "name": "New room name", "revision": 3,
            "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Renamed Alpha"],
                        ["member_id": "beta", "profile": "beta", "handle": "beta"]],
        ])!
        api.setRooms([renamedMember])
        await poll(model)
        XCTAssertFalse(model.presentation === original)
        XCTAssertEqual(model.lines.first?.author, "Renamed Alpha")
    }
}
