import Foundation
import XCTest
@testable import HermesGatewayKit

/// Review BLOCK-003: cleanup must find a room's member sessions while their title is still the
/// transient auto title (or empty), wait for working ones, never touch unrelated sessions, and never
/// report success with an owned or unprovable session left.
final class RoomSessionCleanupTests: XCTestCase {
    static let thief = RoomMember(memberId: "thief", profile: "thief", handle: "thief")
    static let reviewer = RoomMember(memberId: "code-reviewer", profile: "code-reviewer", handle: "code-reviewer")
    static let room = RoomManifestEntry(roomId: "hba-0db4eb2a7e68", name: "hba app hba-0db4eb2a7e68", createdAt: 1_000,
                                        members: [thief, reviewer])
    static let other = RoomManifestEntry(roomId: "hba-111111111111", name: "hba app hba-111111111111", createdAt: 1_000,
                                         members: [thief, reviewer])

    /// Exactly what `session.list` shows: `_shape_preview` = first user message head, newlines → spaces,
    /// `[:60] + "..."` (`hermes_state_common.py:148-157`).
    static func preview(_ firstMessage: String) -> String {
        let raw = String(firstMessage.prefix(63)).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return raw.count > 60 ? String(raw.prefix(60)) + "..." : raw
    }

    /// `derive_title`: first line, collapsed, ≤48 chars cut at a word boundary + "…".
    static func derivedTitle(_ firstMessage: String) -> String {
        let line = firstMessage.split(separator: "\n").first.map { $0.split(separator: " ").joined(separator: " ") } ?? ""
        guard line.count > 48 else { return line }
        let cut = String(line.prefix(48))
        let space = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) } ?? -1
        let base = space > 24 ? String(cut.prefix(space)) : cut
        return base.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—-")) + "…"
    }

    static func prompt(_ e: RoomManifestEntry, _ m: RoomMember) -> String {
        e.opening(for: m) + "\n\nNew messages in this thread since your last turn (oldest first):\n  User (user): hi\n\nRules for this Discussion:"
    }

    // MARK: - opening / classification

    func testOpeningMatchesDriverPromptShape() {
        XCTAssertEqual(Self.room.opening(for: Self.thief),
                       #"[Discussion: "hba app hba-0db4eb2a7e68"] You are @thief, one participant with @code-reviewer and the user."#)
        let solo = RoomManifestEntry(roomId: "hba-x", name: "n", createdAt: 0, members: [Self.thief])
        XCTAssertEqual(solo.opening(for: Self.thief), #"[Discussion: "n"] You are @thief, one participant with no other members and the user."#)
    }

    func testManifestRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hba-manifest-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try RoomManifest.append(Self.room, to: url)
        try RoomManifest.append(Self.other, to: url)
        try RoomManifest.append(Self.room, to: url)  // duplicate id: one entry
        XCTAssertEqual(try RoomManifest.load(url), [Self.room, Self.other])
    }

    /// The reviewer's repro: stored row with the instant derived title + live `working` runtime with the
    /// same key → both owned (the old exact-title / untitled-only filter found neither).
    func testAutoTitledWorkingSessionIsOwned() {
        let p = Self.prompt(Self.room, Self.thief)
        let row = StoredSessionRow(profile: "thief", id: "20261103_212222_df3c8f", title: Self.derivedTitle(p),
                                   preview: Self.preview(p), startedAt: 1_010)
        XCTAssertTrue(row.title.hasPrefix(#"[Discussion: "hba app hba-0db4eb2a7e68"]"#), row.title)
        let live = LiveSessionRow(runtimeId: "bd2fa799", sessionKey: row.id, title: row.title, status: "working")
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: [row], live: [live])
        XCTAssertEqual(d.ownedStored.map(\.row.id), [row.id])
        XCTAssertEqual(d.ownedStored.first?.evidence, "opening_preview")
        XCTAssertEqual(d.ownedStored.first?.memberId, "thief")
        XCTAssertEqual(d.ownedLive.map(\.row.runtimeId), ["bd2fa799"])
        XCTAssertTrue(d.unresolved.isEmpty)
    }

    func testDerivedTitleAloneAndUntitledPreviewAndExactTitleAreOwned() {
        let p = Self.prompt(Self.room, Self.reviewer)
        let rows = [
            StoredSessionRow(profile: "code-reviewer", id: "a", title: Self.derivedTitle(p), preview: "", startedAt: 1_005),
            StoredSessionRow(profile: "code-reviewer", id: "b", title: "", preview: Self.preview(p), startedAt: 1_005),
            StoredSessionRow(profile: "thief", id: "c", title: "Group: hba-0db4eb2a7e68", preview: "", startedAt: 1_005),
        ]
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: rows, live: [])
        XCTAssertEqual(d.ownedStored.map(\.row.id), ["a", "b", "c"])
        XCTAssertEqual(d.ownedStored.map(\.evidence), ["opening_derived_title", "opening_preview", "exact_title"])
        XCTAssertTrue(d.unresolved.isEmpty)
    }

    /// Unrelated controls: another room (manifest or not), another source, the user's own sessions,
    /// a Group title of a non-test room, a member/profile mismatch.
    func testUnrelatedSessionsAreNeverOwned() {
        let pOther = Self.prompt(Self.other, Self.thief)
        let foreignHba = #"[Discussion: "hba M2 multi 1793708742"] You are @thief, one participant with @code-reviewer"#
        let rows = [
            StoredSessionRow(profile: "thief", id: "other-room", title: "", preview: Self.preview(pOther), startedAt: 1_005),
            StoredSessionRow(profile: "thief", id: "other-group", title: "Group: hba-111111111111", startedAt: 1_005),
            StoredSessionRow(profile: "thief", id: "user-room", title: "Group: my-room", startedAt: 1_005),
            StoredSessionRow(profile: "thief", id: "foreign-hba", title: "", preview: Self.preview(foreignHba), startedAt: 1_005),
            StoredSessionRow(profile: "thief", id: "tui", title: "", preview: Self.preview(Self.prompt(Self.room, Self.thief)),
                             source: "tui", startedAt: 1_005),
            // a 1:1 Bot Chat session is not a room session (source != bot_room)
            StoredSessionRow(profile: "thief", id: "chat", title: "Bot Chat", preview: "hello", source: "tui", startedAt: 1_005),
            // bot_room rows outside the scope: before the first test room, or in a profile that is no member
            StoredSessionRow(profile: "thief", id: "old-llm", title: "History of Lighthouses", startedAt: 10),
            StoredSessionRow(profile: "default", id: "nonmember-llm", title: "History of Lighthouses", startedAt: 1_005),
        ]
        let live = [LiveSessionRow(runtimeId: "r1", sessionKey: "other-room", title: "", status: "idle"),
                    LiveSessionRow(runtimeId: "r2", sessionKey: "chat", title: "Bot Chat", status: "working")]
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: rows, live: live)
        XCTAssertTrue(d.ownedStored.isEmpty, "\(d.ownedStored)")
        XCTAssertTrue(d.ownedLive.isEmpty)
        XCTAssertTrue(d.unresolved.isEmpty, "\(d.unresolved)")
        // Reported only: the other room's preview + its Group title + the foreign hba preview.
        XCTAssertEqual(d.foreign.map { String($0.split(separator: " ")[0]) }, ["thief:other-room", "thief:other-group", "thief:foreign-hba"])
    }

    func testUnprovableRowsAreUnresolvedNotOwned() {
        let p = Self.prompt(Self.room, Self.thief)
        let rows = [
            // names the room but the row's profile is a member whose handle does not match
            StoredSessionRow(profile: "code-reviewer", id: "mismatch", title: "", preview: Self.preview(p), startedAt: 1_005),
            // started long before the room existed
            StoredSessionRow(profile: "thief", id: "old", title: "", preview: Self.preview(p), startedAt: 10),
            // nothing to attribute, but started after the first test room
            StoredSessionRow(profile: "thief", id: "empty", title: "", preview: "", startedAt: 1_005),
        ]
        let live = [LiveSessionRow(runtimeId: "t1", sessionKey: "unknown", title: "Group: hba-0db4eb2a7e68", status: "idle")]
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: rows, live: live)
        XCTAssertTrue(d.ownedStored.isEmpty)
        XCTAssertEqual(Set(d.unresolved.map(\.kind)), ["member_mismatch", "predates_room", "unattributed_empty", "title_only_live"])
    }

    func testSameNameRoomMakesPreviewAmbiguous() {
        let p = Self.prompt(Self.room, Self.thief)
        let row = StoredSessionRow(profile: "thief", id: "x", title: "", preview: Self.preview(p), startedAt: 1_005)
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: [row], live: [], otherRoomNames: [Self.room.name])
        XCTAssertTrue(d.ownedStored.isEmpty)
        XCTAssertEqual(d.unresolved.map(\.kind), ["ambiguous_name"])
        // A long name that the 60-char preview cuts → cannot be proven.
        let long = RoomManifestEntry(roomId: "hba-long", name: String(repeating: "hba long name ", count: 5), createdAt: 1_000, members: [Self.thief])
        let r2 = StoredSessionRow(profile: "thief", id: "y", title: "", preview: Self.preview(Self.prompt(long, Self.thief)), startedAt: 1_005)
        XCTAssertEqual(RoomSessionClassifier.classify(manifest: [long], stored: [r2], live: []).unresolved.map(\.kind), ["truncated_provenance"])
    }

    // MARK: - cleaner rounds

    func testTransientWorkingThenGroupIdleIsClosedDeletedAndSettles() async {
        let gw = FakeSessionGateway()
        let p = Self.prompt(Self.room, Self.thief)
        let id = "20261103_212222_df3c8f"
        // Round 1: first turn still working, stored title = instant derived title.
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: id, title: Self.derivedTitle(p), preview: Self.preview(p), startedAt: 1_010)]
        gw.live = [LiveSessionRow(runtimeId: "bd2fa799", sessionKey: id, title: Self.derivedTitle(p), status: "working")]
        // Plus unrelated controls that must survive.
        gw.stored["thief", default: []].append(StoredSessionRow(profile: "thief", id: "user-1", title: "Group: my-room", startedAt: 1_005))
        gw.stored["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "other",
                                                       preview: Self.preview(Self.prompt(Self.other, Self.reviewer)), startedAt: 1_005)]
        gw.live.append(LiveSessionRow(runtimeId: "u1", sessionKey: "user-1", title: "Group: my-room", status: "idle"))
        // After round 1's sleep: the turn ends, the pending Group title lands, runtime idle.
        gw.onSleep = { n, g in
            if n == 1 {
                g.stored["thief"] = g.stored["thief"]!.map { $0.id == id ? StoredSessionRow(profile: "thief", id: id, title: "Group: hba-0db4eb2a7e68",
                                                                                         preview: $0.preview, startedAt: 1_010) : $0 }
                g.live = g.live.map { $0.runtimeId == "bd2fa799" ? LiveSessionRow(runtimeId: "bd2fa799", sessionKey: id, title: "Group: hba-0db4eb2a7e68", status: "idle") : $0 }
            }
        }
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 8, every: 0).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.closeCalls, ["bd2fa799"])        // only once idle
        XCTAssertEqual(gw.deleteCalls, ["thief:\(id)"])    // only after its runtime was closed
        XCTAssertEqual(gw.firstCloseRound, 2)
        XCTAssertTrue(gw.stored["thief"]!.contains { $0.id == "user-1" })
        XCTAssertEqual(gw.stored["code-reviewer"]!.map(\.id), ["other"])
        XCTAssertTrue(gw.live.contains { $0.runtimeId == "u1" })
        XCTAssertTrue(report.final.isEmpty)
    }

    /// Immediate cleanup while the member is still working for the whole budget must FAIL, not report
    /// success from a narrow filter.
    func testStillWorkingAtEndIsNotClean() async {
        let gw = FakeSessionGateway()
        let p = Self.prompt(Self.room, Self.thief)
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "s1", title: Self.derivedTitle(p), preview: Self.preview(p), startedAt: 1_010)]
        gw.live = [LiveSessionRow(runtimeId: "r1", sessionKey: "s1", title: Self.derivedTitle(p), status: "working")]
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.reason.contains("still working"), report.reason)
        XCTAssertTrue(gw.closeCalls.isEmpty)
        XCTAssertTrue(gw.deleteCalls.isEmpty)
        XCTAssertEqual(report.final.ownedLive.count, 1)
    }

    func testDelete4023IsRetriedInLaterRounds() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "s1", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
        gw.deleteFailures["thief:s1"] = 2   // write guard still held for two rounds
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 8, every: 0).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.deleteCalls, ["thief:s1", "thief:s1", "thief:s1"])
        XCTAssertEqual(report.deleted.count, 1)
    }

    func testPersistent4023AndUnresolvedFail() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "s1", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
        gw.deleteFailures["thief:s1"] = 100  // live in another backend
        var report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.lastErrors["thief:s1"]?.contains("4023"), true)

        let gw2 = FakeSessionGateway()
        gw2.live = [LiveSessionRow(runtimeId: "t1", sessionKey: "nope", title: "Group: hba-0db4eb2a7e68", status: "idle")]
        report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0).run(gw2)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(gw2.closeCalls.isEmpty, "a title-only runtime is never closed")
        XCTAssertEqual(report.final.unresolved.map(\.kind), ["title_only_live"])
    }

    func testNeedsConsecutiveEmptyRounds() async {
        let gw = FakeSessionGateway()
        // Empty in round 1, a session shows up before round 2 (still settling) → must be handled.
        gw.onSleep = { n, g in
            if n == 1 { g.stored["thief"] = [StoredSessionRow(profile: "thief", id: "late", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)] }
        }
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 6, every: 0, settleRounds: 2).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(gw.deleteCalls, ["thief:late"])
    }

    // MARK: - review run309 BLOCK-003A: a bare session_key never proves which profile a runtime is

    /// The reviewer's probe: `thief:same-key` owned (exact title), `code-reviewer:same-key` foreign
    /// (`Group: unrelated-user-room`), two live runtimes with that key and their own titles. Nothing may be
    /// closed (the old join closed both), the owned row's delete waits, and the run fails.
    func testSameKeyInTwoProfilesNeverClosesEitherRuntime() async {
        let probe = RoomManifestEntry(roomId: "hba-cleanup-probe", name: "hba cleanup probe", createdAt: 1_000,
                                      members: [Self.thief, Self.reviewer])
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "same-key", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        gw.stored["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "same-key", title: "Group: unrelated-user-room", startedAt: 1_010)]
        gw.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "same-key", title: "Group: hba-cleanup-probe", status: "idle"),
                   LiveSessionRow(runtimeId: "foreign-runtime", sessionKey: "same-key", title: "Group: unrelated-user-room", status: "idle")]
        let report = await RoomSessionCleaner(manifest: [probe], maxRounds: 3, every: 0).run(gw)
        XCTAssertFalse(report.ok, report.reason)
        XCTAssertEqual(gw.closeCalls, [])
        XCTAssertEqual(gw.deleteCalls, [], "the owned row is deferred while a runtime holds its id")
        XCTAssertEqual(Set(report.final.unresolved.map(\.ref)), ["own-runtime", "foreign-runtime"])
        XCTAssertEqual(Set(report.final.unresolved.map(\.kind)), ["key_collision"])
        XCTAssertEqual(gw.live.count, 2)
        XCTAssertEqual(gw.stored["code-reviewer"]?.map(\.id), ["same-key"])
    }

    /// One runtime only, but the id is also stored in a profile that is NOT a room member (found through
    /// `profiles.list`) → still unprovable; and the same id in a non-bot_room row counts too.
    func testCollisionWithNonMemberProfileOrOtherSourceIsUnresolved() async {
        for foreignRow in [StoredSessionRow(profile: "default", id: "k1", title: "Group: my-room", startedAt: 1_010),
                           StoredSessionRow(profile: "default", id: "k1", title: "Plan trip", preview: "plan", source: "tui", startedAt: 1_010)] {
            let gw = FakeSessionGateway()
            gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "k1", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
            gw.stored["default"] = [foreignRow]
            gw.live = [LiveSessionRow(runtimeId: "r", sessionKey: "k1", title: "Group: hba-0db4eb2a7e68", status: "idle")]
            let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 2, every: 0).run(gw)
            XCTAssertFalse(report.ok)
            XCTAssertEqual(gw.closeCalls, [])
            XCTAssertEqual(gw.deleteCalls, [])
            XCTAssertEqual(report.final.unresolved.map(\.kind), ["key_collision"])
            XCTAssertTrue(report.final.scannedProfiles.contains("default"))
        }
    }

    /// The id is stored in one profile only, but two runtimes hold it (the other one's row is in no scanned
    /// profile, e.g. not flushed yet or another home), both with this room's title → neither is closed.
    func testTwoRuntimesOnAUniqueIdAreUnresolved() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "k2", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
        gw.live = [LiveSessionRow(runtimeId: "a", sessionKey: "k2", title: "Group: hba-0db4eb2a7e68", status: "idle"),
                   LiveSessionRow(runtimeId: "b", sessionKey: "k2", title: "Group: hba-0db4eb2a7e68", status: "idle")]
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 2, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(gw.closeCalls, [])
        XCTAssertEqual(gw.deleteCalls, [])
        XCTAssertEqual(report.final.unresolved.map(\.kind), ["key_collision", "key_collision"])
    }

    /// Unique id, one runtime, but its live title points at another room → positive foreign evidence:
    /// not closed. Controls: empty live title, the same stored title, and the room's Group title over a
    /// derived stored title (phase change between the two reads) are all owned.
    func testLiveTitleMustAgreeWithTheOwnedRow() {
        let p = Self.prompt(Self.room, Self.thief)
        let row = StoredSessionRow(profile: "thief", id: "k", title: Self.derivedTitle(p), preview: Self.preview(p), startedAt: 1_010)
        for (title, owned) in [("Group: unrelated-user-room", false), ("Group: hba-111111111111", false),
                               (Self.derivedTitle(Self.prompt(Self.other, Self.thief)), false),
                               ("", true), (row.title, true), ("Group: hba-0db4eb2a7e68", true)] {
            let live = LiveSessionRow(runtimeId: "r", sessionKey: "k", title: title, status: "idle")
            let d = RoomSessionClassifier.classify(manifest: [Self.room, Self.other], stored: [row], live: [live])
            XCTAssertEqual(d.ownedStored.map(\.row.id), ["k"], title)
            XCTAssertEqual(d.ownedLive.map(\.row.runtimeId), owned ? ["r"] : [], title)
            XCTAssertEqual(d.unresolved.map(\.kind), owned ? [] : ["live_title_conflict"], title)
        }
    }

    /// Two owned rows with the same id in two member profiles: with a runtime on that id nothing is closed
    /// or deleted; once no runtime holds it, both rows are deleted (each delete is profile-scoped).
    func testDuplicateOwnedIdsAcrossProfiles() async {
        let gw = FakeSessionGateway()
        gw.stored["thief"] = [StoredSessionRow(profile: "thief", id: "dup", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
        gw.stored["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "dup", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)]
        gw.live = [LiveSessionRow(runtimeId: "r", sessionKey: "dup", title: "Group: hba-0db4eb2a7e68", status: "idle")]
        var report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 2, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(gw.closeCalls, [])
        XCTAssertEqual(gw.deleteCalls, [])
        XCTAssertEqual(report.final.unresolved.map(\.kind), ["key_collision"])

        gw.live = []
        report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 4, every: 0).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(Set(gw.deleteCalls), ["thief:dup", "code-reviewer:dup"])
    }

    // MARK: - review run309 BLOCK-003B: no proof either way is not "absent"

    /// bot_room row of a member profile, in the test window, with an llm title and an empty preview: it
    /// names no room and has no positive foreign proof → unresolved, never closed/deleted, run fails —
    /// also while its runtime is working with that title.
    func testLlmTitleWithEmptyPreviewInWindowIsUnresolved() async {
        let row = StoredSessionRow(profile: "thief", id: "llm", title: "History of Lighthouses", preview: "", startedAt: 1_010)
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: [row], live: [])
        XCTAssertEqual(d.unresolved.map(\.kind), ["unattributed"])
        XCTAssertTrue(d.ownedStored.isEmpty)

        let gw = FakeSessionGateway()
        gw.stored["thief"] = [row]
        gw.live = [LiveSessionRow(runtimeId: "w", sessionKey: "llm", title: "History of Lighthouses", status: "working")]
        let report = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0).run(gw)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.reason.contains("unattributed"), report.reason)
        XCTAssertEqual(gw.closeCalls, [])
        XCTAssertEqual(gw.deleteCalls, [])

        // Same row with no runtime at all: still not ok.
        let gw2 = FakeSessionGateway()
        gw2.stored["thief"] = [row]
        let r2 = await RoomSessionCleaner(manifest: [Self.room], maxRounds: 3, every: 0).run(gw2)
        XCTAssertFalse(r2.ok)
        XCTAssertEqual(r2.final.unresolved.map(\.kind), ["unattributed"])
    }

    /// Controls around the same shape: an llm title over a valid opening preview is owned; a preview that is
    /// no room opening is unresolved; positive foreign proof (another room's Group title or opening) is
    /// reported and left alone; an opening of this room with another room's Group title is a conflict.
    func testProvenanceControlsAroundUnattributedRows() {
        let p = Self.prompt(Self.room, Self.thief)
        let rows = [
            StoredSessionRow(profile: "thief", id: "llm-opening", title: "History of Lighthouses", preview: Self.preview(p), startedAt: 1_010),
            StoredSessionRow(profile: "thief", id: "odd-preview", title: "", preview: "please summarise this", startedAt: 1_010),
            StoredSessionRow(profile: "thief", id: "llm-foreign", title: "History of Lighthouses",
                             preview: Self.preview(#"[Discussion: "Lighthouse club"] You are @thief, one participant with @x"#), startedAt: 1_010),
            StoredSessionRow(profile: "thief", id: "user-group", title: "Group: my-room", startedAt: 1_010),
            StoredSessionRow(profile: "thief", id: "conflict", title: "Group: my-room", preview: Self.preview(p), startedAt: 1_010),
        ]
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: rows, live: [])
        XCTAssertEqual(d.ownedStored.map(\.row.id), ["llm-opening"])
        XCTAssertEqual(d.ownedStored.first?.evidence, "opening_preview")
        XCTAssertEqual(d.unresolved.map { "\($0.kind) \($0.ref)" }, ["unattributed thief:odd-preview", "conflicting_provenance thief:conflict"])
        XCTAssertTrue(d.foreign.isEmpty, "non-hba foreign rows are skipped silently: \(d.foreign)")
    }

    /// An exact Group title of a test room in a profile that is not a member of that room is not owned.
    func testExactTitleInNonMemberProfileIsUnresolved() {
        let row = StoredSessionRow(profile: "default", id: "x", title: "Group: hba-0db4eb2a7e68", startedAt: 1_010)
        let d = RoomSessionClassifier.classify(manifest: [Self.room], stored: [row], live: [])
        XCTAssertTrue(d.ownedStored.isEmpty)
        XCTAssertEqual(d.unresolved.map(\.kind), ["member_mismatch"])
    }
}

