import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Roadmap P1 Group Chat in RoomModel, headless over `FakeRoomActions`: rename (C1.1), threads (C1.2),
/// per-message actions (C1.6) and per-thread drafts (C1.7).
@MainActor
final class RoomModelGroupChatTests: XCTestCase {
    private var api: FakeRoomActions!
    private var model: RoomModel!

    override func setUp() async throws {
        api = FakeRoomActions(rooms: [RoomFixtures.room()])
        model = RoomModel(room: RoomFixtures.room(), api: api)
    }

    override func tearDown() async throws {
        model.shutdown()
    }

    /// Loads `events` through the model's own poller (start → one sync → stop).
    private func load(_ events: [RoomEvent]) async {
        api.setEvents("hba-test-0", events)
        model.start()
        await eventually { self.model.timeline.cursor == (events.last?.seq ?? 0) && self.model.lastSync != nil }
        model.stopPolling()
    }

    // MARK: C1.1 rename

    func testRenameIsOptimisticThenConfirmed() async {
        var changed: [String] = []
        model.onRoomChanged = { changed.append($0.name) }
        XCTAssertTrue(model.rename("  Release crew  "))
        XCTAssertEqual(model.room.name, "Release crew", "the new name shows before the call returns")
        XCTAssertTrue(model.busyActions.contains("rename"))
        await eventually { !self.model.busyActions.contains("rename") }
        XCTAssertEqual(model.room.name, "Release crew")
        XCTAssertEqual(api.renames.map(\.name), ["Release crew"], "sent trimmed")
        XCTAssertTrue(api.renames[0].eventId.hasPrefix("hba-rename-") && RoomMember.isIdentifier(api.renames[0].eventId))
        XCTAssertEqual(changed, ["Release crew"], "the sidebar row follows once")
        XCTAssertEqual(RoomNote(model.notes.last ?? "").text, "Renamed to Release crew.")
        XCTAssertFalse(RoomNote(model.notes.last ?? "").failed)
    }

    func testRenameFailureRestoresOldNameAndSaysWhy() async {
        api.failRename(GatewayClient.RPCError(code: 4117, message: "invalid room name", data: nil))
        var changed: [String] = []
        model.onRoomChanged = { changed.append($0.name) }
        XCTAssertTrue(model.rename("New"))
        XCTAssertEqual(model.room.name, "New")
        await eventually { !self.model.busyActions.contains("rename") }
        XCTAssertEqual(model.room.name, "Ops", "a refused rename puts the old name back")
        XCTAssertEqual(changed, ["New", "Ops"])
        let note = RoomNote(model.notes.last ?? "")
        XCTAssertTrue(note.failed)
        XCTAssertTrue(note.text.hasPrefix("Rename failed:"), note.text)
    }

    func testRenameRefusesBlankUnchangedTooLongOrSecondInFlight() async {
        XCTAssertFalse(model.rename("   "))
        XCTAssertFalse(model.rename("Ops"), "unchanged")
        XCTAssertFalse(model.rename(String(repeating: "a", count: 201)))
        api.holdRename()
        XCTAssertTrue(model.rename("One"))
        await eventually { self.api.renameParked }
        XCTAssertFalse(model.rename("Two"), "one rename at a time")
        api.releaseRename()
        await eventually { !self.model.busyActions.contains("rename") }
        XCTAssertEqual(api.renames.map(\.name), ["One"])
    }

    func testPollDuringRenameKeepsTheNewName() async {
        api.holdRename()
        XCTAssertTrue(model.rename("Fresh"))
        await eventually { self.api.renameParked }
        api.setEvents("hba-test-0", [RoomFixtures.user(1)])
        model.start()  // the server still reports the old name while the rename is in flight
        await eventually { self.model.timeline.cursor == 1 }
        XCTAssertEqual(model.room.name, "Fresh", "a poll does not flash the old name back")
        model.stopPolling()
        api.releaseRename()
        await eventually { !self.model.busyActions.contains("rename") }
        XCTAssertEqual(model.room.name, "Fresh")
    }

    func testStaleStateAfterRenameDoesNotPutTheOldNameBack() async {
        XCTAssertTrue(model.rename("Fresh"))
        await eventually { !self.model.busyActions.contains("rename") }
        XCTAssertEqual(model.room.revision, 2, "the confirmed row (revision + 1) is kept")
        // A sync that was in flight when the rename returned carries the pre-rename row (revision 1).
        api.setRooms([RoomFixtures.room()])
        api.setEvents("hba-test-0", [RoomFixtures.user(1)])
        model.start()
        await eventually { self.model.timeline.cursor == 1 }
        model.stopPolling()
        XCTAssertEqual(model.room.name, "Fresh")
        // A newer row (renamed elsewhere) still wins.
        api.setRooms([RoomFixtures.room(name: "Elsewhere", revision: 3)])
        api.setEvents("hba-test-0", [RoomFixtures.user(1), RoomFixtures.user(2)])
        model.start()
        await eventually { self.model.timeline.cursor == 2 }
        model.stopPolling()
        XCTAssertEqual(model.room.name, "Elsewhere")
    }

