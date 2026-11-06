import HermesGatewayKit
import SwiftUI

/// Read-only overlays keep completed-turn indexes shared while the active turn changes. Values are
/// materialized only by diagnostics; row rendering does one lookup in the small tail, then the history.
struct TranscriptLookup<Value> {
    let history: [UUID: Value]
    let tail: [UUID: Value]

    subscript(_ id: UUID) -> Value? { tail[id] ?? history[id] }
    var isEmpty: Bool { history.isEmpty && tail.isEmpty }
    var values: [Value] { Array(history.values) + Array(tail.values) }
}

/// A stable, integer-indexed view over completed rows and the current turn. Creating a streaming
/// snapshot does not copy all historical rows just to replace the last row in an Array.
struct BotTranscriptItems: RandomAccessCollection {
    let history: [TranscriptItem]
    let tail: [TranscriptItem]
    var startIndex: Int { 0 }
    var endIndex: Int { history.count + tail.count }
    subscript(_ index: Int) -> TranscriptItem {
        index < history.count ? history[index] : tail[index - history.count]
    }
}

@MainActor
final class BotTranscriptHistory {
    let lineCount: Int
    let items: [TranscriptItem]
    let gaps: [UUID: CGFloat]
    let fullResponses: [UUID: String]
    let changedFiles: [UUID: [ChangedFile]]

    init(lines: ArraySlice<ChatLine>) {
        lineCount = lines.count
        let lines = Array(lines)
        items = TranscriptItem.build(lines)
        gaps = TranscriptItem.gaps(items)
        fullResponses = ChatCopy.fullResponses(lines)
        changedFiles = ChangedFiles.cards(lines, busy: false)
    }
}

/// Completed-turn derivations are shared across streaming snapshots. The model explicitly opts into
/// reuse only for events that cannot modify historical rows. Reset/rewind/tool replacement still take
/// the conservative full-build path, so local UUIDs never carry over into a different history generation.
@MainActor
final class BotTranscriptPresentation {
    let history: BotTranscriptHistory
    let activeFirstID: UUID?
    let items: BotTranscriptItems
    let gaps: TranscriptLookup<CGFloat>
    let fullResponses: TranscriptLookup<String>
    let changedFiles: TranscriptLookup<[ChangedFile]>
    let tailStart: Int
    var lastID: UUID? { items.last?.id }

    init(lines: [ChatLine], busy: Bool, previous: BotTranscriptPresentation? = nil, reuseHistory: Bool = false) {
        let history: BotTranscriptHistory
        if reuseHistory, let previous, lines.count >= previous.history.lineCount,
           lines.dropFirst(previous.history.lineCount).first?.id == previous.activeFirstID {
            history = previous.history
        } else {
            let start = lines.lastIndex(where: { $0.role == .user }) ?? 0
            history = BotTranscriptHistory(lines: lines[..<start])
        }
        self.history = history
        let active = Array(lines.dropFirst(history.lineCount))
        activeFirstID = active.first?.id
        let activeItems = TranscriptItem.build(active)
        items = BotTranscriptItems(history: history.items, tail: activeItems)
        var activeGaps = TranscriptItem.gaps(Array(history.items.suffix(1)) + activeItems)
        if let last = history.items.last { activeGaps[last.id] = nil }
        gaps = TranscriptLookup(history: history.gaps, tail: activeGaps)
        fullResponses = TranscriptLookup(history: history.fullResponses, tail: ChatCopy.fullResponses(active))
        changedFiles = TranscriptLookup(history: history.changedFiles, tail: ChangedFiles.cards(active, busy: busy))
        if let previous, previous.items.count == items.count,
           (reuseHistory && previous.history === history
            || zip(previous.items, items).allSatisfy({ $0.id == $1.id })) {
            tailStart = previous.tailStart
        } else {
            tailStart = EagerTail.start(of: items) { $0.approximateLines }
        }
    }
}

@MainActor
final class RoomThreadPresentation {
    let summary: RoomThreadSummary?
    let rows: [RoomRow]
    let anchor: RoomRow?

    init(summary: RoomThreadSummary?, rows: [RoomRow], anchor: RoomRow?) {
        self.summary = summary
        self.rows = rows
        self.anchor = anchor
    }
}

@MainActor
final class RoomTranscriptPresentation {
    let lines: [RoomLine]
    let rows: [RoomRow]
    let threads: [String: RoomThreadSummary]
    let tailStart: Int
    private let eventsBySeq: [Int: RoomEvent]
    private var threadPresentations: [String: RoomThreadPresentation] = [:]

    init(timeline: RoomTimeline, room: RoomSummary, previous: RoomTranscriptPresentation? = nil) {
        let lines = timeline.lines(room: room)
        self.lines = lines
        let eventsBySeq = Dictionary(timeline.events.map { ($0.seq, $0) }, uniquingKeysWith: { first, _ in first })
        self.eventsBySeq = eventsBySeq
        let rows = RoomPresentation.rows(lines: lines, eventsBySeq: eventsBySeq)
        self.rows = rows
        threads = Dictionary(timeline.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let previous, previous.rows.count == rows.count,
           zip(previous.rows, rows).allSatisfy({ $0.id == $1.id }) {
            tailStart = previous.tailStart
        } else {
            tailStart = EagerTail.start(of: rows) { $0.approximateLines }
        }
    }

    /// A thread is projected once for this history revision, rather than on each draft/status change.
    func thread(_ id: String) -> RoomThreadPresentation {
        if let existing = threadPresentations[id] { return existing }
        let rows = RoomPresentation.rows(lines: lines.filter { $0.threadId == id }, eventsBySeq: eventsBySeq)
        let anchor = RoomThreads.anchorSeq(of: id).flatMap { seq in
            RoomPresentation.rows(lines: lines.filter { $0.id == seq }, eventsBySeq: eventsBySeq).first
        }
        let result = RoomThreadPresentation(summary: threads[id], rows: rows, anchor: anchor)
        threadPresentations[id] = result
        return result
    }
}

@MainActor
final class RoomStatusPresentation {
    let memberStates: [String: RoomPresentation.MemberState]
    let active: Bool
    let pollInterval: TimeInterval

    init(timeline: RoomTimeline, room: RoomSummary, driver: RoomDriverStatus?) {
        memberStates = RoomPresentation.memberStates(room: room, timeline: timeline, driver: driver)
        active = RoomPollPolicy.busy(driver: driver, timeline: timeline)
        pollInterval = timeline.behind ? 0 : active ? RoomPollPolicy.active : RoomPollPolicy.idle
    }
}
