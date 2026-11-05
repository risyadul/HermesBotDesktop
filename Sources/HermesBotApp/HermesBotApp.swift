import AppKit
import HermesGatewayKit
import SwiftUI

// App shell: attach-first to a running Hermes backend (or spawn `hermes serve --isolated`), list the
// user's bots (`profiles.list`), chat 1:1 in each bot's canonical "Bot Chat" (shared with Hermes Desktop:
// resumed on select, streamed replies, tool rows, approvals/questions, attachments, slash commands;
// detached, never deleted, on quit), and Group
// Chat (M2, RoomModel.swift + RoomView.swift: `groups.list/create/send/state/log/stop/retry/approve/disband`,
// room updates by polling). The M0 groups.* round-trip lives on in `spike-harness`.
// Files: AppModel (connection, bots, rooms, quit cleanup), ChatModel (+Slash, +Requests), SidebarView,
// BotChatView, ChatComposer, BotInspector; debug-only scripted runs in EvidenceDriver.swift.
//
// Environment:
//   HERMES_BOT_APP_APPEARANCE=light|dark           force the appearance (evidence of both designed modes)
// plus Backend.Options env (HERMES_BOT_APP_LOCK_DIR, HERMES_BOT_APP_FORCE_SPAWN, HERMES_BOT_APP_NO_SPAWN).
// Look and motion: DESIGN.md (tokens in DesignSystem.swift).

@main
struct HermesBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage(DS.Motion.settingKey) private var motion = true
    var body: some Scene {
        WindowGroup("Hermes Bot") {
            RootView(model: AppModel.shared).modifier(MotionGate())
                // Every link surface in the window (not only message bodies) opens web pages only.
                .environment(\.openURL, OpenURLAction { url in MessageBody.opensLink(url) ? .systemAction : .discarded })
        }
            .defaultSize(DS.Size.windowDefault)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(after: .sidebar) {
                    Toggle("Animate Interface Changes", isOn: $motion)
                }
            }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var visibilityObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Pasted images left behind by a crash or a kill (no quit purge ran): nothing can reference them.
        PasteboardAttachments.purge()
        // Notifications (D1): the UserNotifications delegate must be in place before a click that launched the
        // app is delivered. Nothing is requested from the user until the first notification (lazy authorization).
        MainActor.assumeIsolated { _ = AppModel.shared.notifications }
        // `swift run` launches a bare executable: make it a regular foreground app with a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        switch ProcessInfo.processInfo.environment["HERMES_BOT_APP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // SIGTERM and SIGINT (Ctrl+C in the launching terminal) → the same graceful path as Quit
        // (detach chats, stop only an owned backend). A repeated signal while cleanup runs is a
        // no-op (`cleanupStarted`). An owned backend is spawned in its own process group, so the
        // terminal's SIGINT does not reach it before cleanup has used it.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        // Kanban polling pauses while no main window is on screen (hidden app, minimised or covered windows;
        // the Settings window does not count).
        let names: [Notification.Name] = [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.updateVisibility() }
            })
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Detach the Bot Chats (they stay in Hermes), then stop the backend only if we spawned it. If we
    /// crash instead, the spawned backend's HERMES_PARENT_PID watchdog exits it.
    ///
    /// Not `.terminateLater`: that parks the run loop in a modal mode, and the MainActor
    /// continuations of the async cleanup (and the SIGTERM source on the main queue) never ran,
    /// so a scripted quit hung until SIGKILL (evidence/m1/app-attach-console.log). Instead: cancel,
    /// clean up on the normal run loop, then terminate again.
    ///
    /// Cleanup has an overall deadline (`quitDeadline`): a stuck backend (an RPC that never answers)
    /// must not hang ⌘Q, Ctrl+C or SIGTERM. Past it the app exits anyway; an owned backend is stopped
    /// first.
    static let quitDeadline: TimeInterval = 5
    private var cleanupDone = false
    private var cleanupStarted = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupDone { return .terminateNow }
        if !cleanupStarted {
            cleanupStarted = true
            AppModel.shared.log("quit requested: cleaning up before exit")
            Task { @MainActor in
                await AppModel.shared.shutdown()
                self.finishTermination()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitDeadline) {
                MainActor.assumeIsolated {
                    guard !self.cleanupDone else { return }
                    AppModel.shared.abandonShutdown(after: Self.quitDeadline)
                    self.finishTermination()
                }
            }
        }
        return .terminateCancel
    }

    @MainActor private func finishTermination() {
        guard !cleanupDone else { return }
        cleanupDone = true
        PasteboardAttachments.purge()  // pasted images never outlive the app
        NSApp.terminate(nil)
    }
}

