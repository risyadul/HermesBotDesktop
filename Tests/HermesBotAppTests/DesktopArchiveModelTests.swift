import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// E4 / D17: the Desktop archive's model (listing, import, remove, persistence, sidebar rows) and the
/// "Continue in a New Room" helpers. Fake calls and an in-memory store; the file store writes to a temp dir.
@MainActor
final class DesktopArchiveModelTests: XCTestCase {
    final class MemoryStore: DesktopArchiveStoring {
        var stored: [DesktopArchiveRoom]
        var saves = 0
        var failing = false
        init(_ rooms: [DesktopArchiveRoom] = []) { stored = rooms }
        func load() -> [DesktopArchiveRoom] { stored }
        func save(_ rooms: [DesktopArchiveRoom]) throws {
            saves += 1
            if failing { throw CocoaError(.fileWriteNoPermission) }
            stored = rooms
        }
    }

    private func room(_ id: String, name: String? = nil, at seconds: Double = 1_700_000_000, messages: Int = 2,
                      members: [DesktopArchiveMember] = [.init(name: "alice"), .init(name: "bob")], omitted: Int = 0) -> DesktopArchiveRoom {
        let msgs = (0..<messages).map { i in
            DesktopArchiveMessage(id: "\(id)-\(i)", fromUser: i == 0, author: i == 0 ? "You" : "alice", text: "message \(i)",
                                  at: Date(timeIntervalSince1970: seconds + Double(i)))
        }
        return DesktopArchiveRoom(id: id, name: name ?? id, members: members, messages: msgs, omitted: omitted)
    }

    private func bot(_ name: String) -> Bot { Bot(["name": .string(name)])! }

    private func profilesList(_ rooms: [String: JSONValue]) -> JSONValue {
        ["profiles": [["name": "default", "is_default": true,
                       "ui_meta": ["hermes-bots-groups": ["version": 3, "rooms": .object(rooms)]]]]]
    }

    // MARK: listing

    func testListingWithoutAConnectionExplainsWhy() async {
        let m = DesktopArchiveModel(store: MemoryStore())
        await m.list(call: nil)
        guard case .failed(let text) = m.listing else { return XCTFail("expected a failure") }
        XCTAssertTrue(text.contains("Connect to Hermes"))
    }

    func testListingReadsProfilesListOnly() async {
        let m = DesktopArchiveModel(store: MemoryStore())
        let calls = CallRecorder()
        let reply = profilesList(["id:r": ["name": "Standup", "log": [["from": ["kind": "user", "name": "You"], "text": "hi", "at": 1]]]])
        await m.list { method, _ in
            await calls.add(method)
            return reply
        }
        guard case .loaded(let rooms) = m.listing else { return XCTFail("expected rooms") }
        XCTAssertEqual(rooms.map(\.name), ["Standup"])
        let methods = await calls.methods
        XCTAssertEqual(methods, ["profiles.list"], "read-only: never profiles.configure, never groups.create")
        XCTAssertTrue(m.rooms.isEmpty, "listing imports nothing")
    }

    func testListingFailureIsShown() async {
        let m = DesktopArchiveModel(store: MemoryStore())
        await m.list { _, _ in throw GatewayClient.ClientError.timeout("profiles.list") }
        guard case .failed(let text) = m.listing else { return XCTFail("expected a failure") }
        XCTAssertTrue(text.hasPrefix("Could not read Hermes Desktop's group chats"))
    }

    func testAResetListingIsNotOverwrittenByALateReply() async {
        let m = DesktopArchiveModel(store: MemoryStore())
        let gate = Gate()
        let reply = profilesList([:])
        let task = Task { await m.list { _, _ in await gate.wait(); return reply } }
        while m.listing != .loading { await Task.yield() }
        m.resetListing()  // the sheet closed
        await gate.open()
        await task.value
        XCTAssertEqual(m.listing, .idle)
    }

    // MARK: import / remove

