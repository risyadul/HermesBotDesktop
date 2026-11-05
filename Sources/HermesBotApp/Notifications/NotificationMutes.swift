import Foundation
import SwiftUI

// D15: mute notifications per bot or room (sidebar row menu → Mute Notifications). A muted bot or room never
// posts a banner: replies, `@user` mentions, approvals and questions alike. It still counts in the Dock badge
// (D2) and keeps its sidebar badges: the badge says what waits on the user, and a muted bot can still be blocked
// on an approval. Kept in this Mac's UserDefaults (not in Hermes), by sidebar item token (`bot:<name>`,
// `room:<id>`). The Settings switch (`NotificationPolicy.enabledKey`) still turns every banner off.

@MainActor
final class NotificationMutes: ObservableObject {
    static let key = "hba.mutedNotifications"

    @Published private(set) var muted: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        muted = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isMuted(_ item: SidebarItem) -> Bool { muted.contains(item.token) }

    func setMuted(_ item: SidebarItem, _ on: Bool) {
        guard Self.canMute(item), on != isMuted(item) else { return }
        if on { muted.insert(item.token) } else { muted.remove(item.token) }
        defaults.set(muted.sorted(), forKey: Self.key)
    }

    /// Only bots and rooms notify.
    nonisolated static func canMute(_ item: SidebarItem) -> Bool {
        switch item {
        case .bot, .room: return true
        case .board, .archive: return false
        }
    }

    nonisolated static func menuTitle(muted: Bool) -> String { muted ? "Unmute Notifications" : "Mute Notifications" }

    /// The bot or room a notification is about.
    nonisolated static func target(of event: AttentionEvent) -> SidebarItem {
        switch event {
        case .botReplied(let bot, _, _), .botRequest(let bot, _, _): return .bot(bot)
        case .roomApproval(let room, _, _, _), .roomMention(let room, _, _, _, _): return .room(room)
        }
    }
}
