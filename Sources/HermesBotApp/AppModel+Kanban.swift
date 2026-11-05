import AppKit
import SwiftUI

// K9 entry points on AppModel: Create Task from Message, Open Bot Chat from a card, and opening a card from
// its notification. The Kanban side lives in KanbanIntegrations.swift.

extension AppModel {
    /// "Create Task from Message" (Group Chat and Bot Chat message menus): the prefilled New Task sheet.
    func composeTask(from seed: KanbanTaskSeed) {
        kanban.composeTask(from: seed)
    }

    /// Whether `profile` is a bot in the roster (its Bot Chat can open).
    func canOpenBotChat(_ profile: String) -> Bool { bots.contains { $0.name == profile } }

    /// A card's assignee: select that bot's Bot Chat.
    func openBotChat(_ profile: String) {
        guard canOpenBotChat(profile) else { return }
        withTransaction(SidebarView.selectionTransaction) { selection = .bot(profile) }
    }

    /// A card notification was clicked: open its board and select the card (the inspector follows).
    func openCard(board: String, task: String) {
        NSApp?.activate(ignoringOtherApps: true)
        guard kanban.rows.contains(where: { $0.slug == board }) else {
            log("notification: board \(board) is not listed")
            return
        }
        withTransaction(SidebarView.selectionTransaction) { selection = .board(board) }
        kanban.model(for: board)?.select(task)
    }

    func kanbanCardChanged(_ event: KanbanCardEvent) {
        log("kanban: watched card \(event.task.id) on \(event.board) \(event.change.rawValue)")
        notifications.kanbanCard(KanbanCardNotice.content(event))
    }
}
