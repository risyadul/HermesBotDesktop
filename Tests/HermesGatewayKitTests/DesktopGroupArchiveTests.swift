import Foundation
import XCTest
@testable import HermesGatewayKit

/// E4 / D17: parsing Hermes Desktop's `ui_meta["hermes-bots-groups"]` projection (`group-chat.ts`
/// `groupChatSyncSnapshot`), including malformed and oversized input. Pure; the `load` test uses a fake call.
final class DesktopGroupArchiveTests: XCTestCase {
    private func message(_ text: JSONValue, kind: String = "member", name: String = "alice", at: Double = 1_700_000_000_000,
                         id: String? = nil, truncated: Bool? = nil, thread: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["from": ["kind": .string(kind), "name": .string(name)], "text": text, "at": .number(at)]
        if let id { o["id"] = .string(id) }
        if let truncated { o["truncated"] = .bool(truncated) }
        if let thread { o["thread"] = .string(thread) }
        return .object(o)
    }

    private func room(name: String?, log: [JSONValue], members: [JSONValue] = [["name": "alice"], ["name": "bob", "handle": "bobby"]],
                      omitted: Int? = nil, revision: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["log": .array(log), "members": .array(members)]
        if let name { o["name"] = .string(name) }
        if let omitted { o["omitted"] = .number(Double(omitted)) }
        if let revision { o["revision"] = .number(Double(revision)) }
        return .object(o)
    }

    private func snapshot(_ rooms: [String: JSONValue], version: Int = 3, deleted: [String: JSONValue]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["version": .number(Double(version)), "rooms": .object(rooms), "updatedAt": 1]
        if let deleted { o["deleted"] = .object(deleted) }
        return .object(o)
    }

