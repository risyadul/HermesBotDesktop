import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp

private struct TableFixtureRow: Identifiable, Equatable {
    let id: Int
    var text: String
}

private struct ErasedTableFixtureRow: Identifiable, Equatable {
    let id: AnyHashable
    let text: String
}

private final class TableFixtureReads {
    var count = 0
}

private struct TableFixtureRows: RandomAccessCollection {
    let values: [TableFixtureRow]
    let reads: TableFixtureReads
    var startIndex: Int { 0 }
    var endIndex: Int { values.count }
    subscript(index: Int) -> TableFixtureRow {
        reads.count += 1
        return values[index]
    }
}

/// Native row measurement and collection access tests. No NSWindow, backend, or image renderer is used.
@MainActor
final class TranscriptTableTests: XCTestCase {
    func testSearchJumpAcceptsTheErasedUUIDUsedByChatRows() async throws {
        let target = UUID()
        let rows = (0..<80).map { index in
            ErasedTableFixtureRow(id: index == 60 ? AnyHashable(target) : AnyHashable(index), text: "Search target \(index)")
        }
        let tracker = TranscriptScrollTracker()
        let parent = TranscriptTable(items: rows, revision: 0, tracker: tracker,
                                     onFollowChange: { _ in }, sameContent: ==) { Text($0.text) }
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        scroll.tile()
        try await Task.sleep(for: .milliseconds(120))
        tracker.scrollToID?(AnyHashable(target), .center)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(tracker.follow.following)
        XCTAssertTrue(scroll.tableView.rect(ofRow: 60).intersects(scroll.contentView.bounds),
                      "global search must reach UUID rows through the type-erased native command")
    }

    private func presentation(_ rows: TableFixtureRows, revision: Int, tracker: TranscriptScrollTracker)
        -> TranscriptTable<TableFixtureRows, Text> {
        TranscriptTable(items: rows, revision: revision, structureRevision: 1,
                        tracker: tracker, onFollowChange: { _ in }, sameContent: ==) { Text($0.text) }
    }

    func testEstimatedHeightsDoNotConstructOrReadTenThousandOffscreenRows() {
        let reads = TableFixtureReads()
        let rows = TableFixtureRows(values: (0..<10_000).map { TableFixtureRow(id: $0, text: "Message \($0)") }, reads: reads)
        let tracker = TranscriptScrollTracker()
        let parent = presentation(rows, revision: 0, tracker: tracker)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        let created = scroll.createdCellCount
        reads.count = 0

        for index in 0..<10_000 {
            XCTAssertGreaterThan(coordinator.tableView(scroll.tableView, heightOfRow: index), 0)
        }
        XCTAssertEqual(reads.count, 0, "height estimation must not build or inspect offscreen payloads")
        XCTAssertEqual(scroll.createdCellCount, created, "geometry queries must not create hosting cells")
        XCTAssertEqual(coordinator.numberOfRows(in: scroll.tableView), 10_000)
    }

    func testSameStructureStreamingRevisionDoesNotScanTheHistoricalCollection() {
        let reads = TableFixtureReads()
        let values = (0..<10_000).map { TableFixtureRow(id: $0, text: "Message \($0)") }
        let tracker = TranscriptScrollTracker()
        let initial = presentation(TableFixtureRows(values: values, reads: reads), revision: 0, tracker: tracker)
        let coordinator = initial.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }

