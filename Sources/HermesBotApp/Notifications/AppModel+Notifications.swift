import AppKit
import HermesGatewayKit
import SwiftUI

extension AppModel {
    /// A notification was clicked (open its bot or room) or answered with Approve / Deny. Answers go
    /// through the same calls as the cards: `ChatModel.respond` (`approval` once/deny) and `groups.approve`.
    /// A request answered meanwhile (gone from the chat or the room) is not answered again; its pane opens.
    func handleNotification(_ route: NotificationRoute) {
        switch route {
        case .open(let item):
            open(item)
        case .answerChat(let bot, let requestId, let approve):
            guard let chat = chats[bot], let r = chat.requests.first(where: { $0.id == requestId }) else {
                log("notification answer: \(bot) request \(requestId) is no longer waiting")
                return open(.bot(bot))
            }
            chat.respond(r, .approval(approve ? .once : .deny))
            log("notification answer: \(bot) approval → \(approve ? "once" : "deny")")
        case .answerRoom(let roomId, let memberId, let requestId, let approve):
            guard let approval = notifications.rooms.approval(room: roomId, member: memberId, request: requestId) else {
                log("notification answer: room \(roomId) approval \(requestId) is no longer waiting")
                return open(.room(roomId))
            }
            let choice = approve ? "once" : "deny"
            if let model = roomModels[roomId] {
                model.approve(approval, choice: choice)
            } else if let groups {
                Task {
                    do {
                        _ = try await groups.approve(roomId: roomId, approval: approval, choice: choice)
                        self.log("notification answer: room \(roomId) groups.approve \(choice)")
                    } catch {
                        self.log("notification answer: room \(roomId) groups.approve failed: \(Redaction.describe(error))")
                    }
                }
            }
        }
    }

    private func open(_ item: SidebarItem) {
        NSApp?.activate(ignoringOtherApps: true)
        switch item {
        case .bot(let name) where !bots.contains(where: { $0.name == name }): return
        case .room(let id) where !rooms.contains(where: { $0.roomId == id }): return
        default: break
        }
        withTransaction(SidebarView.selectionTransaction) { selection = item }
    }
}
