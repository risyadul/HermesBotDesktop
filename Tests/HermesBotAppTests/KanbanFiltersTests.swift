import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K4 board filters: the profile filter, "Group Running by profile" groups, and "Show archived" (the
/// board is fetched with `include_archived` and the archived lane stays on screen). Headless, fake service.
@MainActor
final class KanbanFiltersTests: XCTestCase {
    private func t(_ id: String, _ status: String, _ assignee: String?) -> KanbanTask {
        try! KanbanTask(json: FakeKanbanService.task(id, "Title \(id)", status: status, assignee: assignee))
    }

    func testProfileFilterKeepsOnlyThatAssigneeInEveryLane() {
        let lanes = [KanbanLane(name: "ready", tasks: [t("a", "ready", "alice"), t("b", "ready", "bob"), t("c", "ready", nil)]),
                     KanbanLane(name: "running", tasks: [t("d", "running", "alice")])]
        XCTAssertEqual(KanbanProfileFilter.apply(lanes, assignee: nil), lanes, "nil = every card")
        let alice = KanbanProfileFilter.apply(lanes, assignee: "alice")
        XCTAssertEqual(alice.map(\.name), ["ready", "running"], "lanes are kept, even when emptied")
        XCTAssertEqual(alice.map { $0.tasks.map(\.id) }, [["a"], ["d"]])
        XCTAssertEqual(KanbanProfileFilter.apply(lanes, assignee: "carol").flatMap(\.tasks), [])
    }

    func testRunningGroupsSortByNameKeepLaneOrderAndNameTheUnassigned() {
        let tasks = [t("1", "running", "zed"), t("2", "running", nil), t("3", "running", "alice"), t("4", "running", "zed")]
        let groups = KanbanProfileFilter.groups(tasks)
        XCTAssertEqual(groups.map(\.name), ["alice", "unassigned", "zed"])
        XCTAssertEqual(groups.map { $0.tasks.map(\.id) }, [["3"], ["2"], ["1", "4"]])
    }

    func testOnlyANonEmptyRunningLaneIsGroupedAndOnlyWhenOn() {
        let running = KanbanLane(name: "running", tasks: [t("1", "running", "a")])
        XCTAssertTrue(KanbanProfileFilter.groupsLane(running, enabled: true))
        XCTAssertFalse(KanbanProfileFilter.groupsLane(running, enabled: false))
        XCTAssertFalse(KanbanProfileFilter.groupsLane(KanbanLane(name: "running", tasks: []), enabled: true))
        XCTAssertFalse(KanbanProfileFilter.groupsLane(KanbanLane(name: "ready", tasks: [t("2", "ready", "a")]), enabled: true))
    }

    func testFilterButtonReadsActiveForAProfileOrArchived() {
        XCTAssertFalse(KanbanProfileFilter.isActive(assignee: nil, archived: false))
        XCTAssertTrue(KanbanProfileFilter.isActive(assignee: "alice", archived: false))
        XCTAssertTrue(KanbanProfileFilter.isActive(assignee: nil, archived: true))
    }

    // MARK: Show archived

    private func fake() -> FakeKanbanService {
        FakeKanbanService(columns: [
            ("todo", [FakeKanbanService.task("t_1", "Todo one", status: "todo")]),
            ("done", []),
            ("archived", []),
        ])
    }

    func testShowArchivedRefetchesWithTheFlagAndKeepsTheEmptyArchivedLane() async throws {
        let api = fake()
        let m = KanbanBoardModel(slug: "main", api: api)
        await m.refresh()
        XCTAssertEqual(m.lanes.map(\.name), ["todo", "done"], "empty archived lane hidden while off")
        m.setIncludeArchived(true)
        XCTAssertTrue(m.includeArchived)
        let end = Date().addingTimeInterval(5)
        while api.with({ $0.boardArchivedFlags }).count < 2, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(api.with { $0.boardArchivedFlags }, [false, true], "the refetch asks for archived cards")
        XCTAssertEqual(m.lanes.map(\.name), ["todo", "done", "archived"], "the archived lane shows, even empty")
        await m.refresh()
        XCTAssertEqual(api.with { $0.boardArchivedFlags }.last, true, "later polls keep the flag")
        m.setIncludeArchived(true)
        XCTAssertEqual(api.count("board"), 3, "setting the same value again fetches nothing")
    }

    func testArchivingWhileShowingArchivedMovesTheCardIntoTheArchivedLane() async {
        let m = KanbanBoardModel(slug: "main", api: fake())
        m.setIncludeArchived(true)
        await m.refresh()
        let ok = await m.archive("t_1")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.lanes.first { $0.name == "archived" }?.tasks.map(\.id), ["t_1"])
        XCTAssertEqual(m.lanes.first { $0.name == "todo" }?.tasks.map(\.id), [])
    }

    func testPlaceDropsArchivedCardsUnlessKept() throws {
        let lanes = [KanbanLane(name: "todo", tasks: []), KanbanLane(name: "archived", tasks: [])]
        let card = t("x", "archived", nil)
        XCTAssertEqual(KanbanBoardModel.place(card, in: lanes).flatMap(\.tasks), [])
        XCTAssertEqual(KanbanBoardModel.place(card, in: lanes, keepArchived: true).last?.tasks.map(\.id), ["x"])
    }
}
