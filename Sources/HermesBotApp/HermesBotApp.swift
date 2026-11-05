import AppKit
import HermesGatewayKit
import SwiftUI

// App shell: attach-first to a running Hermes backend (or spawn `hermes serve --isolated`), list the
// user's bots (`profiles.list`), chat 1:1 in each bot's canonical "Bot Chat" (shared with Hermes Desktop:
// resumed on select, streamed replies, tool rows, approvals/questions, attachments, slash commands;
// detached, never deleted, on quit), and Group
// Chat (M2, RoomModel.swift + RoomView.swift: `groups.list/create/send/state/log/stop/retry/approve/disband`,
// room updates by polling). The M0 groups.* round-trip lives on in `spike-harness`.
// This file holds only the scenes. Files: AppDelegate (launch, quit cleanup, window lifecycle policy),
// RootView (the main window's split view and sheets), SettingsSections (the Settings window and its sections),
// AppModel (connection, bots, rooms, quit cleanup), ChatModel (+Slash, +Requests), SidebarView, BotChatView,
// ChatComposer, BotInspector; debug-only scripted runs in EvidenceDriver.swift.
//
// Environment:
//   HERMES_BOT_APP_APPEARANCE=light|dark           force the appearance (evidence of both designed modes)
// plus Backend.Options env (HERMES_BOT_APP_LOCK_DIR, HERMES_BOT_APP_FORCE_SPAWN, HERMES_BOT_APP_NO_SPAWN).
// Look and motion: DESIGN.md (tokens in DesignSystem.swift).

@main
struct HermesBotApp: App {
    /// The main window's scene (reopened by `MainWindowOpener` after the last window was closed).
    static let mainSceneId = "main"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage(DS.Motion.settingKey) private var motion = true
    var body: some Scene {
        WindowGroup("Hermes Bot", id: Self.mainSceneId) {
            RootView(model: AppModel.shared).modifier(MotionGate()).capturesMainWindowOpener()
                // Every link surface in the window (not only message bodies) opens web pages only.
                .environment(\.openURL, OpenURLAction { url in MessageBody.opensLink(url) ? .systemAction : .discarded })
        }
            .defaultSize(DS.Size.windowDefault)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(after: .appInfo) { CheckForUpdatesCommand(checker: .shared) }  // E3 (Updates/)
                CommandGroup(after: .sidebar) {
                    Toggle("Animate Interface Changes", isOn: $motion)
                        .accessibilityLabel("Animate Interface Changes")
                }
                CommandGroup(after: .newItem) {
                    NewBotCommand(model: AppModel.shared)
                    DesktopImportCommand(model: AppModel.shared)
                }
                AppCommands(model: AppModel.shared)  // D5, D9, D10, D13 (AppCommands.swift)
            }
        // D9: a Bot Chat or a room in its own window, on the same models (PaneWindows.swift).
        WindowGroup("Hermes Bot", id: DetachedPane.sceneId, for: SidebarItem.self) { $item in
            DetachedPaneView(model: AppModel.shared, item: item).modifier(MotionGate())
                .environment(\.openURL, OpenURLAction { url in MessageBody.opensLink(url) ? .systemAction : .discarded })
        }
            .defaultSize(DS.Size.windowDefault)
            .windowToolbarStyle(.unified)
            .commandsRemoved()
        Settings { SettingsView() }
        // D3: menu bar extra (MacIntegration/MenuBarExtra.swift).
        MenuBarScene()
    }
}
