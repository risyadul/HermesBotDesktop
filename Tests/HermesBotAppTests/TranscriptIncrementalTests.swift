import Combine
import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

@MainActor
final class TranscriptIncrementalTests: XCTestCase {
    private func model(turns: Int = 100) -> ChatModel {
        let model = ChatModel(bot: Bot(["name": "fake", "display_name": "Fake"])!, opener: { _ in FakeChatLink() })
        model.log = { _ in }
        model.transcript.seed(history: (0..<turns).flatMap { turn in
            [ChatHistoryMessage(role: .user, text: "Question \(turn)"),
             ChatHistoryMessage(role: .assistant, text: "First answer \(turn)"),
             ChatHistoryMessage(role: .tool, text: "", toolName: "read_file", toolContext: "Read source"),
             ChatHistoryMessage(role: .assistant, text: "Final answer \(turn)")]
        })
        return model
    }

    private func assertMatchesFresh(_ model: ChatModel, file: StaticString = #filePath, line: UInt = #line) {
        let actual = model.presentation
        let expectedItems = TranscriptItem.build(model.lines)
        XCTAssertEqual(Array(actual.items), expectedItems, file: file, line: line)
        let expectedGaps = TranscriptItem.gaps(expectedItems)
        let expectedFull = ChatCopy.fullResponses(model.lines)
        let expectedChanged = ChangedFiles.cards(model.lines, busy: model.busy)
        for item in expectedItems {
            XCTAssertEqual(actual.gaps[item.id], expectedGaps[item.id], file: file, line: line)
        }
        for row in model.lines {
            XCTAssertEqual(actual.fullResponses[row.id], expectedFull[row.id], file: file, line: line)
            XCTAssertEqual(actual.changedFiles[row.id], expectedChanged[row.id], file: file, line: line)
        }
    }

    func testMetadataEventsKeepPresentationAndDoNotPublishTranscript() {
        let model = model()
        let original = model.presentation
        var publications = 0
        let subscription = model.$transcript.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        model.apply(.status(kind: "working", text: "Working"))
        model.apply(.other("heartbeat"))
        model.apply(.requestCancelled(id: "missing", reason: "cancelled"))
        model.apply(.approvalsCancelled(requestIds: []))
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(model.presentation === original)
    }

    func testDraftingToolUpdatesComposerStatusWithoutRebuildingHistory() {
        let model = model()
        let original = model.presentation
        model.apply(.toolGenerating(name: "terminal"))
        XCTAssertEqual(model.transcript.draftingTool, "terminal")
        XCTAssertTrue(model.presentation === original)
    }

    func testStreamingReusesCompletedTurnsAndMatchesFreshDerivations() {
        let model = model()
        XCTAssertNotNil(model.transcript.beginTurn("New question"))
        model.apply(.started)
        let before = model.presentation
        let frozenHistory = before.history
        XCTAssertGreaterThan(frozenHistory.items.count, 300)
        for i in 0..<30 {
            model.apply(.delta(" token\(i)"))
            XCTAssertTrue(model.presentation.history === frozenHistory)
            assertMatchesFresh(model)
        }
        XCTAssertEqual(before.items.last?.id, model.presentation.items.last?.id)
        if case .line(let originalLine, _) = before.items.last {
            XCTAssertEqual(originalLine.text, "", "a later delta must not mutate an earlier snapshot")
        } else {
            XCTFail("expected the initially empty streaming text row")
        }
        model.apply(.interim("Interim answer", alreadyStreamed: false))
        assertMatchesFresh(model)
        model.apply(.reasoning("Check another step"))
        assertMatchesFresh(model)
        model.apply(.delta("Final answer"))
        assertMatchesFresh(model)
        model.apply(.completed(ChatCompletion(text: "Final answer")))
        assertMatchesFresh(model)
    }

    func testToolEditsAndHistoryReplacementDoNotReuseStaleIndexes() {
        let model = model()
        XCTAssertNotNil(model.transcript.beginTurn("Edit file"))
        model.apply(.toolStarted(ToolStart(toolId: "edit", name: "edit_file", args: ["path": "Example.swift"])))
        model.apply(.toolCompleted(ToolCompletion(toolId: "edit", name: "edit_file", inlineDiff: "-old\n+new")))
        assertMatchesFresh(model)
        model.apply(.completed(ChatCompletion(text: nil)))
        assertMatchesFresh(model)
        XCTAssertEqual(model.presentation.changedFiles.values.flatMap { $0 }.map(\.path), ["Example.swift"])
        let historical = model.presentation.history
        model.transcript.seed(history: [ChatHistoryMessage(role: .user, text: "Replacement"),
                                       ChatHistoryMessage(role: .assistant, text: "Different history")])
        assertMatchesFresh(model)
        XCTAssertFalse(model.presentation.history === historical)
        XCTAssertTrue(model.presentation.changedFiles.isEmpty)
    }

    private func poll(_ model: RoomModel) async {
        let before = model.pollCount
        model.start()
        model.nudge()
        await eventually { model.pollCount > before }
        model.stopPolling()
    }

    func testRoomCachesStatusAndThreadAcrossDraftsAndUnchangedPolls() async {
        let room = RoomFixtures.room()
        let api = FakeRoomActions(rooms: [room])
        let thread = RoomThreads.anchored(at: 1)
        let events = [RoomFixtures.user(1, "Anchor"), RoomFixtures.user(2, "Thread question", thread: thread),
                      RoomFixtures.member(3, "alpha", "Thread answer", thread: thread, disc: "user:2")]
        api.setEvents(room.roomId, events)
        let model = RoomModel(room: room, api: api)
        defer { model.shutdown() }
        await poll(model)
        let status = model.statusPresentation
        let transcript = model.presentation
        let projected = model.threadPresentation(thread: thread)
        XCTAssertEqual(projected.rows, RoomPresentation.rows(lines: model.timeline.lines(thread: thread, room: room), events: events))
        XCTAssertEqual(projected.anchor?.id, 1)
        XCTAssertEqual(model.memberStates, RoomPresentation.memberStates(room: room, timeline: model.timeline, driver: model.driver))

        model.setDraft("Typing", thread: thread)
        XCTAssertTrue(model.statusPresentation === status)
        XCTAssertTrue(model.threadPresentation(thread: thread) === projected)
        await poll(model)
        XCTAssertTrue(model.statusPresentation === status)
        XCTAssertTrue(model.presentation === transcript)
        XCTAssertTrue(model.threadPresentation(thread: thread) === projected)

        api.setDriver(room.roomId, RoomFixtures.approval)
        await poll(model)
        XCTAssertFalse(model.statusPresentation === status)
        XCTAssertEqual(model.memberStates["alpha"], .needsApproval)
        XCTAssertTrue(model.presentation === transcript)
        XCTAssertTrue(model.threadPresentation(thread: thread) === projected)

        api.setEvents(room.roomId, events + [RoomFixtures.member(4, "beta", "Another answer", thread: thread, disc: "user:2")])
        await poll(model)
        XCTAssertFalse(model.threadPresentation(thread: thread) === projected)
        XCTAssertEqual(model.threadPresentation(thread: thread).rows.last?.id, 4)
    }
}
