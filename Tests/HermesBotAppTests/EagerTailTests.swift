import XCTest
@testable import HermesBotApp

/// The eager tail of a bottom-anchored timeline (EagerTail): it must cover what the user sees on open
/// (so the opening offset lands on laid-out rows) while older rows stay lazy.
final class EagerTailTests: XCTestCase {
    private func row(_ id: Int, _ kind: RoomRow.Kind) -> RoomRow { RoomRow(id: id, kind: kind, time: 0) }
    private func member(_ id: Int, chars: Int) -> RoomRow {
        row(id, .member(memberId: "m", author: "m", text: String(repeating: "x", count: chars)))
    }

    func testShortTimelineIsAllTail() {
        let rows = (0..<7).map { member($0, chars: 40) }
        XCTAssertEqual(EagerTail.start(of: rows) { $0.approximateLines }, 0)
        XCTAssertEqual(EagerTail.start(of: [RoomRow]()) { $0.approximateLines }, 0)
    }

    func testLongMessagesKeepTheTailNearMinRows() {
        // 60 rows of ~40 lines each: 10 rows already exceed the line budget.
        let rows = (0..<60).map { member($0, chars: 3_200) }
        let start = EagerTail.start(of: rows) { $0.approximateLines }
        XCTAssertEqual(start, 50)
        XCTAssertGreaterThanOrEqual(rows[start...].map(\.approximateLines).reduce(0, +), EagerTail.minLines)
    }

    func testShortRowsGrowTheTailUntilItFillsAWindow() {
        // Pass and divider rows are two lines each: 10 of them cannot fill a window.
        let rows = (0..<200).map { row($0, $0.isMultiple(of: 2) ? .passes([]) : .divider(text: "settled")) }
        let start = EagerTail.start(of: rows) { $0.approximateLines }
        XCTAssertGreaterThan(rows.count - start, EagerTail.minRows)
        XCTAssertGreaterThanOrEqual(rows[start...].map(\.approximateLines).reduce(0, +), EagerTail.minLines)
        XCTAssertEqual(start % EagerTail.step, 0)
    }

    func testSplitOnlyMovesInSteps() {
        // A growing timeline keeps the same split until it crosses a step boundary.
        let starts = (41...49).map { n in EagerTail.start(of: (0..<n).map { member($0, chars: 3_200) }) { $0.approximateLines } }
        XCTAssertEqual(Set(starts), [30])
    }

    func testLineEstimateCountsWrapsAndNewlines() {
        XCTAssertEqual(EagerTail.lines(""), 3)
        XCTAssertEqual(EagerTail.lines(String(repeating: "x", count: 80)), 3)
        XCTAssertEqual(EagerTail.lines(String(repeating: "x", count: 81)), 4)
        XCTAssertEqual(EagerTail.lines("a\nb\n\nc"), 6)
    }
}