/// In-memory `RoomSessionGateway`: delete removes the row (4023 while `deleteFailures` > 0 or while a
/// live runtime holds the key), close removes the runtime.
final class FakeSessionGateway: RoomSessionGateway, @unchecked Sendable {
    let lock = NSLock()
    var stored: [String: [StoredSessionRow]] = [:]
    var live: [LiveSessionRow] = []
    var deleteFailures: [String: Int] = [:]
    var closeCalls: [String] = []
    var deleteCalls: [String] = []
    var sleeps = 0
    var firstCloseRound: Int?
    var onSleep: ((Int, FakeSessionGateway) -> Void)?

    /// Profiles `profiles.list` reports besides the ones that have rows.
    var extraProfiles: [String] = []
    func profileNames() async throws -> [String] { lock.withLock { stored.keys.sorted() + extraProfiles } }
    func storedRows(profile: String) async throws -> [StoredSessionRow] { lock.withLock { stored[profile] ?? [] } }
    /// Rows in a profile's store that its listing does not show (kanban/tool/oneshot, archived, out of window).
    var unlisted: [String: [StoredSessionRow]] = [:]
    /// `"profile:id"` → forced exact-lookup answer.
    var presenceOverride: [String: StoredIdPresence] = [:]
    var presenceCalls: [String] = []
    /// `"profile:id"` → `message_count` the exact lookup reports (default 0).
    var messageCounts: [String: Int] = [:]
    /// Called after every successful delete (inside the lock): models a late writer re-creating the id.
    var onDelete: ((String, String, FakeSessionGateway) -> Void)?
    func storedIdPresence(profile: String, id: String) async -> StoredIdPresence {
        lock.withLock {
            presenceCalls.append("\(profile):\(id)")
            if let o = presenceOverride["\(profile):\(id)"] { return o }
            if let r = ((stored[profile] ?? []) + (unlisted[profile] ?? [])).first(where: { $0.id == id }) {
                return .present(source: r.source, messages: messageCounts["\(profile):\(id)"] ?? 0)
            }
            return .absent("not_found")
        }
    }
    func liveRows() async throws -> [LiveSessionRow] { lock.withLock { live } }
    func close(runtimeId: String) async throws -> Bool {
        lock.withLock {
            closeCalls.append(runtimeId)
            if firstCloseRound == nil { firstCloseRound = sleeps + 1 }
            let had = live.contains { $0.runtimeId == runtimeId }
            live.removeAll { $0.runtimeId == runtimeId }
            return had
        }
    }
    func delete(profile: String, id: String) async throws {
        try lock.withLock {
            let key = "\(profile):\(id)"
            deleteCalls.append(key)
            if let n = deleteFailures[key], n > 0 {
                deleteFailures[key] = n - 1
                throw GatewayClient.RPCError(code: 4023, message: "cannot delete an active session", data: nil)
            }
            if live.contains(where: { $0.sessionKey == id }) {
                throw GatewayClient.RPCError(code: 4023, message: "cannot delete an active session", data: nil)
            }
            guard stored[profile]?.contains(where: { $0.id == id }) == true else {
                throw GatewayClient.RPCError(code: 4007, message: "session not found", data: nil)
            }
            stored[profile]?.removeAll { $0.id == id }
            onDelete?(profile, id, self)
        }
    }
    func sleep(seconds: Double) async throws {
        let (n, hook) = lock.withLock { () -> (Int, ((Int, FakeSessionGateway) -> Void)?) in sleeps += 1; return (sleeps, onSleep) }
        if let hook { lock.withLock { hook(n, self) } }
    }
}
