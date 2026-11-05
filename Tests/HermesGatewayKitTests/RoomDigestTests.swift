import Foundation
import XCTest
@testable import HermesGatewayKit

/// C1.5 / C1.7: the sidebar digest of a room (last-message preview, age, "needs you").
final class RoomDigestTests: XCTestCase {
    private let room = RoomSummary([
        "room_id": "hba-x", "name": "Test",
        "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Alpha"],
                    ["member_id": "beta", "profile": "beta", "handle": "beta"]],
    ])!

    private func user(_ seq: Int, _ text: String = "hi", id: String? = nil, time: Double = 100) -> RoomEvent {
        RoomEvent(seq: seq, eventId: id ?? "user:\(seq)", kind: "message.user", actor: ["kind": "user", "id": "desktop"],
                  payload: ["text": .string(text), "thread_id": "main"], createdAt: time)
    }
    private func member(_ seq: Int, _ m: String, _ text: String, disc: String = "user:1", time: Double = 200) -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dmessage:\(seq)", kind: "message.member", actor: ["kind": "member", "id": .string(m)],
                  payload: ["text": .string(text), "member_id": .string(m), "discussion_event_id": .string(disc), "thread_id": "main"],
                  createdAt: time)
    }
    private func settled(_ seq: Int, disc: String = "user:1") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dactivity:\(seq)", kind: "room.activity",
                  payload: ["status": "settled", "reason_code": "silent_round", "thread_id": "main", "discussion_event_id": .string(disc)])
    }

    func testPreviewIsNewestMessageWithAuthor() {
        let d = RoomDigest.make(events: [user(1), member(2, "alpha", "Hello\n\nthere   friend", time: 250), settled(3)], room: room)
        XCTAssertEqual(d.preview, RoomDigest.Preview(author: "Alpha", text: "Hello there friend", time: 250, seq: 2, fromUser: false))
        XCTAssertEqual(d.latestSeq, 3)
        XCTAssertFalse(d.awaiting)
        let mine = RoomDigest.make(events: [user(1, "ship it", time: 90)], room: room)
        XCTAssertEqual(mine.preview?.author, "You")
        XCTAssertTrue(mine.awaiting, "a user message with no settled discussion is still awaiting bots")
    }

    func testPreviewDropsAttachmentsAndCuts() {
        let withFiles = RoomAttachments.compose(text: "see these", paths: ["/tmp/a.png", "/tmp/b.txt"])
        XCTAssertEqual(RoomDigest.previewText(withFiles), "see these")
        XCTAssertEqual(RoomDigest.previewText(RoomAttachments.compose(text: "", paths: ["/tmp/a.png"])), "1 file")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(RoomDigest.previewText(long).count, RoomDigest.previewLimit)
        XCTAssertTrue(RoomDigest.previewText(long).hasSuffix("…"))
    }

    func testEmptyLogHasNoPreview() {
        XCTAssertNil(RoomDigest.make(events: [], room: room).preview)
        XCTAssertFalse(RoomDigest.make(events: [], room: room).needsYou(seenThrough: 0))
    }

    func testAddressesUserWord() {
        XCTAssertTrue(RoomDigest.addressesUser("@user can you confirm?", room: room))
        XCTAssertTrue(RoomDigest.addressesUser("Done. @User, please review.", room: room))
        XCTAssertTrue(RoomDigest.addressesUser("(@user)", room: room))
        XCTAssertFalse(RoomDigest.addressesUser("mail me at bob@user.com", room: room))
        XCTAssertFalse(RoomDigest.addressesUser("ask @users or @username", room: room))
        XCTAssertFalse(RoomDigest.addressesUser("@alpha what do you think", room: room))
        let withUserBot = RoomSummary(["room_id": "r", "members": [["member_id": "user", "profile": "user", "handle": "user"]]])!
        XCTAssertFalse(RoomDigest.addressesUser("@user go", room: withUserBot), "a bot handled `user` is a bot mention")
    }

    func testNeedsYouUntilSentOrSeen() {
        let asks = RoomDigest.make(events: [user(1), member(2, "alpha", "@user which option?"), settled(3)], room: room)
        XCTAssertEqual(asks.lastAddressSeq, 2)
        XCTAssertTrue(asks.needsYou(seenThrough: 0))
        XCTAssertFalse(asks.needsYou(seenThrough: 2), "opening the room (seen through the message) clears it")
        let answered = RoomDigest.make(events: [user(1), member(2, "alpha", "@user which option?"), settled(3), user(4, "B", id: "user:4")],
                                       room: room)
        XCTAssertFalse(answered.needsYou(seenThrough: 0), "a newer user message clears it")
        let plain = RoomDigest.make(events: [user(1), member(2, "alpha", "done")], room: room)
        XCTAssertFalse(plain.needsYou(seenThrough: 0))
    }

    func testUserMessagesNeverCountAsAddress() {
        let d = RoomDigest.make(events: [user(1, "@user note to self")], room: room)
        XCTAssertEqual(d.lastAddressSeq, 0)
    }

    func testUnorderedAndDuplicateEvents() {
        let d = RoomDigest.make(events: [member(2, "alpha", "b"), user(1), member(2, "alpha", "b")], room: room)
        XCTAssertEqual(d.preview?.seq, 2)
        XCTAssertEqual(d.latestSeq, 2)
    }

    func testAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RoomDigest.age(of: 1_000_000 - 30, now: now), "now")
        XCTAssertEqual(RoomDigest.age(of: 1_000_000 - 300, now: now), "5m")
        XCTAssertEqual(RoomDigest.age(of: 1_000_000 - 3 * 3600, now: now), "3h")
        XCTAssertEqual(RoomDigest.age(of: 1_000_000 - 2 * 86_400, now: now), "2d")
        XCTAssertEqual(RoomDigest.age(of: 1_000_000 + 60, now: now), "now", "clock skew never shows a negative age")
        XCTAssertEqual(RoomDigest.age(of: 0, now: now), "", "no time, no age")
        let old = RoomDigest.age(of: 1_700_000_000 - 30 * 86_400, now: Date(timeIntervalSince1970: 1_700_000_000), locale: Locale(identifier: "en_US"),
                                 timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(old, "Oct 15")
    }
}
