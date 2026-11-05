import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Live UI test 2026-11-06 (round 2): Settings had no switch for notifications (roadmap D15). Settings ›
/// Notifications › "Show notifications" writes the same key `NotificationPolicy.isEnabled` reads, so the
/// coordinator follows it. A throwaway defaults suite; nothing is posted.
@MainActor
final class NotificationsSettingTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "hba-notifications-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testTheSwitchIsWhatThePolicyReads() {
        let setting = NotificationsSection.setting(defaults)
        XCTAssertTrue(setting.wrappedValue, "on by default")
        XCTAssertTrue(NotificationPolicy.isEnabled(defaults))
        setting.wrappedValue = false
        XCTAssertFalse(NotificationPolicy.isEnabled(defaults), "turning the switch off stops notifications")
        XCTAssertFalse(NotificationsSection.setting(defaults).wrappedValue, "the switch shows the stored value")
        setting.wrappedValue = true
        XCTAssertTrue(NotificationPolicy.isEnabled(defaults))
    }

    func testTheCoordinatorFollowsTheSwitch() {
        let poster = NotificationCoordinatorTests.RecordingPoster()
        let c = NotificationCoordinator(poster: poster)
        c.appActive = { false }
        c.setBadge = { _ in }
        c.enabled = { [defaults] in NotificationPolicy.isEnabled(defaults!) }
        let chat = ChatModel(bot: Bot(["name": "alpha"])!, opener: { _ in throw CancellationError() })
        chat.log = { _ in }
        chat.transcript.seed(history: [ChatHistoryMessage(role: .user, text: "hi"), ChatHistoryMessage(role: .assistant, text: "Done.")])
        NotificationsSection.setting(defaults).wrappedValue = false
        c.turnEvent("message.complete", chat)
        XCTAssertTrue(poster.posted.isEmpty)
        NotificationsSection.setting(defaults).wrappedValue = true
        c.turnEvent("message.complete", chat)
        XCTAssertEqual(poster.posted.map(\.body), ["Done."])
    }

    func testOutsideTheAppBundleTheSectionSaysWhy() {
        XCTAssertFalse(UserNotificationPoster.availability(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), environment: [:]))
        XCTAssertTrue(NotificationsSection.unavailableNote.contains("Herald.app"))
    }
}
