import AppKit
import HermesGatewayKit
import SwiftUI

// Layout and tokens: DESIGN.md. Window = native split view: sidebar (system material, Group Chats then
// Bots) + detail with the unified toolbar.

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.motionEnabled) private var motion
    /// The window's height (content plus the toolbar inset): bounds the bot Edit sheet.
    @State private var windowHeight = DS.Size.windowMinHeight

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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom }) {
            windowHeight = $0
        }
        .task { await model.connectOnce() }
        .task(id: model.bots.map(\.name)) { AvatarStore.shared.load(bots: model.bots, backend: model.backend) }
        // Not `.sheet`: its slide and dimmer fade ignore the motion gate (MotionSheet.swift).
        // Closed any way (Cancel, Escape, Create, the window): a Desktop-archive prefill goes with it.
        .motionSheet(isPresented: Binding(get: { model.showCreateRoom },
                                          set: { if $0 { model.showCreateRoom = true } else { model.closeCreateRoom() } }),
                     motion: motion) {
            CreateRoomView(bots: model.bots, prefill: model.createRoomPrefill,
                           onCreate: { name, members in await model.createRoomFromSheet(name: name, members: members) },
                           onClose: { model.closeCreateRoom() })
        }
        .motionSheet(isPresented: $model.showDesktopImport, motion: motion) {
            DesktopImportView(archive: model.desktopArchive, onImport: { model.importDesktopRooms($0) },
                              onRetry: { model.openDesktopImport() }, onClose: { model.closeDesktopImport() })
        }
        .motionSheet(isPresented: Binding(get: { model.botSheet != nil }, set: { if !$0 { model.botSheet = nil } }),
                     motion: motion) {
            BotSheetContent(sheet: model.botSheet, windowHeight: windowHeight)
        }
        // K9: Create Task from Message (KanbanIntegrations.swift).
        .modifier(KanbanComposePresenter(hub: model.kanban, bots: model.bots.map(\.name), motion: motion))
        // D5 / D10: ⌘K and ⇧⌘F (CommandPaletteView.swift); D13: Save as Template (RoomTemplates.swift).
        .motionSheet(isPresented: Binding(get: { model.palette != nil }, set: { if !$0 { model.palette = nil } }),
                     motion: motion) {
            if let mode = model.palette {
                CommandPaletteView(model: model, mode: mode, onClose: { model.palette = nil })
            }
        }
        .motionSheet(isPresented: Binding(get: { model.templateSource != nil }, set: { if !$0 { model.templateSource = nil } }),
                     motion: motion) {
            if let room = model.templateSource {
                SaveRoomTemplateView(room: room, onSave: { name, prompt in
                    switch model.roomTemplates.save(name: name, members: room.members.map(\.profile), prompt: prompt) {
                    case .success: return nil
                    case .failure(let e): return e.message
                    }
                }, onClose: { model.templateSource = nil })
            }
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
            }, onOpenBot: { model.openBotChat($0) }, canOpenBot: { model.canOpenBotChat($0) })
            .paneArrival(motion: motion).id(PaneIdentity(slug, board))
        } else if case .archive(let key)? = model.selection, let room = model.desktopArchive.room(key) {
            DesktopArchiveRoomView(room: room, bots: model.bots,
                                   canContinue: DesktopArchivePresentation.canContinue(
                                       room, bots: model.bots, connected: model.phase.isConnected,
                                       groupsAvailable: model.groupsAvailable),
                                   onContinue: { model.continueArchivedRoom(room) },
                                   onRemove: { model.removeArchivedRoom(key) })
                .paneArrival(motion: motion).id(PaneIdentity(key))
        } else if let screen = Onboarding.screen(phase: model.phase, issue: model.setupIssue, bots: model.bots,
                                                 groupsAvailable: model.groupsAvailable) {
            // E2: one guided first-run screen instead of a bare error (OnboardingView.swift).
            OnboardingView(screen: screen,
                           onTryAgain: { Task { await model.connect() } },
                           onCheckAgain: { Task { await model.recheckSetup() } },
                           onOpenBot: { name in withTransaction(SidebarView.selectionTransaction) { model.selection = .bot(name) } })
                .navigationTitle("Hermes Bot")
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
