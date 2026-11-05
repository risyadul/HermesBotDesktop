import SwiftUI
import XCTest
import HermesGatewayKit
@testable import HermesBotApp

/// One `@user` grammar (`UserMention`): the room badge (`RoomDigest.addressesUser`), the notification watcher
/// (`RoomAttention`, through the digest's check) and the transcript highlight (`TextStyling.highlightMentions`)
/// agree on every tricky input. Before they shared it, `@user-` badged nothing while the highlight showed it
/// amber, and a member handled `user` was still painted as the human.
@MainActor
final class UserMentionAgreementTests: XCTestCase {
    private struct Row {
        let text: String
        var members: [String] = []
        let addressesUser: Bool
    }

    private let table: [Row] = [
        Row(text: "@user", addressesUser: true),
        Row(text: "@user.", addressesUser: true),
        Row(text: "@user-", addressesUser: true),
        Row(text: "@user_", addressesUser: true),
        Row(text: "@user:", addressesUser: true),
        Row(text: "Done. @User, please review.", addressesUser: true),
        Row(text: "(@user)", addressesUser: true),
        Row(text: "@USER: done", addressesUser: true),
        Row(text: "me@user", addressesUser: false),
        Row(text: "bob@user.com", addressesUser: false),
        Row(text: "@@user", addressesUser: false),
        Row(text: "@username", addressesUser: false),
        Row(text: "@users", addressesUser: false),
        Row(text: "@user.name", addressesUser: false),
        Row(text: "@user-bot", addressesUser: false),
        Row(text: "@alpha check this", addressesUser: false),
        Row(text: "", addressesUser: false),
        Row(text: "@user go", members: ["user"], addressesUser: false),
        Row(text: "@User go", members: ["USER"], addressesUser: false),
    ]

    private func room(_ handles: [String]) -> RoomSummary {
        let members: [JSONValue] = (handles + ["alpha"]).map {
            .object(["member_id": .string($0), "profile": .string($0), "handle": .string($0)])
        }
        return RoomSummary(["room_id": "r", "members": .array(members)])!
    }

    private func highlightsUser(_ text: String, members: [String]) -> Bool {
        var a = AttributedString(text)
        TextStyling.highlightMentions(&a, handles: Set(members + ["alpha"]))
        return a.runs.contains { $0.foregroundColor == DS.Palette.attention }
    }

    func testEverySurfaceAgreesOnTrickyInputs() {
        for row in table {
            let label = "\(row.text.debugDescription) members \(row.members)"
            XCTAssertEqual(UserMention.mentionsUser(row.text, memberHandles: row.members), row.addressesUser, label)
            XCTAssertEqual(RoomDigest.addressesUser(row.text, room: room(row.members)), row.addressesUser, "digest " + label)
            XCTAssertEqual(highlightsUser(row.text, members: row.members), row.addressesUser, "highlight " + label)
        }
    }

    func testMentionRangesStopBeforeTrailingPunctuation() {
        let text = "ask @alpha. then @user-"
        let found = UserMention.mentions(in: text).map { String(text[$0.range]) }
        XCTAssertEqual(found, ["@alpha", "@user"])
    }
}