    func testParsesV3RoomsMembersAndMessages() throws {
        let rooms = DesktopGroupArchive.parse(snapshot([
            "id:r1": room(name: "Design review", log: [
                message("Hi team", kind: "user", name: "You", at: 1_700_000_000_000, id: "m1"),
                message("On it", at: 1_700_000_060_000, id: "m2", truncated: true, thread: "t-1"),
            ], omitted: 3),
        ]))
        let r = try XCTUnwrap(rooms.first)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(r.id, "id:r1")
        XCTAssertEqual(r.name, "Design review")
        XCTAssertEqual(r.omitted, 3)
        XCTAssertEqual(r.members, [DesktopArchiveMember(name: "alice"), DesktopArchiveMember(name: "bob", handle: "bobby")])
        XCTAssertEqual(r.messages.map(\.id), ["m1", "m2"])
        XCTAssertTrue(r.messages[0].fromUser)
        XCTAssertFalse(r.messages[1].fromUser)
        XCTAssertEqual(r.messages[1].author, "alice")
        XCTAssertTrue(r.messages[1].truncated)
        XCTAssertEqual(r.messages[1].thread, "t-1")
        XCTAssertEqual(r.messages[0].at, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(r.lastAt, Date(timeIntervalSince1970: 1_700_000_060))
    }

    func testRoomsAreOrderedNewestFirstAndNameFallsBackToKey() {
        let rooms = DesktopGroupArchive.parse(snapshot([
            "id:old": room(name: "Old", log: [message("a", at: 1_000)]),
            "name:Legacy": room(name: nil, log: [message("b", at: 3_000)]),
            "id:mid": room(name: "  ", log: [message("c", at: 2_000)]),
        ]))
        XCTAssertEqual(rooms.map(\.id), ["name:Legacy", "id:mid", "id:old"])
        XCTAssertEqual(rooms[0].name, "Legacy", "a name-keyed room without a name uses its key")
        XCTAssertEqual(rooms[1].name, "Untitled group chat")
    }

    func testOlderVersionsAreKeyedByName() {
        let rooms = DesktopGroupArchive.parse(snapshot(["Standup": room(name: nil, log: [message("hello")])], version: 2))
        XCTAssertEqual(rooms.map(\.id), ["name:Standup"])
        XCTAssertEqual(rooms.first?.name, "Standup")
    }

    func testTombstonedRoomsAreSkippedLikeDesktop() {
        let rooms = DesktopGroupArchive.parse(snapshot([
            "id:gone": room(name: "Gone", log: [message("x")], revision: 2),
            "id:back": room(name: "Recreated", log: [message("y")], revision: 5),
        ], deleted: ["id:gone": 2, "id:back": 4]))
        XCTAssertEqual(rooms.map(\.id), ["id:back"], "a tombstone at or above the room's revision hides it")
    }

    func testMalformedInputIsSkippedNotFatal() {
        XCTAssertEqual(DesktopGroupArchive.parse(nil), [])
        XCTAssertEqual(DesktopGroupArchive.parse(.string("not json")), [])
        XCTAssertEqual(DesktopGroupArchive.parse(.array([])), [])
        XCTAssertEqual(DesktopGroupArchive.parse(["version": 3, "rooms": .array([])]), [])
        let rooms = DesktopGroupArchive.parse(snapshot([
            "id:a": .string("nope"),
            "id:b": ["log": "nope"],
            "id:c": room(name: "Empty", log: []),
            "id:d": room(name: "Bad entries", log: [.string("x"), .number(1), message(.number(5)), message("   "), .null]),
            "id:e": room(name: "Good", log: [.null, message("ok", kind: "weird", name: "")],
                         members: [.string("x"), ["handle": "nameless"], ["name": "dup"], ["name": "dup"]]),
        ]))
        XCTAssertEqual(rooms.map(\.id), ["id:e"])
        let good = rooms[0]
        XCTAssertEqual(good.messages.count, 1)
        XCTAssertTrue(good.messages[0].fromUser, "an unknown author kind reads as the user, as Desktop does")
        XCTAssertEqual(good.messages[0].author, "You")
        XCTAssertEqual(good.members.map(\.name), ["dup"], "members without a name and duplicates are dropped")
    }

    func testBadTimestampsBecomeUnknown() {
        let rooms = DesktopGroupArchive.parse(snapshot([
            "id:a": room(name: "A", log: [message("1", at: -5), message("2", at: 0), message("3", at: 1e20), message("4", at: .infinity)]),
        ]))
        XCTAssertEqual(rooms.first?.messages.map(\.at), [nil, nil, nil, nil])
    }

    func testOversizedInputIsCapped() throws {
        let long = String(repeating: "x", count: 50_000)
        let log = (0..<500).map { message(.string("m\($0)"), at: Double(1_000 + $0), id: "id\($0)") } + [message(.string(long), at: 9_999)]
        let members = (0..<40).map { JSONValue.object(["name": .string("bot\($0)")]) }
        var rooms: [String: JSONValue] = ["id:big": room(name: String(repeating: "N", count: 500), log: log, members: members, omitted: 7)]
        for i in 0..<200 { rooms["id:r\(i)"] = room(name: "R\(i)", log: [message("x", at: Double(i + 1))]) }
        let parsed = DesktopGroupArchive.parse(snapshot(rooms))
        XCTAssertEqual(parsed.count, DesktopGroupArchive.maxRooms)
        let big = try XCTUnwrap(parsed.first)
        XCTAssertEqual(big.id, "id:big", "newest activity first")
        XCTAssertEqual(big.messages.count, DesktopGroupArchive.maxMessages)
        XCTAssertEqual(big.messages.first?.id, "id485", "the newest messages are kept")
        XCTAssertEqual(big.omitted, 7 + 501 - DesktopGroupArchive.maxMessages, "dropped messages add to Desktop's own count")
        XCTAssertEqual(big.members.count, DesktopGroupArchive.maxMembers)
        XCTAssertEqual(big.name.count, DesktopGroupArchive.maxNameChars)
        let last = try XCTUnwrap(big.messages.last)
        XCTAssertEqual(last.text.count, DesktopGroupArchive.maxTextChars)
        XCTAssertTrue(last.text.hasSuffix(DesktopGroupArchive.truncationMark))
        XCTAssertTrue(last.truncated)
    }

    func testDuplicateMessageIdsStayUnique() {
        let rooms = DesktopGroupArchive.parse(snapshot(["id:a": room(name: "A", log: [message("1", id: "same"), message("2", id: "same")])]))
        let ids = rooms.first?.messages.map(\.id) ?? []
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testHiddenCharactersInLabelsAreShown() {
        let rooms = DesktopGroupArchive.parse(snapshot(["id:a": room(name: "evil\u{202E}txt.exe", log: [message("hi", name: "al\nice")])]))
        XCTAssertEqual(rooms.first?.name, "evil⟨U+202E⟩txt.exe")
        XCTAssertEqual(rooms.first?.messages.first?.author, "al ice", "labels stay on one line")
    }

    func testJSONStringValueIsDecoded() {
        let inner = snapshot(["id:a": room(name: "A", log: [message("hi")])]).compactJSON()
        XCTAssertEqual(DesktopGroupArchive.parse(.string(inner)).map(\.id), ["id:a"])
        let huge = String(repeating: " ", count: DesktopGroupArchive.maxEncodedBytes + 1)
        XCTAssertEqual(DesktopGroupArchive.parse(.string(huge)), [])
    }

    func testReadsTheDefaultProfileRowOnly() {
        let projection = snapshot(["id:a": room(name: "A", log: [message("hi")])])
        let other = snapshot(["id:b": room(name: "B", log: [message("hi")])])
        let list: JSONValue = ["profiles": [
            ["name": "reviewer", "ui_meta": ["hermes-bots-groups": other]],
            ["name": "main", "is_default": true, "ui_meta": ["hermes-bots-groups": projection]],
        ]]
        XCTAssertEqual(DesktopGroupArchive.rooms(profilesList: list).map(\.id), ["id:a"])
        let byName: JSONValue = ["profiles": [["name": "default", "ui_meta": ["hermes-bots-groups": projection]]]]
        XCTAssertEqual(DesktopGroupArchive.rooms(profilesList: byName).map(\.id), ["id:a"])
        XCTAssertEqual(DesktopGroupArchive.rooms(profilesList: ["profiles": [["name": "default"]]]), [])
        XCTAssertEqual(DesktopGroupArchive.rooms(profilesList: [:]), [])
    }

    func testLoadOnlyCallsProfilesList() async throws {
        let calls = CallLog()
        let response: JSONValue = ["profiles": [["name": "default", "is_default": true,
                                                 "ui_meta": ["hermes-bots-groups": snapshot(["id:a": room(name: "A", log: [message("hi")])])]]]]
        let rooms = try await DesktopGroupArchive.load { method, params in
            await calls.add(method, params)
            return response
        }
        XCTAssertEqual(rooms.count, 1)
        let log = await calls.entries
        XCTAssertEqual(log.map(\.0), ["profiles.list"], "read-only: never profiles.configure")
        XCTAssertEqual(log.first?.1, ["include_sessions": false])
    }

    func testArchiveRoundTripsThroughCodable() throws {
        let rooms = DesktopGroupArchive.parse(snapshot(["id:a": room(name: "A", log: [message("hi", id: "m"), message("no time", at: 0)])]))
        let data = try JSONEncoder().encode(rooms)
        XCTAssertEqual(try JSONDecoder().decode([DesktopArchiveRoom].self, from: data), rooms)
    }
}

actor CallLog {
    private(set) var entries: [(String, JSONValue)] = []
    func add(_ method: String, _ params: JSONValue) { entries.append((method, params)) }
}
