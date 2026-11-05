import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A5: user sections the way Hermes Desktop keeps them: the list local, membership (`sectionId` +
/// `sectionName`) on each bot's `ui_meta`. Filing goes to a recording fake (or a fake `BotMetaModel` saver);
/// no real profile is written. `UserDefaults` is a throwaway suite.
@MainActor
final class BotSectionsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let name = "hba-test-sections-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Records every filing; each returns a finished save.
    private final class Filings {
        var calls: [(bot: String, id: String?, name: String?)] = []
    }

    private func model(_ d: UserDefaults? = nil, filings: Filings = Filings()) -> BotSectionsModel {
        var n = 0
        let m = BotSectionsModel(defaults: d ?? defaults(), makeId: { n += 1; return "sec-\(n)" })
        m.filer = { bot, id, name in
            filings.calls.append((bot, id, name))
            return Task {}
        }
        return m
    }

    private func bot(_ name: String) -> Bot { Bot(.object(["name": .string(name)]))! }

    // MARK: CRUD

    func testCreateAppendsPersistsAndFilesTheBot() {
        let d = defaults(), f = Filings()
        let m = model(d, filings: f)
        XCTAssertNil(m.create("   "), "a blank name makes nothing")
        let s = m.create(" Clients ", filing: ["alpha"])
        XCTAssertEqual(s, BotSection(id: "sec-1", name: "Clients"))
        XCTAssertEqual(m.sections, [BotSection(id: "sec-1", name: "Clients")])
        XCTAssertEqual(f.calls.map(\.bot), ["alpha"])
        XCTAssertEqual(f.calls.first?.id, "sec-1")
        XCTAssertEqual(f.calls.first?.name, "Clients", "the name rides along so other apps can rebuild it")
        XCTAssertEqual(model(d).sections, m.sections, "the list survives a relaunch")
    }

    func testRenameReStampsOnlyItsMembers() {
        let f = Filings()
        let m = model(filings: f)
        m.create("Clients")
        let meta: [String: BotUIMeta] = ["a": .init(sectionId: "sec-1", sectionName: "Clients"), "b": .init()]
        f.calls = []
        m.rename("sec-1", to: "Customers", meta: meta)
        XCTAssertEqual(m.sections.first?.name, "Customers")
        XCTAssertEqual(f.calls.map(\.bot), ["a"])
        XCTAssertEqual(f.calls.first?.name, "Customers")
        m.rename("sec-1", to: " ", meta: meta)
        XCTAssertEqual(m.sections.first?.name, "Customers")
    }

    func testDeleteUnfilesMembersAndUndoRestoresSlotAndMembers() {
        let f = Filings()
        let m = model(filings: f)
        m.create("One"); m.create("Two"); m.create("Three")
        let meta: [String: BotUIMeta] = ["a": .init(sectionId: "sec-2", sectionName: "Two"),
                                         "b": .init(sectionId: "sec-2", sectionName: "Two"), "c": .init()]
        f.calls = []
        m.delete("sec-2", meta: meta)
        XCTAssertEqual(m.sections.map(\.id), ["sec-1", "sec-3"])
        XCTAssertEqual(f.calls.map(\.bot), ["a", "b"])
        XCTAssertTrue(f.calls.allSatisfy { $0.id == nil && $0.name == nil }, "members go back to Unassigned")
        XCTAssertEqual(m.lastDelete?.members, ["a", "b"])
        XCTAssertEqual(SectionUndoLine.text(m.lastDelete!), "Deleted “Two”: 2 bots moved to Unassigned")
        f.calls = []
        m.undoDelete(meta: ["a": .init(), "b": .init(), "c": .init()])
        XCTAssertEqual(m.sections.map(\.id), ["sec-1", "sec-2", "sec-3"], "back in its slot")
        XCTAssertEqual(f.calls.map(\.bot), ["a", "b"])
        XCTAssertTrue(f.calls.allSatisfy { $0.id == "sec-2" && $0.name == "Two" })
        XCTAssertNil(m.lastDelete)
    }

    func testDeletedSectionIsNotRebuiltByMembersStillBeingCleared() {
        let m = model()
        m.filer = { _, _, _ in Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) } }  // clear still running
        m.create("Two")
        let stale: [String: BotUIMeta] = ["a": .init(sectionId: "sec-1", sectionName: "Two")]
        m.delete("sec-1", meta: stale)
        m.sync(meta: stale)
        XCTAssertTrue(m.sections.isEmpty)
    }

    func testMoveAndFileSkipNoOpsAndUnknownSections() {
        let f = Filings()
        let m = model(filings: f)
        m.create("One"); m.create("Two")
        m.move("sec-2", by: -1)
        XCTAssertEqual(m.sections.map(\.id), ["sec-2", "sec-1"])
        m.move("sec-2", by: -1)
        XCTAssertEqual(m.sections.map(\.id), ["sec-2", "sec-1"])
        f.calls = []
        m.file(["a", "b"], into: "sec-1", meta: ["a": .init(sectionId: "sec-1", sectionName: "One")])
        XCTAssertEqual(f.calls.map(\.bot), ["b"], "a bot already there is not written again")
        f.calls = []
        m.file(["a"], into: "sec-gone", meta: [:])
        XCTAssertTrue(f.calls.isEmpty, "filing into a deleted section would resurrect it")
    }

    func testCollapseIsRemembered() {
        let d = defaults()
        let m = model(d)
        m.toggleCollapsed(BotSectionsModel.unassignedKey)
        XCTAssertTrue(m.isCollapsed(BotSectionsModel.unassignedKey))
        XCTAssertTrue(model(d).isCollapsed(BotSectionsModel.unassignedKey))
        m.toggleCollapsed(BotSectionsModel.unassignedKey)
        XCTAssertFalse(model(d).isCollapsed(BotSectionsModel.unassignedKey))
    }

    // MARK: following Desktop

    func testAdoptsSectionsAnotherAppMadeAndAgreedRenames() {
        let local = [BotSection(id: "s1", name: "Old")]
        let meta: [String: BotUIMeta] = [
            "a": .init(sectionId: "s1", sectionName: "New"), "b": .init(sectionId: "s1", sectionName: "New"),
            "c": .init(sectionId: "s9", sectionName: "Desktop"), "d": .init(sectionId: "s7"),
            "e": .init(sectionId: "s8", sectionName: "Gone"),
        ]
        XCTAssertEqual(BotSectionsModel.adopted(local: local, meta: meta, pending: ["s8"]),
                       [BotSection(id: "s1", name: "New"), BotSection(id: "s9", name: "Desktop")],
                       "an id without a name has nothing to rebuild from; a pending delete is not rebuilt")
        let split: [String: BotUIMeta] = ["a": .init(sectionId: "s1", sectionName: "X"), "b": .init(sectionId: "s1", sectionName: "Y")]
        XCTAssertEqual(BotSectionsModel.adopted(local: local, meta: split, pending: []), local, "members disagree: the local name stays")
    }

    func testBackfillStampsNamesOnceForKnownSections() {
        let f = Filings()
        let m = model(filings: f)
        m.create("Clients")
        f.calls = []
        let meta: [String: BotUIMeta] = ["a": .init(sectionId: "sec-1"), "b": .init(sectionId: "other")]
        m.sync(meta: meta)
        XCTAssertEqual(f.calls.map(\.bot), ["a"])
        XCTAssertEqual(f.calls.first?.name, "Clients")
        m.sync(meta: meta)
        XCTAssertEqual(f.calls.count, 1, "a stamp that did not land is not retried on every change")
    }

    // MARK: layout

    func testBlocksPutEveryBotOnceUnknownSectionsUnassigned() {
        let bots = ["a", "b", "c", "d"].map(bot)
        let sections = [BotSection(id: "s1", name: "One"), BotSection(id: "s2", name: "Two")]
        let meta: [String: BotUIMeta] = ["a": .init(sectionId: "s2"), "b": .init(sectionId: "s1"), "c": .init(sectionId: "deleted")]
        let blocks = BotSectionBlock.blocks(bots, sections: sections, meta: meta)
        XCTAssertEqual(blocks.map { $0.section?.id }, ["s1", "s2", nil])
        XCTAssertEqual(blocks.map { $0.bots.map(\.name) }, [["b"], ["a"], ["c", "d"]])
    }

    func testRosterDrawsSectionsCollapsedAndFiltered() {
        let bots = ["a", "b", "c"].map(bot)
        let sections = [BotSection(id: "s1", name: "One"), BotSection(id: "s2", name: "Empty")]
        let meta: [String: BotUIMeta] = ["a": .init(sectionId: "s1")]
        let r = BotRoster(bots: bots, meta: meta, query: "", hiddenExpanded: false, sections: sections, collapsed: ["s1"])
        XCTAssertEqual(r.blocks.map(\.id), ["s1", "s2", BotSectionsModel.unassignedKey], "an empty named section shows its drop slot")
        XCTAssertEqual(r.rows.map(\.name), ["b", "c"], "a collapsed section's rows are not drawn or walked")
        let filtered = BotRoster(bots: bots, meta: meta, query: "a", hiddenExpanded: false, sections: sections, collapsed: ["s1"])
        XCTAssertEqual(filtered.blocks.map(\.id), ["s1"], "a filter leaves out blocks without a match")
        XCTAssertEqual(filtered.rows.map(\.name), ["a"], "and shows matches inside collapsed sections")
        let flat = BotRoster(bots: bots, meta: meta, query: "", hiddenExpanded: false)
        XCTAssertTrue(flat.blocks.isEmpty, "no sections: the plain list")
        let allFiled = BotRoster(bots: [bot("a")], meta: meta, query: "", hiddenExpanded: false, sections: [sections[0]])
        XCTAssertEqual(allFiled.blocks.map(\.id), ["s1"], "an empty Unassigned gets no heading")
    }

    func testMoveToSectionChoices() {
        let sections = [BotSection(id: "s1", name: "One"), BotSection(id: "s2", name: "Two")]
        XCTAssertEqual(BotRowMenu.sectionChoices(BotUIMeta(sectionId: "s2"), sections: sections),
                       [.section(sections[0], current: false), .section(sections[1], current: true), .unassigned, .newSection])
        XCTAssertEqual(BotRowMenu.sectionChoices(BotUIMeta(), sections: []), [.newSection])
        XCTAssertEqual(BotRowMenu.sectionChoices(BotUIMeta(sectionId: "gone"), sections: sections),
                       [.section(sections[0], current: false), .section(sections[1], current: false), .newSection])
    }

    func testDragPayloadIsTheHandleAndOnlyRosterBotsDrop() {
        let roster = [bot("alpha"), bot("beta")]
        XCTAssertEqual(BotDrag.payload(roster[0]), "@alpha")
        XCTAssertEqual(BotDrag.bot(from: "@beta", roster: roster)?.name, "beta")
        XCTAssertNil(BotDrag.bot(from: "beta", roster: roster))
        XCTAssertNil(BotDrag.bot(from: "@ghost", roster: roster))
        XCTAssertNil(BotDrag.bot(from: "some dropped text", roster: roster))
    }

    func testSectionNameSheetValidation() {
        XCTAssertFalse(SectionNameView.canSave("  ", request: .create(filing: nil)))
        XCTAssertTrue(SectionNameView.canSave("Clients", request: .create(filing: "a")))
        let s = BotSection(id: "s1", name: "Clients")
        XCTAssertFalse(SectionNameView.canSave("Clients ", request: .rename(s)), "an unchanged name is not a rename")
        XCTAssertTrue(SectionNameView.canSave("Customers", request: .rename(s)))
    }

    // MARK: the save itself (BotMetaModel)

    func testSetSectionSendsDesktopsFieldsAndClearsWithNulls() async throws {
        let patches = Patches()
        let m = BotMetaModel()
        m.log = { _ in }
        m.load([bot("a")])
        m.saver = { name, patch in
            patches.add(patch)
            return .persisted(BotUIMeta(row: ["ui_meta": ["hermes-bots": .object(patch)]]))
        }
        await m.setSection("a", id: "s1", sectionName: "Clients")?.value
        XCTAssertEqual(patches.all.last, ["sectionId": "s1", "sectionName": "Clients"])
        XCTAssertEqual(m["a"].sectionId, "s1")
        XCTAssertNil(m.setSection("a", id: "s1", sectionName: "Clients"), "no change, no write")
        await m.setSection("a", id: nil, sectionName: "ignored")?.value
        XCTAssertEqual(patches.all.last, ["sectionId": .null, "sectionName": .null])
        XCTAssertNil(m["a"].sectionId)
        XCTAssertNil(m["a"].sectionName)
    }
}

private final class Patches: @unchecked Sendable {
    private let lock = NSLock()
    private var patches: [[String: JSONValue]] = []
    func add(_ p: [String: JSONValue]) { lock.withLock { patches.append(p) } }
    var all: [[String: JSONValue]] { lock.withLock { patches } }
}
