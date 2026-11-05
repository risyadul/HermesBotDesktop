import AppKit
import HermesGatewayKit
import SwiftUI

// Menu bar commands for the macOS integration items: the Go menu (D5 ⌘K and ⌘1…9, D10 ⇧⌘F, D9 Open in New
// Window), File → room templates (D13). Sidebar row menus share `SidebarItemMenu` (D9, D13, D15).

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            RoomTemplateCommands(model: model, store: model.roomTemplates)
        }
        CommandMenu("Go") { GoMenu(model: model) }
    }
}

private struct GoMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Quick Switch…") { model.openPalette(.switcher) }
            .keyboardShortcut("k", modifiers: .command)
        Button("Search Messages…") { model.openPalette(.messages) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Divider()
        let targets = SidebarShortcuts.targets(model.sidebarOrder)
        ForEach(Array(targets.enumerated()), id: \.element) { i, item in
            Button(model.shortcutTitle(item)) { model.selectShortcut(i + 1) }
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
        }
        Divider()
        Button("Open in New Window") { if let item = model.selection { openWindow(value: item) } }
            .disabled(!(model.selection?.opensInWindow ?? false))
    }
}

/// Extra items in a bot's or a room's sidebar menu: Open in New Window (D9), Save as Template… (D13, rooms),
/// Mute / Unmute Notifications (D15).
/// Edit / Duplicate / Delete, then Open in New Window and Mute: the bot row's context menu and the Bot Chat
/// toolbar's Bot menu, so managing a bot is not sidebar-only.
struct BotManageMenu: View {
    let bot: Bot
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(BotRowMenu.manageItems(bot), id: \.self) { item in
            switch item {
            case .edit: Button(BotRowMenu.title(item)) { model.editBot(bot.name) }
            case .duplicate: Button(BotRowMenu.title(item)) { model.duplicateBot(bot.name) }
            case .delete:
                Divider()
                Button(BotRowMenu.title(item), role: .destructive) { model.deleteBot(bot.name) }
            default: EmptyView()
            }
        }
        .disabled(model.backend == nil || model.botSheet != nil)
        SidebarItemMenu(item: .bot(bot.name), model: model)  // D9, D15
    }
}

/// Open in New Window, Save as Template (rooms) and Mute: the sidebar row's context menu and the pane's
/// toolbar menu (Room, Bot) alike.
struct SidebarItemMenu: View {
    let item: SidebarItem
    @ObservedObject var model: AppModel
    @ObservedObject private var mutes: NotificationMutes
    @Environment(\.openWindow) private var openWindow

    init(item: SidebarItem, model: AppModel) {
        self.item = item
        _model = ObservedObject(wrappedValue: model)
        _mutes = ObservedObject(wrappedValue: model.mutes)
    }

    var body: some View {
        Divider()
        Button("Open in New Window") { openWindow(value: item) }
        if case .room(let id) = item {
            Button("Save as Template…") { model.saveTemplate(from: id) }
                .disabled(model.templateSource != nil)
        }
        Button(NotificationMutes.menuTitle(muted: mutes.isMuted(item))) { model.toggleMute(item) }
    }
}
