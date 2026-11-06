import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit


private struct NativeScrollFixtureRow: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
private final class NativeFollowChanges {
    var values: [Bool] = []
}

/// Exercises the production table coordinator, including its real data source and height updates.
/// No NSWindow or backend is created.
@MainActor
private struct NativeScrollFixture {
    typealias Table = TranscriptTable<[NativeScrollFixtureRow], Text>
    let values: [NativeScrollFixtureRow]
    let tracker: TranscriptScrollTracker
    let changes: NativeFollowChanges
    let scroll: TranscriptTableScrollView
    let coordinator: Table.Coordinator

    init() {
        values = Self.rows(0..<40)
        let tracker = TranscriptScrollTracker()
        self.tracker = tracker
        let changes = NativeFollowChanges()
        self.changes = changes
        let parent = Table(items: values, revision: 0, structureRevision: 0, tracker: tracker,
                           onFollowChange: { changes.values.append($0) }, sameContent: ==) { Text($0.text) }
        coordinator = parent.makeCoordinator()
        scroll = TranscriptTableScrollView(tracker: tracker)
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        coordinator.attach(scroll)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
    }

    static func rows(_ range: Range<Int>) -> [NativeScrollFixtureRow] {
        range.map { NativeScrollFixtureRow(id: $0, text: "Message \($0). " + String(repeating: "Wrapped native transcript text. ", count: 20)) }
    }

    func update(_ values: [NativeScrollFixtureRow], revision: Int) {
        coordinator.update(Table(items: values, revision: revision, structureRevision: revision, tracker: tracker,
                                 onFollowChange: { changes.values.append($0) }, sameContent: ==) { Text($0.text) })
    }

    var rowExtent: CGFloat {
        scroll.tableView.numberOfRows > 0 ? scroll.tableView.rect(ofRow: scroll.tableView.numberOfRows - 1).maxY : 0
    }
    var bottom: CGFloat { max(0, rowExtent - scroll.contentView.bounds.height) }