    func testRenameRefusedOnceTheRoomIsClosing() async {
        _ = await model.disband()
        XCTAssertFalse(model.rename("Later"))
        XCTAssertTrue(api.renames.isEmpty)
    }

    func testRenameDialogValidation() {
        XCTAssertTrue(RenameRoomView.canRename("New", current: "Ops"))
        XCTAssertFalse(RenameRoomView.canRename(" Ops ", current: "Ops"))
        XCTAssertFalse(RenameRoomView.canRename("", current: "Ops"))
    }

    // MARK: C1.2 threads

    func testMainComposerPostsToMain() async {
        model.setDraft("hello all", thread: RoomThreads.main)
        XCTAssertTrue(model.submit())
        XCTAssertEqual(model.draft(RoomThreads.main), "", "accepted: the draft clears")
        await eventually { self.api.sends.count == 1 }
        XCTAssertEqual(api.sends[0].thread, "main")
        XCTAssertEqual(api.sends[0].text, "hello all")
    }

    func testReplyInThreadOnMainMessageStartsAnchoredThreadAndQuotesIt() async {
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha", "Option A is faster.\nOption B is safer.")])
        model.replyInThread(seq: 2)
        XCTAssertEqual(model.openThread, "hba-t-2")
        XCTAssertEqual(model.focusRequest?.thread, "hba-t-2")
        model.setDraft("why safer?", thread: "hba-t-2")
        model.setDraft("main draft stays", thread: RoomThreads.main)
        XCTAssertTrue(model.submit(thread: "hba-t-2"))
        await eventually { self.api.sends.count == 1 }
        XCTAssertEqual(api.sends[0].thread, "hba-t-2")
        XCTAssertEqual(api.sends[0].text, "> Alpha: Option A is faster. Option B is safer.\n\nwhy safer?",
                       "members only see their thread: the first message quotes what it answers")
        XCTAssertEqual(model.draft(RoomThreads.main), "main draft stays", "drafts are per thread")
        await eventually { !self.model.composer.sending }
        model.setDraft("and cost?", thread: "hba-t-2")
        XCTAssertTrue(model.submit(thread: "hba-t-2"))
        await eventually { self.api.sends.count == 2 }
        XCTAssertEqual(api.sends[1].text, "and cost?", "only the first message of the thread quotes")
    }

