import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// K7: New / Rename / Delete (archive) / Export / Import boards through `KanbanHub`, and the orchestration
/// settings model, against `FakeKanbanService` (never a live backend; export/import paths are placeholders
/// the fake only records). Headless.
@MainActor
final class KanbanBoardManagementTests: XCTestCase {
    private static let hour: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }

    private func connected(_ boards: [JSONValue] = [FakeKanbanService.summary("default"), FakeKanbanService.summary("side")]) async
        -> (KanbanHub, FakeKanbanService) {
        let api = FakeKanbanService()
        api.with { $0.boards = boards }
        let hub = KanbanHub(sleep: Self.hour)
        hub.connect(api: api)
        await hub.refreshBoards()
        return (hub, api)
    }

    // MARK: rules

    func testDefaultBoardIsNeverArchivedAndTheCurrentOneWarns() throws {
        XCTAssertFalse(KanbanBoardRules.canArchive("default"))
        XCTAssertTrue(KanbanBoardRules.canArchive("side"))
        let plain = try KanbanBoardSummary(json: ["slug": "side"])
        let current = try KanbanBoardSummary(json: ["slug": "side", "is_current": true])
        XCTAssertTrue(KanbanBoardRules.archiveMessage(plain).contains("archived, not erased"))
        XCTAssertFalse(KanbanBoardRules.archiveMessage(plain).contains("current board"))
        XCTAssertTrue(KanbanBoardRules.archiveMessage(current).contains("Hermes' current board"))
        XCTAssertEqual(KanbanBoardRules.exportFileName("side"), "side.tar.gz")
    }

    func testNewBoardNameProblems() throws {
        let existing = [try KanbanBoardSummary(json: ["slug": "q3-plan"])]
        XCTAssertEqual(KanbanBoardRules.newNameProblem("  ", existing: existing), "", "empty: Create is just disabled")
        XCTAssertEqual(KanbanBoardRules.newNameProblem("!!", existing: existing), "Use at least one letter or digit.")
        XCTAssertEqual(KanbanBoardRules.newNameProblem("Q3 Plan", existing: existing), "A board with the id “q3-plan” already exists.")
        XCTAssertNil(KanbanBoardRules.newNameProblem("Q4 Plan", existing: existing))
    }

    // MARK: hub actions

    func testCreateBoardSendsSlugAndNameAndListsIt() async {
        let (hub, api) = await connected()
        let r = await hub.createBoard(name: " Q4 Launch ")
        XCTAssertEqual(r, .success("q4-launch"))
        XCTAssertEqual(api.with { $0.createdBoards.map { "\($0.slug)|\($0.name)" } }, ["q4-launch|Q4 Launch"])
        XCTAssertTrue(hub.rows.contains { $0.slug == "q4-launch" }, "the list was refreshed")
        XCTAssertEqual(hub.boardNote, KanbanBoardNote(text: "Created the board “Q4 Launch”.", isError: false))
    }

    func testCreateBoardRefusesATakenIdWithoutSending() async {
        let (hub, api) = await connected()
        let r = await hub.createBoard(name: "Side")
        XCTAssertEqual(r, .failure(KanbanBoardFailure(message: "A board with the id “side” already exists.")))
        XCTAssertEqual(api.count("createBoard"), 0)
    }

    func testRenameBoard() async {
        let (hub, api) = await connected()
        let empty = await hub.renameBoard("side", to: "  ")
        XCTAssertEqual(empty, "Give the board a name.")
        let ok = await hub.renameBoard("side", to: "Side projects")
        XCTAssertNil(ok)
        XCTAssertEqual(api.with { $0.renamedBoards.map(\.name) }, ["Side projects"])
        XCTAssertEqual(hub.summary("side")?.name, "Side projects")
    }

    func testArchiveRefusesDefaultAndArchivesOthers() async {
        let (hub, api) = await connected()
        var listed: Set<String>?
        hub.onBoardsListed = { listed = $0 }
        let refused = await hub.archiveBoard("default")
        XCTAssertEqual(refused, "The default board can't be deleted.")
        XCTAssertEqual(api.count("archiveBoard"), 0)
        let ok = await hub.archiveBoard("side")
        XCTAssertNil(ok)
        XCTAssertEqual(api.with { $0.archivedBoards }, ["side"])
        XCTAssertEqual(listed, ["default"], "the selection follows through onBoardsListed")
        XCTAssertFalse(hub.rows.contains { $0.slug == "side" })
        XCTAssertEqual(hub.boardNote?.isError, false)
        XCTAssertTrue(hub.boardNote?.text.contains("/placeholder/_archived/x") ?? false)
    }

    func testArchiveFailureIsAnErrorNote() async {
        let (hub, api) = await connected()
        api.with { $0.manageError = PluginREST.Failure.http(status: 400, detail: "board 'side' is busy") }
        let r = await hub.archiveBoard("side")
        XCTAssertEqual(r, "Delete “Side” failed: board 'side' is busy")
        XCTAssertEqual(hub.boardNote, KanbanBoardNote(text: "Delete “Side” failed: board 'side' is busy", isError: true))
        XCTAssertTrue(hub.rows.contains { $0.slug == "side" })
    }

    func testExportPassesThePickedPath() async {
        let (hub, api) = await connected()
        let file = URL(fileURLWithPath: "/placeholder/exports/side.tar.gz")
        let r = await hub.exportBoard("side", to: file)
        guard case .success(let out) = r else { return XCTFail("export failed") }
        XCTAssertEqual(out.archive, file.path)
        XCTAssertEqual(api.with { $0.exports.map(\.output) }, [file.path])
        XCTAssertEqual(hub.boardNote?.text, "Exported to /placeholder/exports/side.tar.gz (2 KB).")
    }

    func testImportListsTheNewBoardAndReportsRenameAndWarnings() async {
        let (hub, api) = await connected()
        api.with { $0.importReply = ["board": "side-2", "name": "Side", "renamed": true, "requested_board": "side",
                                     "warnings": ["1 task parked: its workspace is missing."]] }
        let r = await hub.importBoard(from: URL(fileURLWithPath: "/placeholder/side.tar.gz"))
        XCTAssertEqual(r, .success("side-2"))
        XCTAssertEqual(api.with { $0.imports }, ["/placeholder/side.tar.gz"])
        XCTAssertTrue(hub.rows.contains { $0.slug == "side-2" })
        XCTAssertEqual(hub.boardNote?.text,
                       "Imported “Side”. That id was taken, so it is “side-2”. 1 task parked: its workspace is missing.")
    }

    func testImportFailure() async {
        let (hub, api) = await connected()
        api.with { $0.manageError = PluginREST.Failure.http(status: 404, detail: "archive not found") }
        let r = await hub.importBoard(from: URL(fileURLWithPath: "/placeholder/none.tar.gz"))
        XCTAssertEqual(r, .failure(KanbanBoardFailure(message: "Import failed: archive not found")))
        XCTAssertEqual(hub.boardNote?.isError, true)
        hub.dismissBoardNote()
        XCTAssertNil(hub.boardNote)
    }

    func testActionsNeedAConnection() async {
        let hub = KanbanHub(sleep: Self.hour)
        let r = await hub.createBoard(name: "New")
        XCTAssertEqual(r, .failure(KanbanBoardFailure(message: "Not connected to Hermes.")))
        let archived = await hub.archiveBoard("side")
        XCTAssertEqual(archived, "Not connected to Hermes.")
    }

    // MARK: orchestration

    func testOrchestrationLoadsAndSavesOneFieldAtATime() async {
        let api = FakeKanbanService()
        let m = KanbanOrchestrationModel(api: api)
        await m.load()
        XCTAssertEqual(m.settings?.resolvedOrchestratorProfile, "alice")
        XCTAssertEqual(m.profiles.map(\.name), ["alice", "bob"])
        let ok = await m.save(KanbanOrchestrationPatch(defaultAssignee: "bob"))
        XCTAssertTrue(ok)
        XCTAssertEqual(m.settings?.defaultAssignee, "bob")
        _ = await m.save(KanbanOrchestrationPatch(autoDecompose: false))
        XCTAssertEqual(m.settings?.autoDecompose, false)
        XCTAssertEqual(api.with { $0.orchestrationPatches },
                       [KanbanOrchestrationPatch(defaultAssignee: "bob"), KanbanOrchestrationPatch(autoDecompose: false)])
        XCTAssertFalse(m.saving)
    }

    func testOrchestrationErrorsKeepTheSettings() async {
        let api = FakeKanbanService()
        let m = KanbanOrchestrationModel(api: api)
        await m.load()
        api.with { $0.orchestrationError = PluginREST.Failure.http(status: 400, detail: "profile 'ghost' does not exist") }
        let ok = await m.save(KanbanOrchestrationPatch(orchestratorProfile: "ghost"))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "Not saved: profile 'ghost' does not exist")
        XCTAssertEqual(m.settings?.orchestratorProfile, "")
        let fresh = KanbanOrchestrationModel(api: api)
        await fresh.load()
        XCTAssertNil(fresh.settings)
        XCTAssertEqual(fresh.error, "Settings not loaded: profile 'ghost' does not exist")
    }

    func testProfileChoicesKeepAConfiguredNameTheRosterLost() {
        let roster = [KanbanProfile(json: ["name": "alice"])!, KanbanProfile(json: ["name": "bob"])!]
        XCTAssertEqual(KanbanOrchestrationModel.choices(roster, current: ""), ["alice", "bob"])
        XCTAssertEqual(KanbanOrchestrationModel.choices(roster, current: "carol"), ["alice", "bob", "carol"])
    }
}
