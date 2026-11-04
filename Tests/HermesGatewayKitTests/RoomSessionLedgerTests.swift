import Foundation
import XCTest
@testable import HermesGatewayKit

/// Review run313 BLOCK-003C: a member row deleted by the cleanup can be re-created with the SAME exact id
/// by the late title-generation usage write (`hermes_state_usage.py:388-391`: `source=unknown`,
/// `message_count=0`, then an llm title). The `bot_room` listing filter never sees it again, so the
/// cleanup must remember proven keys (ledger) and read them back by exact id — no false success, and
/// unrelated `unknown` rows stay untouched.
final class RoomSessionLedgerTests: XCTestCase {
    static let thief = RoomMember(memberId: "thief", profile: "thief", handle: "thief")
    static let reviewer = RoomMember(memberId: "code-reviewer", profile: "code-reviewer", handle: "code-reviewer")
    static let room = RoomManifestEntry(roomId: "hba-recreation-probe", name: "hba recreation probe", createdAt: 1_000,
                                        members: [thief, reviewer])
    static let own = StoredSessionRow(profile: "thief", id: "own-exact-key", title: "Group: hba-recreation-probe", startedAt: 1_010)
    /// What title accounting leaves behind: same id, source unknown, arbitrary llm title, 0 messages.
    static let placeholder = StoredSessionRow(profile: "thief", id: "own-exact-key", title: "History of tide clocks essay",
                                              source: "unknown", startedAt: 1_020)