    func testImportAddsReplacesAndPersistsNewestFirst() {
        let store = MemoryStore([room("a", at: 100)])
        let m = DesktopArchiveModel(store: store)
        XCTAssertEqual(m.rooms.map(\.id), ["a"], "the saved archive is loaded at start")
        XCTAssertNil(m.importRooms([room("b", at: 300), room("a", name: "A v2", at: 200)]))
        XCTAssertEqual(m.rooms.map(\.id), ["b", "a"])
        XCTAssertEqual(m.room("a")?.name, "A v2", "re-importing replaces the older copy")
        XCTAssertEqual(store.stored.map(\.id), ["b", "a"])
        XCTAssertTrue(m.isImported("b"))
        XCTAssertNil(m.importRooms([]))
        XCTAssertEqual(store.saves, 1, "nothing chosen, nothing saved")
    }

    func testRemoveOnlyTouchesTheLocalArchive() {
        let store = MemoryStore([room("a"), room("b", at: 1)])
        let m = DesktopArchiveModel(store: store)
        XCTAssertNil(m.remove("a"))
        XCTAssertEqual(m.rooms.map(\.id), ["b"])
        XCTAssertEqual(store.stored.map(\.id), ["b"])
        XCTAssertNil(m.remove("nope"))
        XCTAssertEqual(store.saves, 1)
    }

    func testSaveFailureIsReportedAndTheRoomsStayForTheSession() {
        let store = MemoryStore()
        store.failing = true
        let m = DesktopArchiveModel(store: store)
        let error = m.importRooms([room("a")])
        XCTAssertNotNil(error)
        XCTAssertEqual(m.rooms.map(\.id), ["a"])
    }

    func testTheArchiveIsCappedAtTheRoomLimit() {
        let m = DesktopArchiveModel(store: MemoryStore())
        m.importRooms((0..<100).map { room("r\($0)", at: Double($0)) })
        XCTAssertEqual(m.rooms.count, DesktopGroupArchive.maxRooms)
        XCTAssertEqual(m.rooms.first?.id, "r99")
    }

    // MARK: sidebar

    func testSidebarRowsFollowTheDisclosureAndTheFilter() {
        let m = DesktopArchiveModel(store: MemoryStore([room("id:1", name: "Design", members: [.init(name: "alice", handle: "ally")]),
                                                        room("id:2", name: "Standup", at: 1)]))
        XCTAssertEqual(m.sidebarRooms(query: "").map(\.id), ["id:1", "id:2"])
        XCTAssertEqual(m.sidebarRooms(query: "@ally").map(\.id), ["id:1"], "members' handles match")
        m.expanded = false
        XCTAssertEqual(m.sidebarRooms(query: ""), [], "collapsed")
        XCTAssertEqual(m.sidebarRooms(query: "stand").map(\.id), ["id:2"], "a filter shows matches even when collapsed")
    }

    // MARK: file store

    func testFileStoreRoundTripsPrivatelyAndRemovesTheFileWhenEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DesktopArchiveFileStore(url: dir.appendingPathComponent("Desktop Archive/archive.json"))
        XCTAssertEqual(store.load(), [], "no file yet")
        let rooms = [room("a"), room("b", at: 5)]
        try store.save(rooms)
        XCTAssertEqual(store.load(), rooms)
        let perms = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testFileStoreIgnoresGarbage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("archive.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(DesktopArchiveFileStore(url: url).load(), [])
    }

    // MARK: continue in a new room

    func testContinuationMatchesBotsByNameThenHandle() {
        let r = room("a", members: [.init(name: "alice"), .init(name: "remote-bob", handle: "bob"), .init(name: "gone"),
                                    .init(name: "alice")])
        let c = DesktopArchivePresentation.continuation(r, bots: [bot("alice"), bot("bob"), bot("carol")])
        XCTAssertEqual(c.members.map(\.profile), ["alice", "bob"])
        XCTAssertEqual(c.missing, ["gone"])
    }