    func position(_ y: CGFloat) {
        let proposal = CGRect(origin: NSPoint(x: 0, y: y), size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposal).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func settle() async throws {
        // The coordinator coalesces native width changes for 60ms. Exercise that production path,
        // rather than changing a fake document's frame or bypassing its scheduled adjustment.
        try await Task.sleep(for: .milliseconds(120))
        scroll.layoutSubtreeIfNeeded()
        scroll.tableView.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

final class LongTranscriptScrollTests: XCTestCase {
    func testInitialHistoryIsNotUnreadAndReadinessDoesNotEraseLaterArrivals() {
        var unread = UnreadCounter()
        var lines = (0..<600).map { index in
            ChatLine(role: index.isMultiple(of: 3) ? .user : .bot, text: "Persisted message \(index)")
        }
        // A native pause can be delivered during initial layout, before the view's ready callback.
        unread.update(lines, following: false)
        XCTAssertTrue(unread.seedHistoryIfNeeded(lines))
        unread.update(lines, following: false)
        XCTAssertEqual(unread.count, 0, "existing history is not new when the reader first scrolls up")

        lines.append(ChatLine(role: .bot, text: "A reply arrived after opening"))
        unread.update(lines, following: false)
        XCTAssertEqual(unread.count, 1)
        XCTAssertFalse(unread.seedHistoryIfNeeded(lines), "a later ready/appear callback must not reset reading state")
        unread.update(lines, following: false)
        XCTAssertEqual(unread.count, 1)
    }

    func testEmptyOrToolOnlyInitialHistorySeedsExactlyOnce() {
        for history in [[], [ChatLine(role: .tool, text: "Prior tool output")]] {
            var unread = UnreadCounter()
            XCTAssertTrue(unread.seedHistoryIfNeeded(history))
            unread.update(history + [ChatLine(role: .bot, text: "New answer")], following: false)
            XCTAssertEqual(unread.count, 1)
        }
    }

    @MainActor
    func testUnphasedNativeUserScrollResumesAtTheBottom() async throws {
        let fixture = NativeScrollFixture()
        defer { fixture.coordinator.detach() }
        try await fixture.settle()
        fixture.coordinator.scrollToLatest()
        try await fixture.settle()
        XCTAssertGreaterThan(fixture.bottom, 400)

        // Older wheels can deliver didLive without the phase begin/end pair.
        fixture.position(fixture.bottom / 2)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(fixture.tracker.follow.following)
        XCTAssertFalse(fixture.tracker.userScrolling)

        fixture.position(fixture.bottom)
        XCTAssertFalse(fixture.tracker.follow.following, "bounds alone are geometry, not a request to follow")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: NSScrollView())
        XCTAssertFalse(fixture.tracker.follow.following, "another scroll view's user event is ignored")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: fixture.scroll)
        XCTAssertTrue(fixture.tracker.follow.following, "an unphased user scroll at bottom resumes following")
    }

    @MainActor
    func testPausedNativeHistorySurvivesLayoutClampingAtTheBottom() async throws {
        let fixture = NativeScrollFixture()
        defer { fixture.coordinator.detach() }
        try await fixture.settle()
        fixture.coordinator.scrollToLatest()
        try await fixture.settle()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        fixture.position(fixture.bottom / 2)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(fixture.tracker.follow.following)

        // A history replacement removes the old reading anchor and produces a short document.
        // The actual table's structural update and bottom-aligned clip perform the layout clamp.
        fixture.update(Array(fixture.values.prefix(2)), revision: 1)
        try await fixture.settle()
        XCTAssertLessThanOrEqual(fixture.rowExtent - fixture.scroll.contentView.bounds.maxY,
                                 TranscriptFollow.slack, "the production viewport really reached its new end")
        XCTAssertFalse(fixture.tracker.follow.following, "a layout-only clamp must preserve reading intent")
        XCTAssertFalse(fixture.tracker.userScrolling)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertTrue(fixture.tracker.follow.following, "only a gesture ending at bottom resumes following")
    }

    @MainActor
    func testNativeDataGrowthRestoresBottomAndKeepsGestureIntent() async throws {
        let fixture = NativeScrollFixture()
        defer { fixture.coordinator.detach() }
        try await fixture.settle()
        fixture.coordinator.scrollToLatest()
        try await fixture.settle()
        let previousBottom = fixture.bottom
        fixture.update(fixture.values + NativeScrollFixture.rows(40..<60), revision: 1)
        try await fixture.settle()
        XCTAssertGreaterThan(fixture.bottom, previousBottom)
        XCTAssertEqual(fixture.scroll.contentView.bounds.maxY, fixture.scroll.tableView.bounds.maxY, accuracy: 1)
        XCTAssertTrue(fixture.tracker.follow.following)

        fixture.position(fixture.bottom - 200)
        XCTAssertTrue(fixture.tracker.follow.following, "a bounds change alone is not user intent")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(fixture.tracker.follow.following, "the next explicit upward scroll pauses after relayout")
    }

    @MainActor
    func testNativeFollowControllerIsScopedImmediateAndDetached() async throws {
        let fixture = NativeScrollFixture()
        defer { fixture.coordinator.detach() }
        try await fixture.settle()
        fixture.coordinator.scrollToLatest()
        try await fixture.settle()
        XCTAssertTrue(fixture.tracker.nativeAttached)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: NSScrollView())
        XCTAssertTrue(fixture.tracker.follow.following, "another window or inspector must not pause this transcript")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(fixture.tracker.follow.following, "gesture intent pauses before asynchronous geometry")
        XCTAssertTrue(fixture.tracker.userScrolling)
        XCTAssertEqual(fixture.changes.values.last, false)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: fixture.scroll.contentView)
        XCTAssertFalse(fixture.tracker.follow.following, "stale bottom geometry at gesture start cannot resume")
        fixture.position(fixture.bottom / 2)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertFalse(fixture.tracker.follow.following)
        XCTAssertFalse(fixture.tracker.userScrolling)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        fixture.position(fixture.bottom)
        XCTAssertFalse(fixture.tracker.follow.following, "an active gesture owns the viewport even at the bottom")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: fixture.scroll)
        XCTAssertTrue(fixture.tracker.follow.following)

        fixture.coordinator.detach()
        let count = fixture.changes.values.count
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        XCTAssertEqual(fixture.changes.values.count, count)
        XCTAssertFalse(fixture.tracker.nativeAttached)
        XCTAssertFalse(fixture.tracker.userScrolling)
        XCTAssertNil(fixture.tracker.scrollToLatest)
        XCTAssertNil(fixture.tracker.scrollToID)
    }

    func testReadingLongHistorySurvivesNewOutputAndSidebarReflow() {
        var follow = TranscriptFollow()
        follow.update(top: -200_000, bottom: 600, viewport: 600, width: 900)
        follow.update(top: -198_000, bottom: 2_600, viewport: 600, width: 900, userScrolling: true)
        XCTAssertFalse(follow.following)

        // More output and narrower wrapping both change estimated content height. Neither is a request
        // to leave the historical messages the user is reading.
        follow.update(top: -198_000, bottom: 4_600, viewport: 600, width: 900)
        follow.update(top: -250_000, bottom: 40_000, viewport: 600, width: 650)
        follow.update(top: -197_500, bottom: 5_100, viewport: 600, width: 900)
        XCTAssertFalse(follow.following)

        follow.update(top: -202_010, bottom: 590, viewport: 600, width: 900, userScrolling: true)
        XCTAssertTrue(follow.following, "reaching the end follows new output again")
    }

    func testSidebarOrInspectorReflowDoesNotPretendTheUserScrolledUp() {
        var follow = TranscriptFollow()
        follow.update(top: -4_000, bottom: 600, viewport: 600, width: 900)
        follow.update(top: -2_000, bottom: 1_100, viewport: 600, width: 1_100)
        XCTAssertTrue(follow.following, "a wider viewport moved the top; no user gesture occurred")
        follow.update(top: -1_850, bottom: 1_250, viewport: 750, width: 1_100)
        XCTAssertTrue(follow.following, "changing viewport height is also layout")
    }

    func testLazyHeightCorrectionDoesNotStopFollowingButUserGestureDoes() {
        var follow = TranscriptFollow()
        follow.update(top: -4_000, bottom: 600, viewport: 600, width: 900)
        follow.update(top: -3_000, bottom: 800, viewport: 600, width: 900)
        XCTAssertTrue(follow.following, "lazy estimated height correction is not user scrolling")

        // Realising another tall row changes content height in the same tick as an actual gesture.
        follow.update(top: -2_800, bottom: 1_600, viewport: 600, width: 900, userScrolling: true)
        XCTAssertFalse(follow.following, "native live-scroll intent takes precedence over height changes")
        follow.resume()
        XCTAssertTrue(follow.following)
        follow.update(top: -4_000, bottom: 1_000, viewport: 600, width: 900)
        XCTAssertTrue(follow.following, "resume discards the old offset before the programmatic jump")
    }

    func testRoomUnreadCountIgnoresStatusOnlyPollingAcrossLongHistory() {
        var unread = RoomUnreadCounter()
        var rows = (0..<2_000).map { id in
            RoomRow(id: id, kind: id.isMultiple(of: 2)
                ? .member(memberId: "bot", author: "Bot", text: "Message \(id)")
                : .divider(text: "Discussion settled"), time: 0)
        }
        unread.update(rows, following: true)

        rows.append(RoomRow(id: 2_000, kind: .passes([]), time: 0))
        rows.append(RoomRow(id: 2_001, kind: .status(memberId: "bot", author: "Bot", text: "Working"), time: 0))
        unread.update(rows, following: false)
        XCTAssertEqual(unread.count, 0)

        rows.append(RoomRow(id: 2_002, kind: .user(text: "New question"), time: 0))
        rows.append(RoomRow(id: 2_003, kind: .member(memberId: "bot", author: "Bot", text: "Reply"), time: 0))
        unread.update(rows, following: false)
        XCTAssertEqual(unread.count, 2)
        unread.update(rows, following: false)
        XCTAssertEqual(unread.count, 2, "the same poll must not count messages twice")
        unread.update(rows, following: true)
        XCTAssertEqual(unread.count, 0)
    }
}
