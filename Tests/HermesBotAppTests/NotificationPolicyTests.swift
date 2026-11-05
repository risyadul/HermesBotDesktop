import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D1 / D2 pure rules: when to notify, what a notification says, the action routes, the Dock badge
/// count and the `@user` grammar. No notification is posted.
final class NotificationPolicyTests: XCTestCase {
    static func approvalRequest(id: String = "srq-1", choices: [String] = ["once", "session", "always", "deny"]) -> ServerRequest {
        ServerRequest(wireId: .string(id), method: "approval",
                      params: ["session_id": "s", "request_id": "q1", "command": "rm -rf build", "description": "delete build",
                               "choices": .array(choices.map { .string($0) })])
    }

    static let roomApproval = RoomApproval(memberId: "alpha", taskId: "t1", executionGeneration: 1, requestId: "r1",
                                           choices: ["once", "deny"], command: "git push", description: "push")

    // MARK: policy

    func testPostsOnlyWhenEnabledAndNotFrontmost() {
        let e = AttentionEvent.botReplied(bot: "a", title: "A", text: "done")
        XCTAssertTrue(NotificationPolicy.shouldPost(e, appActive: false, enabled: true, botHidden: false))
        XCTAssertFalse(NotificationPolicy.shouldPost(e, appActive: true, enabled: true, botHidden: false))
        XCTAssertFalse(NotificationPolicy.shouldPost(e, appActive: false, enabled: false, botHidden: false))
    }

    func testHiddenBotRepliesStayQuietButItsRequestsStillNotify() {
        XCTAssertFalse(NotificationPolicy.shouldPost(.botReplied(bot: "a", title: "A", text: "x"),
                                                     appActive: false, enabled: true, botHidden: true))
        XCTAssertTrue(NotificationPolicy.shouldPost(.botRequest(bot: "a", title: "A", request: Self.approvalRequest()),
                                                    appActive: false, enabled: true, botHidden: true))
    }

    func testEmptyReplyDoesNotNotify() {
        XCTAssertFalse(NotificationPolicy.shouldPost(.botReplied(bot: "a", title: "A", text: "  \n"),
                                                     appActive: false, enabled: true, botHidden: false))
    }

    func testEnabledSettingDefaultsOn() throws {
        let suite = "hba-notify-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NotificationPolicy.isEnabled(defaults))
        defaults.set(false, forKey: NotificationPolicy.enabledKey)
        XCTAssertFalse(NotificationPolicy.isEnabled(defaults))
        XCTAssertEqual(NotificationPolicy.enabledKey, "notificationsEnabled")
    }

    // MARK: content

    func testReplyContentIsClippedOneLine() {
        let c = NotificationContent(.botReplied(bot: "a", title: "Alpha", text: "line one\n\nline two " + String(repeating: "x", count: 400)))
        XCTAssertEqual(c.title, "Alpha")
        XCTAssertFalse(c.body.contains("\n"))
        XCTAssertEqual(c.body.count, NotificationContent.bodyLimit)
        XCTAssertTrue(c.body.hasSuffix("…"))
        XCTAssertNil(c.category)
        XCTAssertEqual(c.id, "chat.reply.a")
        XCTAssertEqual(NotificationRoute.parse(action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: c.userInfo),
                       .open(.bot("a")))
    }

    func testChatApprovalOffersApproveDenyOnlyWhenBothChoicesExist() {
        let c = NotificationContent(.botRequest(bot: "a", title: "Alpha", request: Self.approvalRequest()))
        XCTAssertEqual(c.title, "Alpha needs your approval")
        XCTAssertEqual(c.body, "delete build: rm -rf build")
        XCTAssertEqual(c.category, .approval)
        XCTAssertEqual(c.id, NotificationContent.requestId(bot: "a", request: "srq-1"))
        XCTAssertEqual(NotificationRoute.parse(action: NotificationContent.approveAction, userInfo: c.userInfo),
                       .answerChat(bot: "a", requestId: "srq-1", approve: true))
        XCTAssertEqual(NotificationRoute.parse(action: NotificationContent.denyAction, userInfo: c.userInfo),
                       .answerChat(bot: "a", requestId: "srq-1", approve: false))
        let onlyOnce = NotificationContent(.botRequest(bot: "a", title: "Alpha", request: Self.approvalRequest(choices: ["once"])))
        XCTAssertNil(onlyOnce.category)
        XCTAssertEqual(NotificationRoute.parse(action: NotificationContent.approveAction, userInfo: onlyOnce.userInfo),
                       .open(.bot("a")), "no answer kind → the action only opens the chat")
    }

