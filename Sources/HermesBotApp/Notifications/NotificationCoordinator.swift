import AppKit
import Combine
import Foundation
import HermesGatewayKit

/// Posts and withdraws notifications (UserNotificationPoster in the app, a recorder in tests).
@MainActor
protocol NotificationPosting: AnyObject {
    func post(_ content: NotificationContent)
    func remove(ids: [String])
}

/// D1 + D2 wiring: follows every open Bot Chat (request cards, finished replies) and every room
/// (`RoomAttentionWatcher`), posts a notification when `NotificationPolicy` allows it, withdraws it once the
/// request is answered, and keeps the Dock badge at the number of things waiting on the user.
@MainActor
final class NotificationCoordinator {
    /// nil when the process cannot use UserNotifications (not an .app bundle, or under tests).
    private let poster: NotificationPosting?
    let rooms = RoomAttentionWatcher()
    var appActive: () -> Bool = { NSApp?.isActive ?? true }
    var enabled: () -> Bool = { NotificationPolicy.isEnabled() }
    var botHidden: (String) -> Bool = { _ in false }
    var setBadge: (String?) -> Void = { label in NSApp?.dockTile.badgeLabel = label }
    private(set) var badge: String?
    private var chatRequests: [String: [ServerRequest]] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]

    init(poster: NotificationPosting?) {
        self.poster = poster
        rooms.onApprovals = { [weak self] room, new, gone in self?.roomApprovals(room, new: new, gone: gone) }
        rooms.onMentions = { [weak self] room, mentions in self?.roomMentions(room, mentions) }
    }

    // MARK: Bot Chat

    /// Follows one Bot Chat's request cards (the chat's model lives for the connection).
    func track(_ chat: ChatModel) {
        let bot = chat.bot
        subscriptions[bot.name] = chat.$requests.sink { [weak self] requests in
            self?.chatRequestsChanged(bot, requests)
        }
    }

    /// A deleted bot: stop following its chat and withdraw what it posted.
    func untrack(_ bot: String) {
        subscriptions[bot] = nil
        let ids = (chatRequests.removeValue(forKey: bot) ?? []).map { NotificationContent.requestId(bot: bot, request: $0.id) }
        if !ids.isEmpty { poster?.remove(ids: ids) }
        updateBadge()
    }

    private func chatRequestsChanged(_ bot: Bot, _ requests: [ServerRequest]) {
        let before = chatRequests[bot.name] ?? []
        chatRequests[bot.name] = requests
        let old = Set(before.map(\.id)), now = Set(requests.map(\.id))
        let gone = before.filter { !now.contains($0.id) }
        if !gone.isEmpty {
            poster?.remove(ids: gone.map { NotificationContent.requestId(bot: bot.name, request: $0.id) })
        }
        for r in requests where !old.contains(r.id) && DockBadge.waiting([r]) == 1 {
            consider(.botRequest(bot: bot.name, title: bot.title, request: r))
        }
        updateBadge()
    }

    /// `ChatModel.onTurnEvent`: a finished reply notifies.
    func turnEvent(_ type: String, _ chat: ChatModel) {
        guard type == "message.complete" else { return }
        let text = chat.lines.last(where: { $0.role == .bot })?.text ?? ""
        consider(.botReplied(bot: chat.bot.name, title: chat.bot.title, text: text))
    }

    // MARK: rooms

    private func roomApprovals(_ room: RoomSummary, new: [RoomApproval], gone: [RoomApproval]) {
        if !gone.isEmpty {
            poster?.remove(ids: gone.map { NotificationContent.roomApprovalId(room: room.roomId, approval: $0) })
        }
        for a in new {
            let member = room.member(a.memberId)?.title ?? a.memberId
            consider(.roomApproval(roomId: room.roomId, roomName: room.name, member: member, approval: a))
        }
        updateBadge()
    }

    private func roomMentions(_ room: RoomSummary, _ mentions: [RoomAttention.Mention]) {
        for m in mentions {
            consider(.roomMention(roomId: room.roomId, roomName: room.name, discussion: m.discussion, author: m.author, text: m.text))
        }
    }

    // MARK: kanban (K9)

    /// A watched kanban card finished or became blocked (KanbanIntegrations.swift builds the content). Same
    /// rule as the others: only while enabled and the app is not frontmost.
    func kanbanCard(_ content: NotificationContent) {
        guard enabled(), !appActive() else { return }
        poster?.post(content)
    }

    // MARK: posting

    private func consider(_ event: AttentionEvent) {
        let hidden: Bool
        if case .botReplied(let bot, _, _) = event { hidden = botHidden(bot) } else { hidden = false }
        guard NotificationPolicy.shouldPost(event, appActive: appActive(), enabled: enabled(), botHidden: hidden) else { return }
        poster?.post(NotificationContent(event))
    }

    var badgeCount: Int {
        DockBadge.count(chatRequests: chatRequests.mapValues(DockBadge.waiting), roomApprovals: rooms.approvalCounts)
    }

    private func updateBadge() {
        let label = DockBadge.label(badgeCount)
        guard label != badge else { return }
        badge = label
        setBadge(label)
    }

    /// The connection is gone: nothing waits any more (its chats and rooms are dropped).
    func reset() {
        subscriptions = [:]
        let ids = chatRequests.flatMap { bot, rs in rs.map { NotificationContent.requestId(bot: bot, request: $0.id) } }
            + rooms.states.flatMap { room, s in s.approvals.map { NotificationContent.roomApprovalId(room: room, approval: $0) } }
        if !ids.isEmpty { poster?.remove(ids: ids) }
        chatRequests = [:]
        rooms.reset()
        updateBadge()
    }
}