        var changed = values
        changed[changed.count - 1].text += " streamed suffix"
        reads.count = 0
        coordinator.update(presentation(TableFixtureRows(values: changed, reads: reads), revision: 1, tracker: tracker))
        XCTAssertLessThan(reads.count, 100, "a text delta may refresh visible rows, never enumerate the full collection")
        XCTAssertLessThan(scroll.createdCellCount, 100)
    }

    func testVeryTallHostingRowIsMeasuredAtItsActualViewportWidth() throws {
        let reads = TableFixtureReads()
        let rows = TableFixtureRows(values: [TableFixtureRow(id: 0, text: String(repeating: "Long text should wrap normally. ", count: 1_000))], reads: reads)
        let tracker = TranscriptScrollTracker()
        let parent = presentation(rows, revision: 0, tracker: tracker)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        scroll.tile()

        let cell = try XCTUnwrap(coordinator.tableView(scroll.tableView, viewFor: scroll.tableView.tableColumns.first, row: 0))
        XCTAssertNotNil(cell)
        let height = coordinator.tableView(scroll.tableView, heightOfRow: 0)
        XCTAssertGreaterThan(height, 1_000, "the native table must reserve the tall row's real height")
        XCTAssertLessThan(height, 100_000, "initial zero-width installation must not measure a glyph-wide document")
        XCTAssertGreaterThan(scroll.measuredCellCount, 0)
    }

    func testStreamingOneVisibleRowDoesNotRemeasureUnchangedVisibleHistory() async throws {
        let reads = TableFixtureReads()
        var values = (0..<6).map { TableFixtureRow(id: $0, text: "Message \($0)") }
        let tracker = TranscriptScrollTracker()
        let parent = presentation(TableFixtureRows(values: values, reads: reads), revision: 0, tracker: tracker)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        scroll.tile()
        for index in values.indices {
            _ = try XCTUnwrap(scroll.tableView.view(atColumn: 0, row: index, makeIfNecessary: true))
        }
        // Settle the width and the initial automatic heights without opening a window.
        try await Task.sleep(for: .milliseconds(120))
        scroll.tableView.layoutSubtreeIfNeeded()
        let before = scroll.measuredCellCount
        values[5].text += " delta"
        coordinator.update(presentation(TableFixtureRows(values: values, reads: reads), revision: 1, tracker: tracker))
        XCTAssertEqual(scroll.measuredCellCount - before, 1,
                       "only the active row's changed payload should need explicit measurement")
    }

    func testDetachRemovesTheNativeScrollCommands() {
        let tracker = TranscriptScrollTracker()
        let parent = presentation(TableFixtureRows(values: [], reads: TableFixtureReads()), revision: 0, tracker: tracker)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        XCTAssertNotNil(tracker.scrollToLatest)
        XCTAssertNotNil(tracker.scrollToID)
        XCTAssertTrue(tracker.nativeAttached)
        coordinator.detach()
        XCTAssertNil(tracker.scrollToLatest)
        XCTAssertNil(tracker.scrollToID)
        XCTAssertFalse(tracker.nativeAttached)
    }

    func testShortChatAndThreadRowsStayAtTheViewportBottom() async throws {
        for count in [1, 3] {
            let rows = TableFixtureRows(values: (0..<count).map { TableFixtureRow(id: $0, text: "Short message \($0)") },
                                        reads: TableFixtureReads())
            let tracker = TranscriptScrollTracker()
            let parent = presentation(rows, revision: 0, tracker: tracker)
            let coordinator = parent.makeCoordinator()
            let scroll = TranscriptTableScrollView(tracker: tracker)
            coordinator.attach(scroll)
            scroll.setFrameSize(NSSize(width: 600, height: 400))
            scroll.tile()
            try await Task.sleep(for: .milliseconds(120))
            scroll.tableView.layoutSubtreeIfNeeded()
            coordinator.scrollToLatest()
            try await Task.sleep(for: .milliseconds(30))

            let lastRow = scroll.tableView.rect(ofRow: count - 1)
            XCTAssertLessThan(lastRow.maxY, scroll.contentView.bounds.height)
            let bottom = scroll.tableView.convert(lastRow, to: scroll.contentView).maxY
            XCTAssertEqual(bottom, scroll.contentView.bounds.maxY, accuracy: 1,
                           "short chat/thread transcripts must sit against the composer")
            XCTAssertLessThan(scroll.contentView.bounds.minY, 0)
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            XCTAssertFalse(tracker.follow.following)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            XCTAssertTrue(tracker.follow.following, "a gesture at a short transcript's actual bottom resumes follow")
            coordinator.detach()
        }
    }

    func testPausedShortTranscriptCanScrollAfterItsReplyGrows() async throws {
        let reads = TableFixtureReads()
        let tracker = TranscriptScrollTracker()
        var values = [TableFixtureRow(id: 0, text: "Short streaming reply")]
        let parent = presentation(TableFixtureRows(values: values, reads: reads), revision: 0, tracker: tracker)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        scroll.tile()
        _ = scroll.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        try await Task.sleep(for: .milliseconds(120))
        coordinator.scrollToLatest()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        XCTAssertFalse(tracker.follow.following)
        values[0].text = String(repeating: "A longer reply must stay scrollable after it grows. ", count: 1_000)
        values.append(TableFixtureRow(id: 1, text: "Next reply"))
        coordinator.update(presentation(TableFixtureRows(values: values, reads: reads), revision: 1, tracker: tracker))
        try await Task.sleep(for: .milliseconds(100))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertFalse(tracker.follow.following)
        let proposed = CGRect(x: 0, y: 400, width: scroll.contentView.bounds.width, height: scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0,
                             "a stale short-content extent must not force a grown reply to a negative offset")
        tracker.scrollToLatest?()
        XCTAssertTrue(tracker.follow.following)
    }

    func testDeletedReadingAnchorUsesSurvivingNeighborAcrossAppendAndResize() async throws {
        let reads = TableFixtureReads()
        var values = (0..<100).map { TableFixtureRow(id: $0, text: "Message \($0) " + String(repeating: "wrapped history ", count: 20)) }
        let tracker = TranscriptScrollTracker()
        func makePresentation(_ revision: Int) -> TranscriptTable<TableFixtureRows, Text> {
            TranscriptTable(items: TableFixtureRows(values: values, reads: reads), revision: revision,
                            structureRevision: revision, tracker: tracker,
                            onFollowChange: { _ in }, sameContent: ==) { Text($0.text) }
        }
        let parent = makePresentation(0)
        let coordinator = parent.makeCoordinator()
        let scroll = TranscriptTableScrollView(tracker: tracker)
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        scroll.setFrameSize(NSSize(width: 600, height: 400))
        scroll.tile()
        try await Task.sleep(for: .milliseconds(120))
        coordinator.scroll(to: AnyHashable(40), anchor: .top)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(tracker.follow.following)

        values.removeAll { $0.id == 40 }
        coordinator.update(makePresentation(1))
        try await Task.sleep(for: .milliseconds(120))
        let successorIndex = try XCTUnwrap(values.firstIndex { $0.id == 41 })
        let initialOffset = scroll.contentView.bounds.minY - scroll.tableView.rect(ofRow: successorIndex).minY
        XCTAssertGreaterThanOrEqual(initialOffset, -1)
        XCTAssertLessThan(initialOffset, scroll.tableView.rect(ofRow: successorIndex).height)

        values.append(TableFixtureRow(id: 100, text: "Appended while reading"))
        coordinator.update(makePresentation(2))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(scroll.contentView.bounds.minY - scroll.tableView.rect(ofRow: successorIndex).minY,
                       initialOffset, accuracy: 1, "append must retain the replacement anchor")
        scroll.setFrameSize(NSSize(width: 480, height: 400))
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(scroll.contentView.bounds.minY - scroll.tableView.rect(ofRow: successorIndex).minY,
                       initialOffset, accuracy: 1, "resize must retain the replacement anchor")
        XCTAssertFalse(tracker.follow.following)
    }
}
