import AppKit
import Foundation
import UserNotifications

/// The system side of D1: UNUserNotificationCenter. Authorization is requested lazily, on the first
/// notification the app wants to show. Only available inside an .app bundle (UNUserNotificationCenter
/// raises in a bare `swift run` executable) and never under XCTest, so tests cannot post real notifications.
@MainActor
final class UserNotificationPoster: NSObject, NotificationPosting {
    private let center: UNUserNotificationCenter
    private var authorization: Task<Bool, Never>?
    /// Where a click or an action button goes (AppModel.handleNotification).
    var onRoute: (NotificationRoute) -> Void = { _ in }

    nonisolated static func availability(bundleURL: URL, environment: [String: String]) -> Bool {
        bundleURL.pathExtension == "app" && environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
    }

    static func makeIfAvailable() -> UserNotificationPoster? {
        guard availability(bundleURL: Bundle.main.bundleURL, environment: ProcessInfo.processInfo.environment) else { return nil }
        return UserNotificationPoster(center: .current())
    }

    private init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
        // Approve needs an unlocked Mac: it lets a bot run a command.
        let approve = UNNotificationAction(identifier: NotificationContent.approveAction, title: "Approve Once",
                                           options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: NotificationContent.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationContent.Category.approval.rawValue, actions: [approve, deny],
                                   intentIdentifiers: []),
        ])
    }

    private func authorized() async -> Bool {
        if authorization == nil {
            let center = center
            authorization = Task {
                do { return try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                    AppModel.shared.log("notifications: authorization failed: \(error.localizedDescription)")
                    return false
                }
            }
        }
        return await authorization?.value ?? false
    }

    func post(_ content: NotificationContent) {
        Task {
            guard await authorized() else { return }
            let c = UNMutableNotificationContent()
            c.title = content.title
            c.body = content.body
            c.sound = .default
            c.userInfo = content.userInfo
            if let category = content.category { c.categoryIdentifier = category.rawValue }
            do {
                try await center.add(UNNotificationRequest(identifier: content.id, content: c, trigger: nil))
            } catch {
                AppModel.shared.log("notifications: post failed: \(error.localizedDescription)")
            }
        }
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

extension UserNotificationPoster: UNUserNotificationCenterDelegate {
    /// The app only posts while it is in the background; one that lands just as it comes forward stays quiet.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let k = k as? String, let v = v as? String { info[k] = v }
        }
        let route = NotificationRoute.parse(action: action, userInfo: info)
        completionHandler()  // the answer itself runs on the main actor, like a card's button
        guard let route else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onRoute(route) }
        }
    }
}
