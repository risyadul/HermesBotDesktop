import Foundation

/// Splits a bottom-anchored chat timeline into a lazy head and an eagerly laid-out tail.
///
/// A plain `LazyVStack` under `.defaultScrollAnchor(.bottom)` opened a timeline of tall, uneven messages
/// blank: its estimated height parked the opening offset where no row was realised. A plain `VStack`
/// fixed that but laid out every message on open (≈400 ms main-thread stall for a long room). The tail
/// holds the rows the user sees first, so the opening offset always lands on laid-out rows, and the
/// older rows stay lazy.
enum EagerTail {
    /// Rows the tail always holds, however short they are.
    static let minRows = 10
    /// Rough text lines the tail must hold: enough to fill a tall window (a 1440 pt high window shows
    /// about 60 lines of body text).
    static let minLines = 120

    /// The split moves in steps of this many rows, so a growing timeline (or a streaming reply whose line
    /// count changes) does not move a row between head and tail on every update.
    static let step = 10

    /// Index of the first tail row: everything before it goes in the lazy head. Rounded down to a
    /// multiple of `step` (a bigger tail, never a smaller one).
    static func start<Item>(of items: [Item], minRows: Int = minRows, minLines: Int = minLines,
                            lines: (Item) -> Int) -> Int {
        var start = items.count, total = 0
        while start > 0 && (items.count - start < minRows || total < minLines) {
            start -= 1
            total += lines(items[start])
        }
        return start / step * step
    }

    /// Approximate wrapped line count of a message body plus its header and spacing (two lines).
    static func lines(_ text: String, charactersPerLine: Int = 80) -> Int {
        2 + text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + charactersPerLine - 1) / charactersPerLine) }
    }
}

extension RoomRow {
    /// Approximate height in text lines, for `EagerTail`.
    var approximateLines: Int {
        switch kind {
        case .user(let text), .member(_, _, let text), .status(_, _, let text), .failure(_, _, let text):
            return EagerTail.lines(text)
        case .passes, .divider:
            return 2
        }
    }
}