// MARK: - views
//
// Layout and tokens: DESIGN.md. Window = native split view: sidebar (system material, Group Chats then
// Bots) + detail with the unified toolbar.

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarWidth, max: DS.Size.sidebarMax)
        } detail: {
            detail
                .frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.window)
        }
        .frame(minWidth: DS.Size.windowMinWidth, minHeight: DS.Size.windowMinHeight)
        .tint(DS.Palette.primary)
        .background(MainWindowMarker { model.markMainWindow($0) })
        .task { await model.connectAtLaunch() }
        .task(id: model.bots.map(\.name)) { AvatarStore.shared.load(bots: model.bots, backend: model.backend) }
        // Not `.sheet`: its slide and dimmer fade ignore the motion gate (MotionSheet.swift).
        .motionSheet(isPresented: $model.showCreateRoom, motion: motion) {
            CreateRoomView(bots: model.bots,
                           onCreate: { name, members in await model.createRoom(name: name, members: members) },
                           onClose: { model.showCreateRoom = false })
        }
        .motionSheet(isPresented: Binding(get: { model.botSheet != nil }, set: { if !$0 { model.botSheet = nil } }),
                     motion: motion) {
            BotSheetContent(sheet: model.botSheet)
        }
    }

    /// One pane at a time: the outgoing pane leaves in the same frame (the selection changes outside any
    /// animation, `SidebarView.selectionTransaction`) and the incoming one fades in on its own (`PaneArrival`).
    /// A pane's identity includes its model instance, so a model replaced after a reconnect gets a fresh view
    /// (its `onAppear` / `task` start the new model).
    @ViewBuilder private var detail: some View {
        if let name = model.selectedBot, let bot = model.bots.first(where: { $0.name == name }) {
            let chat = model.chat(for: bot)
            BotChatView(chat: chat).paneArrival(motion: motion).id(PaneIdentity(name, chat))
        } else if case .room(let id)? = model.selection, let room = model.roomModel(id) {
            let activity = model.activityModel(for: room)
            RoomView(model: room, activity: activity).paneArrival(motion: motion)
                .id(PaneIdentity(id, room, activity))
        } else if case .board(let slug)? = model.selection, let board = model.kanban.model(for: slug) {
            KanbanBoardView(hub: model.kanban, model: board, onSelectBoard: { next in
                withTransaction(SidebarView.selectionTransaction) { model.selection = .board(next) }
            })
            .paneArrival(motion: motion).id(PaneIdentity(slug, board))
        } else {
            placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .connecting:
            EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "Connecting to Hermes",
                           message: "Looking for a running Hermes backend first. A private hermes serve starts only if none is running.") {
                ProgressView().controlSize(.small)
            }
            .navigationTitle("Hermes Bot")
        case .failed(let e):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't reach Hermes", message: e) {
                Button("Try Again") { Task { await model.connect() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
            .navigationTitle("Hermes Bot")
        case .connected:
            EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "Pick a bot or a group chat",
                           message: model.bots.count >= 2 && model.groupsAvailable
                               ? "Chat 1:1 with one bot, or put 2 to 6 bots in a group chat that answers in turns."
                               : "Chat 1:1 with a bot from the sidebar.") {
                if model.bots.count >= 2 && model.groupsAvailable {
                    Button("New Group Chat") { model.showCreateRoom = true }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            .navigationTitle("Hermes Bot")
        }
    }
}

/// A detail pane's view identity: what it shows (bot name, room id, board slug) and the model instances
/// behind it.
struct PaneIdentity: Hashable {
    let key: String
    let models: [ObjectIdentifier?]

    init(_ key: String, _ models: AnyObject?...) {
        self.key = key
        self.models = models.map { $0.map(ObjectIdentifier.init) }
    }
}

/// Reports the window hosting the main window's content, so visibility checks can tell it from Settings.
private struct MainWindowMarker: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> MarkerView {
        let v = MarkerView()
        v.onAttach = onAttach
        return v
    }

    func updateNSView(_ view: MarkerView, context: Context) { view.onAttach = onAttach }

    final class MarkerView: NSView {
        var onAttach: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }
}

// MARK: - settings

/// General (motion), Background (E1, SettingsSections.swift) and Kanban dispatcher (K8).
struct SettingsView: View {
    @StateObject private var background = BackgroundServeSettingsModel()
    var body: some View { SettingsForm(background: background, dispatcher: AppModel.shared.kanban.dispatcher) }
}

/// The Settings window sizes to this form's full height (every section on screen, nothing below the fold)
/// and follows it as rows come and go (SettingsLayoutTests).
struct SettingsForm: View {
    @ObservedObject var background: BackgroundServeSettingsModel
    let dispatcher: DispatcherStatusModel
    @AppStorage(DS.Motion.settingKey) private var motion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Form {
            Section("General") {
                Toggle("Animate interface changes", isOn: $motion)
                Text(reduceMotion
                     ? "Reduce Motion is on in System Settings, so animations stay off."
                     : "New messages, turn status changes and approvals animate once. Reduce Motion in System Settings also turns this off.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BackgroundServeSection(model: background)
            GatewaySection(model: dispatcher)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .tint(DS.Palette.primary)
        .frame(width: DS.Size.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