    func testQuestionsAndSecretPromptsHaveNoActionsAndNoValues() {
        let clarify = ServerRequest(wireId: "c1", method: "clarify",
                                    params: ["session_id": "s", "questions": [["qid": "q", "question": "Which branch?"]]])
        let c = NotificationContent(.botRequest(bot: "a", title: "Alpha", request: clarify))
        XCTAssertEqual(c.title, "Alpha has a question")
        XCTAssertEqual(c.body, "Which branch?")
        XCTAssertNil(c.category)
        let secret = ServerRequest(wireId: "v1", method: "secret", params: ["session_id": "s", "env_var": "API_KEY", "prompt": "key"])
        let v = NotificationContent(.botRequest(bot: "a", title: "Alpha", request: secret))
        XCTAssertEqual(v.title, "Alpha needs your input")
        XCTAssertFalse(v.body.contains("API_KEY"))
    }

    func testRoomApprovalRoutesToGroupsApprove() {
        let c = NotificationContent(.roomApproval(roomId: "hba-1", roomName: "Launch", member: "Alpha", approval: Self.roomApproval))
        XCTAssertEqual(c.title, "Alpha needs your approval")
        XCTAssertEqual(c.body, "Launch: push: git push")
        XCTAssertEqual(c.category, .approval)
        XCTAssertEqual(NotificationRoute.parse(action: NotificationContent.denyAction, userInfo: c.userInfo),
                       .answerRoom(roomId: "hba-1", memberId: "alpha", requestId: "r1", approve: false))
        let a = RoomApproval(memberId: "alpha", taskId: "t", executionGeneration: 0, requestId: "r2", choices: ["deny"],
                             command: nil, description: nil)
        XCTAssertNil(NotificationContent(.roomApproval(roomId: "hba-1", roomName: "L", member: "A", approval: a)).category)
    }

    func testRoomMentionOpensTheRoom() {
        let c = NotificationContent(.roomMention(roomId: "hba-1", roomName: "Launch", discussion: "user:abc", author: "Alpha",
                                                 text: "@user which account?"))
        XCTAssertEqual(c.title, "Alpha needs you in Launch")
        XCTAssertEqual(c.id, "room.mention.hba-1.user:abc")
        XCTAssertEqual(NotificationRoute.parse(action: "x", userInfo: c.userInfo), .open(.room("hba-1")))
    }

    func testRouteRejectsMissingOrBadTargets() {
        XCTAssertNil(NotificationRoute.parse(action: NotificationContent.approveAction, userInfo: [:]))
        XCTAssertNil(NotificationRoute.parse(action: "x", userInfo: ["target": "bot:"]))
        XCTAssertNil(NotificationRoute.parse(action: "x", userInfo: ["target": "board:x"]))
    }

    // MARK: badge

    func testBadgeCountsWaitingRequestsAndRoomApprovals() {
        let notShown = ServerRequest(wireId: "n", method: "tour", params: [:])
        XCTAssertEqual(DockBadge.waiting([Self.approvalRequest(), notShown]), 1)
        XCTAssertEqual(DockBadge.count(chatRequests: ["a": 2, "b": 0], roomApprovals: ["r": 1]), 3)
        XCTAssertNil(DockBadge.label(0))
        XCTAssertEqual(DockBadge.label(3), "3")
    }

    // MARK: @user

    func testUserMentionGrammar() {
        XCTAssertTrue(UserMention.mentionsUser("Blocked on billing — @user which account?"))
        XCTAssertTrue(UserMention.mentionsUser("@USER: done"))
        XCTAssertTrue(UserMention.mentionsUser("ping @user."))
        XCTAssertFalse(UserMention.mentionsUser("@users please"))
        XCTAssertFalse(UserMention.mentionsUser("@username"))
        XCTAssertFalse(UserMention.mentionsUser("mail me at me@user"))
        XCTAssertFalse(UserMention.mentionsUser("@alpha check this"))
        XCTAssertFalse(UserMention.mentionsUser(""))
    }

    @MainActor func testPosterIsUnavailableOutsideAnAppBundleAndUnderTests() {
        XCTAssertFalse(UserNotificationPoster.availability(bundleURL: URL(fileURLWithPath: "/tmp/debug"), environment: [:]))
        XCTAssertFalse(UserNotificationPoster.availability(bundleURL: URL(fileURLWithPath: "/A/HermesBot.app"),
                                                           environment: ["XCTestConfigurationFilePath": "/x"]))
        XCTAssertTrue(UserNotificationPoster.availability(bundleURL: URL(fileURLWithPath: "/A/HermesBot.app"), environment: [:]))
        XCTAssertNil(UserNotificationPoster.makeIfAvailable(), "the test runner never gets a real poster")
    }
}