    func tempLedger() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hba-ledger-\(UUID().uuidString).jsonl")
    }

    /// The reviewer's deterministic probe: owned bot_room row → delete → the same key re-appears as the
    /// placeholder before empty round 2. Old code: storedleft 1, exact_reads_after_delete 0, ok true.
    /// Now: exact readback finds it, it is deleted again, and success comes only after it stays absent.
    func testRecreatedBeforeSecondEmptyRoundIsRedeletedNeverFalseSuccess() async throws {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own]
        gw.extraProfiles = ["code-reviewer"]
        gw.onSleep = { n, g in if n == 1 { g.stored["thief", default: []].append(Self.placeholder) } }
        let url = tempLedger()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 6, every: 0, scope: "s",
                                              recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.deleteCalls, ["thief:own-exact-key", "thief:own-exact-key"])
        XCTAssertEqual(report.deleted.count, 1)
        XCTAssertEqual(report.redeleted.count, 1)
        XCTAssertEqual(gw.stored["thief"]?.map(\.id) ?? [], [], "no row may remain when ok")
        XCTAssertEqual(report.final.ledgerReadback["thief:own-exact-key"], .absent("not_found"))
        // Exact reads of the deleted key happened after the delete (old probe: 0).
        XCTAssertGreaterThanOrEqual(gw.presenceCalls.filter { $0 == "thief:own-exact-key" }.count, 3)
        let events = try SessionLedger.load(url).map { "\($0.event) \($0.key) \($0.roomId) \($0.scope)" }
        XCTAssertEqual(events, ["proven thief:own-exact-key hba-recreation-probe s", "deleted thief:own-exact-key hba-recreation-probe s",
                                "redeleted thief:own-exact-key hba-recreation-probe s"])
    }

    /// Ordinary control: delete, nothing re-appears → ok after two empty rounds, one delete, one readback per round.
    func testOrdinaryDeleteStaysAbsent() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own]
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 5, every: 0).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.deleteCalls, ["thief:own-exact-key"])
        XCTAssertTrue(report.redeleted.isEmpty)
        XCTAssertEqual(report.final.ledgerReadback, ["thief:own-exact-key": .absent("not_found")])
        XCTAssertFalse(report.ledgerDurable)
    }

    /// The late writer keeps re-creating the key through the whole budget → not ok, never "settled".
    func testRecreatedEveryRoundUntilBudgetEndsIsNotClean() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own]
        gw.onDelete = { p, id, g in g.stored[p, default: []].append(Self.placeholder) }
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 4, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.reason.contains("re-created"), report.reason)
        XCTAssertEqual(report.final.ledgerRecreated.map(\.entry.key), ["thief:own-exact-key"])
    }

    /// Beyond the budget: run 1 settles, THEN the placeholder appears. A fresh audit (new process: ledger
    /// loaded from the file) must fail, and a fresh cleanup from the ledger alone must delete it again.
    func testRecreationAfterTheRunIsCaughtByAuditAndCleanedFromTheLedger() async throws {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own]
        let url = tempLedger()
        defer { try? FileManager.default.removeItem(at: url) }
        let r1 = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 4, every: 0, scope: "s", recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(r1.ok, r1.reason)
        gw.stored["thief", default: []].append(Self.placeholder)  // late title accounting

        // Without the ledger the filtered discovery is blind (the BLOCK-003C false success):
        let blind = try await RoomSessionCleaner(manifest: [Self.room]).discover(gw)
        XCTAssertTrue(blind.isEmpty)
        // With the stored ledger (same scope) it is not clean:
        let keys = SessionLedger.keys(try SessionLedger.load(url), scope: "s", rooms: [Self.room.roomId])
        let audit = try await RoomSessionCleaner(manifest: [Self.room], ledger: keys).discover(gw)
        XCTAssertFalse(audit.isEmpty)
        XCTAssertEqual(audit.ledgerRecreated.map(\.entry.key), ["thief:own-exact-key"])
        // Another scope's ledger is never read back here.
        XCTAssertTrue(SessionLedger.keys(try SessionLedger.load(url), scope: "isolated").isEmpty)

        // Restart: an empty manifest + the ledger is enough to clean it (no title/source needed).
        let r2 = await RoomSessionCleaner(manifest: [], maxRounds: 4, every: 0, ledger: keys, scope: "s", recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(r2.ok, r2.reason)
        XCTAssertEqual(r2.redeleted.count, 1)
        XCTAssertEqual(gw.stored["thief"]?.map(\.id) ?? [], [])
        let after = try await RoomSessionCleaner(manifest: [Self.room], ledger: keys).discover(gw)
        XCTAssertTrue(after.isEmpty)
    }

    /// Unrelated `unknown`-source rows (not in the ledger) are never touched; a ledger key stored again in
    /// another shape (other source, messages, no count) or unprovable is unresolved and not deleted.
    func testUnrelatedUnknownUntouchedAndOtherShapesFailClosed() async throws {
        let unrelated = StoredSessionRow(profile: "thief", id: "user-aux-only", title: "Some title", source: "unknown", startedAt: 1_015)
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own, unrelated]
        gw.onSleep = { n, g in if n == 1 { g.stored["thief", default: []].append(Self.placeholder) } }
        let r = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 6, every: 0).run(gw)
        XCTAssertTrue(r.ok, r.reason)
        XCTAssertFalse(gw.deleteCalls.contains("thief:user-aux-only"))
        XCTAssertEqual(gw.stored["thief"]?.map(\.id), ["user-aux-only"])

        let entry = SessionLedgerEntry(event: "deleted", scope: "s", profile: "thief", id: "k", roomId: Self.room.roomId, evidence: "exact_title")
        for (row, count, override, kind) in [
            (StoredSessionRow(profile: "thief", id: "k", title: "Plan", source: "desktop", startedAt: 1_020), 0, nil as StoredIdPresence?, "ledger_key_present"),
            (StoredSessionRow(profile: "thief", id: "k", title: "", source: "unknown", startedAt: 1_020), 4, nil, "ledger_key_present"),
            (StoredSessionRow(profile: "thief", id: "k", title: "", source: "unknown", startedAt: 1_020), 0, .present(source: "unknown", messages: nil), "ledger_key_present"),
            (StoredSessionRow(profile: "thief", id: "k", title: "", source: "unknown", startedAt: 1_020), 0, .unknown("HTTP 503"), "ledger_readback_unknown"),
        ] {
            let g = FakeSessionGateway()
            g.stored["thief"] = [row]
            g.messageCounts["thief:k"] = count
            if let override { g.presenceOverride["thief:k"] = override }
            let rep = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 2, every: 0, ledger: [entry]).run(g)
            XCTAssertFalse(rep.ok, kind)
            XCTAssertEqual(g.deleteCalls, [], kind)
            XCTAssertEqual(rep.final.unresolved.map(\.kind), [kind], kind)
            XCTAssertEqual(g.stored["thief"]?.map(\.id), ["k"], kind)
        }
    }

    /// The placeholder while some runtime holds the id is deferred, deleted only once no runtime does.
    func testRecreatedWhileARuntimeHoldsTheIdIsDeferred() async {
        let entry = SessionLedgerEntry(event: "deleted", scope: "", profile: "thief", id: "k", roomId: Self.room.roomId, evidence: "exact_title")
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "k", title: "Essay", source: "unknown", startedAt: 1_020)]
        gw.live = [LiveSessionRow(runtimeId: "someone", sessionKey: "k", title: "Essay", status: "idle")]
        gw.onSleep = { n, g in if n == 2 { g.live = [] } }
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 6, every: 0, ledger: [entry]).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.closeCalls, [], "a runtime of a ledger key is never closed by the readback path")
        XCTAssertEqual(gw.deleteCalls, ["thief:k"], "no delete while the runtime held the id")
    }

    /// A proven key that cannot be recorded is neither closed nor deleted, and the run is not ok.
    func testLedgerWriteFailureBlocksCloseAndDelete() async {
        struct Broken: SessionLedgerRecorder { func record(_ e: SessionLedgerEntry) throws { throw CocoaError(.fileWriteNoPermission) } }
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [Self.own]
        gw.live = [LiveSessionRow(runtimeId: "r", sessionKey: Self.own.id, title: Self.own.title, status: "idle")]
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0, recorder: Broken()).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.reason.contains("ledger could not record"), report.reason)
        XCTAssertEqual(gw.closeCalls, [])
        XCTAssertEqual(gw.deleteCalls, [])
    }

    func testLedgerFileRoundTripAndScopeFilter() throws {
        let url = tempLedger()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SessionLedger.load(url), [])
        let a = SessionLedgerEntry(event: "proven", scope: "u", profile: "thief", id: "a", roomId: "hba-1", evidence: "exact_title", at: 1)
        let b = SessionLedgerEntry(event: "imported_deleted", scope: "u", profile: "code-reviewer", id: "b", roomId: "hba-2", evidence: "x", origin: "run312/cleanup-multi/scenario.json", at: 2)
        let c = SessionLedgerEntry(event: "proven", scope: "iso", profile: "default", id: "c", roomId: "hba-1", evidence: "x", at: 3)
        for e in [a, a.with(event: "deleted", at: 4), b, c] { try SessionLedger.append(e, to: url) }
        let all = try SessionLedger.load(url)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(SessionLedger.keys(all, scope: "u").map(\.key), ["thief:a", "code-reviewer:b"])
        XCTAssertEqual(SessionLedger.keys(all, scope: "u", rooms: ["hba-1"]).map(\.key), ["thief:a"])
        XCTAssertEqual(SessionLedger.keys(all, scope: "iso").map(\.key), ["default:c"])
        XCTAssertEqual(all[2].origin, "run312/cleanup-multi/scenario.json")
    }
}
