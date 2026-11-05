import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Live UI test 2026-11-06: empty Triage / Todo lanes filled the board while the selected card's lane was off
/// screen, and the card inspector opened on "No card selected". Pure rules, headless.
@MainActor
final class KanbanBoardLayoutTests: XCTestCase {
    private func task(_ id: String, _ status: String = "todo") -> KanbanTask {
        try! KanbanTask(json: .object(["id": .string(id), "title": .string("Card \(id)"), "status": .string(status)]))
    }

    private var board: [KanbanLane] {
        [KanbanLane(name: "triage", tasks: []), KanbanLane(name: "todo", tasks: []),
         KanbanLane(name: "ready", tasks: [task("t_1", "ready")]), KanbanLane(name: "blocked", tasks: [task("t_2", "blocked")])]
    }

    func testEmptyLanesFoldUnlessUnfoldedOrTheWholeBoardIsEmpty() {
        let lanes = board
        XCTAssertEqual(lanes.map { KanbanColumns.isCollapsed($0, in: lanes, expanded: []) }, [true, true, false, false])
        XCTAssertEqual(lanes.map { KanbanColumns.isCollapsed($0, in: lanes, expanded: ["todo"]) }, [true, false, false, false],
                       "a lane the user unfolded stays open")
        let empty = lanes.map { KanbanLane(name: $0.name, tasks: []) }
        XCTAssertFalse(empty.contains { KanbanColumns.isCollapsed($0, in: empty, expanded: []) },
                       "a board with no cards shows its lanes")
    }

    func testFoldedLanesLeaveRoomForTheLanesWithCards() {
        XCTAssertTrue((240...260).contains(DS.Kanban.laneWidth))
        XCTAssertLessThan(DS.Kanban.collapsedLaneWidth, DS.Kanban.laneWidth / 4)
        // Default window, sidebar column (setting + 8) and inspector: two lanes with cards fit side by side.
        let detail = DS.Size.windowDefault.width - (DS.Size.sidebarWidth + 8) - DS.Size.inspectorWidth
        XCTAssertLessThanOrEqual(2 * DS.Space.s4 + 2 * DS.Kanban.laneWidth + DS.Space.s3, detail)
    }

    func testSelectedCardsLaneIsFound() {
        XCTAssertEqual(KanbanColumns.lane(containing: "t_2", in: board), "blocked")
        XCTAssertNil(KanbanColumns.lane(containing: "t_9", in: board))
        XCTAssertNil(KanbanColumns.lane(containing: nil, in: board))
    }

    func testInspectorOpensOnSelectionAndRespectsAnExplicitClose() {
        XCTAssertFalse(KanbanInspectorRule.shown(selection: nil, closedByUser: false), "hidden with nothing selected")
        XCTAssertTrue(KanbanInspectorRule.shown(selection: "t_1", closedByUser: false), "opens on selection")
        XCTAssertFalse(KanbanInspectorRule.shown(selection: "t_1", closedByUser: true), "stays closed after the user closed it")

        XCTAssertTrue(KanbanInspectorRule.closedByUser(afterShown: false, selection: "t_1", was: false),
                      "closing with a card selected is the user's choice")
        XCTAssertFalse(KanbanInspectorRule.closedByUser(afterShown: false, selection: nil, was: false),
                       "the app hiding it on deselect is not")
        XCTAssertTrue(KanbanInspectorRule.closedByUser(afterShown: false, selection: nil, was: true))
        XCTAssertFalse(KanbanInspectorRule.closedByUser(afterShown: true, selection: "t_1", was: true),
                       "opening it again by hand clears the choice")
    }
}