    func testReplyInThreadOnThreadMessageContinuesIt() async {
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha"), RoomFixtures.user(3, "q", thread: "tdesk-1"),
                    RoomFixtures.member(4, "beta", "a", thread: "tdesk-1")])
        model.replyInThread(seq: 4)
        XCTAssertEqual(model.openThread, "tdesk-1")
        model.setDraft("more", thread: "tdesk-1")
        XCTAssertTrue(model.submit(thread: "tdesk-1"))
        await eventually { self.api.sends.count == 1 }
        XCTAssertEqual(api.sends[0].thread, "tdesk-1")
        XCTAssertEqual(api.sends[0].text, "more", "an existing thread is not quoted into")
    }

    func testExistingAnchoredThreadIsNotQuotedAgain() async {
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha"), RoomFixtures.user(3, "> Alpha: hello\n\nq", thread: "hba-t-2")])
        model.setDraft("follow-up", thread: "hba-t-2")
        XCTAssertTrue(model.submit(thread: "hba-t-2"))
        await eventually { self.api.sends.count == 1 }
        XCTAssertEqual(api.sends[0].text, "follow-up")
    }

    func testThreadSendFailureRestoresThatThreadsDraft() async {
        api.failSend(GatewayClient.ClientError.timeout("groups.send"))
        model.setDraft("lost?", thread: "hba-t-9")
        XCTAssertTrue(model.submit(thread: "hba-t-9"))
        XCTAssertEqual(model.draft("hba-t-9"), "")
        await eventually { self.model.draft("hba-t-9") == "lost?" }
        XCTAssertEqual(model.draft(RoomThreads.main), "", "the main composer is untouched")
    }

    func testCloseThreadReturnsFocusToMain() {
        model.showThread("hba-t-3")
        XCTAssertEqual(model.openThread, "hba-t-3")
        model.closeThread()
        XCTAssertNil(model.openThread)
        XCTAssertEqual(model.focusRequest?.thread, "main")
        model.showThread("main")
        XCTAssertNil(model.openThread, "main is the room composer, not a thread pane")
    }

    func testRowsCarryTheirThread() async {
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha", thread: "hba-t-1")])
        let rows = RoomPresentation.rows(lines: model.lines, events: model.timeline.events)
        XCTAssertEqual(rows.map(\.threadId), ["main", "hba-t-1"])
        XCTAssertTrue(rows.allSatisfy(\.isMessage))
        XCTAssertEqual(RoomPresentation.threadTitle(nil), "Thread")
        XCTAssertEqual(RoomPresentation.replyCount(1), "1 reply")
        XCTAssertEqual(RoomPresentation.replyCount(3), "3 replies")
    }

    // MARK: C1.6 per-message actions

    func testReplyToBotPrefillsMentionInMain() async {
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha")])
        model.setDraft("  ", thread: RoomThreads.main)
        model.replyToMember(seq: 2)
        XCTAssertEqual(model.draft(RoomThreads.main), "@alpha ")
        XCTAssertEqual(model.focusRequest?.thread, "main")
        XCTAssertNil(model.openThread)
        model.replyToMember(seq: 2)
        XCTAssertEqual(model.draft(RoomThreads.main), "@alpha ", "an existing mention is not repeated")
        XCTAssertTrue(api.sends.isEmpty, "only edits the draft")
    }

    func testReplyToBotInThreadOpensItsThread() async {
        await load([RoomFixtures.user(1, thread: "hba-t-1"), RoomFixtures.member(2, "beta", thread: "hba-t-1")])
        model.setDraft("draft", thread: "hba-t-1")
        model.replyToMember(seq: 2)
        XCTAssertEqual(model.openThread, "hba-t-1")
        XCTAssertEqual(model.draft("hba-t-1"), "@beta draft")
        XCTAssertEqual(model.draft(RoomThreads.main), "")
    }

    func testReplyToIgnoresNonMemberRows() async {
        await load([RoomFixtures.user(1)])
        model.replyToMember(seq: 1)
        XCTAssertEqual(model.draft(RoomThreads.main), "")
    }

    func testSeedMention() {
        XCTAssertEqual(RoomModel.seedMention("alpha", into: ""), "@alpha ")
        XCTAssertEqual(RoomModel.seedMention("alpha", into: "what about x?"), "@alpha what about x?")
        XCTAssertEqual(RoomModel.seedMention("alpha", into: "ok @alpha"), "ok @alpha")
        XCTAssertEqual(RoomModel.seedMention("alpha", into: "@alphabet"), "@alpha @alphabet", "a longer handle is another mention")
        XCTAssertEqual(RoomModel.seedMention("alpha", into: "hi\n\n"), "@alpha hi ")
    }

    func testCopyText() {
        let member = RoomRow(id: 2, kind: .member(memberId: "alpha", author: "Alpha", text: "**bold** answer"), time: 0)
        XCTAssertEqual(RoomPresentation.copyText(member), "**bold** answer", "copied as written")
        let sent = RoomAttachments.compose(text: "see file", paths: ["/tmp/a.png"])
        XCTAssertEqual(RoomPresentation.copyText(RoomRow(id: 1, kind: .user(text: sent), time: 0)), "see file\n/tmp/a.png")
        XCTAssertNil(RoomPresentation.copyText(RoomRow(id: 3, kind: .divider(text: "Stopped"), time: 0)))
        let opening = RoomThreads.opening("why?", quoting: "Alpha", "B is safer")
        XCTAssertEqual(RoomPresentation.copyText(RoomRow(id: 4, kind: .user(text: opening), time: 0, threadId: "hba-t-2")), "why?",
                       "the quote an anchored thread opens with is not copied")
        XCTAssertEqual(RoomPresentation.copyText(RoomRow(id: 5, kind: .user(text: "> mine\n\nok"), time: 0)), "> mine\n\nok",
                       "a quote the user typed in the room is kept")
    }

    // MARK: C1.7 drafts survive the pane

    func testDraftsLiveInTheModelAcrossPaneSwitches() {
        model.setDraft("half-written", thread: RoomThreads.main)
        model.start(); model.stopPolling()  // the pane disappears (switching to another room) …
        model.start(); model.stopPolling()  // … and comes back
        XCTAssertEqual(model.draft(RoomThreads.main), "half-written")
    }

    func testRefusedSendKeepsDraft() async {
        _ = await model.disband()
        model.setDraft("too late", thread: RoomThreads.main)
        XCTAssertFalse(model.submit())
        XCTAssertEqual(model.draft(RoomThreads.main), "too late")
    }

    func testOnAppliedReportsSeenWhileOnScreen() async {
        var seen: [(Bool, Int)] = []
        model.onApplied = { m in seen.append((m.isOnScreen, m.timeline.cursor)) }
        await load([RoomFixtures.user(1), RoomFixtures.member(2, "alpha")])
        XCTAssertEqual(seen.last?.0, true)
        XCTAssertEqual(seen.last?.1, 2)
        XCTAssertFalse(model.isOnScreen, "stopped polling: off screen")
    }
}