    func testContinueNeedsTwoLocalBotsAConnectionAndGroupChat() {
        let r = room("a")
        let bots = [bot("alice"), bot("bob")]
        XCTAssertTrue(DesktopArchivePresentation.canContinue(r, bots: bots, connected: true, groupsAvailable: true))
        XCTAssertFalse(DesktopArchivePresentation.canContinue(r, bots: bots, connected: false, groupsAvailable: true))
        XCTAssertFalse(DesktopArchivePresentation.canContinue(r, bots: bots, connected: true, groupsAvailable: false))
        XCTAssertFalse(DesktopArchivePresentation.canContinue(r, bots: [bot("alice")], connected: true, groupsAvailable: true))
    }

    func testCarryOverQuotesTheLastMessages() {
        let long = String(repeating: "z", count: 2_000)
        var messages = (0..<9).map { i in
            DesktopArchiveMessage(id: "\(i)", fromUser: false, author: "alice", text: "line \(i)\nsecond", at: nil)
        }
        messages.append(DesktopArchiveMessage(id: "long", fromUser: true, author: "You", text: long, at: nil))
        let r = DesktopArchiveRoom(id: "a", name: "Design", members: [], messages: messages, omitted: 0)
        let text = DesktopArchivePresentation.carryOver(r)
        XCTAssertTrue(text.hasPrefix("Let's continue our Hermes Desktop group chat \"Design\"."))
        XCTAssertFalse(text.contains("line 3"), "only the last \(DesktopArchivePresentation.carryOverMessages) messages")
        XCTAssertTrue(text.contains("> line 4\n> second"))
        XCTAssertTrue(text.contains("> **You:**"))
        XCTAssertFalse(text.contains(long), "long messages are shortened")
        XCTAssertLessThan(text.utf8.count, RoomComposer.maxTextBytes)
    }

    func testPrefillNameAndSummary() {
        let r = room("a", name: String(repeating: "n", count: 64), messages: 3, omitted: 4)
        let prefill = DesktopArchivePresentation.prefill(r, bots: [bot("alice"), bot("bob")])
        XCTAssertEqual(prefill.name.count, DesktopGroupArchive.maxNameChars)
        XCTAssertTrue(prefill.name.hasSuffix(" (continued)"))
        XCTAssertEqual(prefill.members, ["alice", "bob"])
        XCTAssertEqual(DesktopArchivePresentation.summary(r), "7 messages · 2 bots")
        XCTAssertEqual(DesktopArchivePresentation.summary(room("b", messages: 1, members: [.init(name: "x")])), "1 message · 1 bot")
    }

    // MARK: app model (nothing is written: no import goes through the app's own archive here)

    func testContinueOpensThePrefilledCreateSheetAndCloseClearsIt() async {
        let app = AppModel()
        app.bots = [bot("alice"), bot("bob")]
        app.continueArchivedRoom(room("a", name: "Design"))
        XCTAssertTrue(app.showCreateRoom)
        XCTAssertEqual(app.createRoomPrefill?.name, "Design (continued)")
        XCTAssertEqual(app.createRoomPrefill?.members, ["alice", "bob"])
        let error = await app.createRoomFromSheet(name: "Design (continued)", members: [])
        XCTAssertEqual(error, "not connected", "nothing is created without a backend")
        app.closeCreateRoom()
        XCTAssertFalse(app.showCreateRoom)
        XCTAssertNil(app.createRoomPrefill)
    }

    func testRemovingTheShownRoomClearsTheSelection() {
        let app = AppModel()
        app.selection = .archive("not-imported")
        app.removeArchivedRoom("not-imported")
        XCTAssertNil(app.selection)
    }

    func testImportSheetWithoutAConnectionSaysSo() async {
        let app = AppModel()
        app.openDesktopImport()
        XCTAssertTrue(app.showDesktopImport)
        for _ in 0..<1_000 {
            if case .failed = app.desktopArchive.listing { break }
            await Task.yield()
        }
        guard case .failed = app.desktopArchive.listing else { return XCTFail("expected the not-connected message") }
        app.closeDesktopImport()
        XCTAssertFalse(app.showDesktopImport)
        XCTAssertEqual(app.desktopArchive.listing, .idle)
    }
}

private actor CallRecorder {
    private(set) var methods: [String] = []
    func add(_ method: String) { methods.append(method) }
}

/// Holds a fake call until opened.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
