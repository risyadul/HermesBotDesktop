import AppKit
import HermesGatewayKit
import SwiftUI

// D9: a Bot Chat or a room in its own window. The scene is `WindowGroup(for: SidebarItem.self)`
// (HermesBotApp.swift); its content shows the SAME models as the main window (`AppModel.chat(for:)`,
// `AppModel.roomModel(_:)`, `AppModel.activityModel(for:)`): no second connection, no second poller. A room can
// be on screen in two windows at once, so its pollers count viewers (`PaneViewers`): each pane instance registers
// on appear and leaves on disappear, and polling stops only when the last one has left.

// MARK: - viewers

/// One pane instance (a `RoomView` or an Activity panel), by identity only.
final class PaneViewer {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// The panes showing one room model. Registering twice is a no-op, so an extra `onAppear` cannot keep a poller
/// alive; a viewer that reported its window hidden does not count as on screen.
struct PaneViewers: Equatable {
    /// Callers that do not name a viewer (tests, scripted runs) share this one.
    static let anonymous = ObjectIdentifier(PaneViewer.self)

    private(set) var shown: Set<ObjectIdentifier> = []
    private var hidden: Set<ObjectIdentifier> = []

    var isEmpty: Bool { shown.isEmpty }

    /// Some registered viewer is on screen. With none registered, only what was reported counts (a window can
    /// report hidden before its pane appears).
    var anyVisible: Bool {
        shown.isEmpty ? hidden.isEmpty : shown.contains { !hidden.contains($0) }
    }

    mutating func add(_ viewer: ObjectIdentifier) { shown.insert(viewer) }

    mutating func remove(_ viewer: ObjectIdentifier) {
        shown.remove(viewer)
        hidden.remove(viewer)
    }

    mutating func setVisible(_ visible: Bool, _ viewer: ObjectIdentifier) {
        if visible { hidden.remove(viewer) } else { hidden.insert(viewer) }
    }

    mutating func removeAll() {
        shown = []
        hidden = []
    }
}

// MARK: - scene value

/// The window scene's value: restorable across launches, so it is a plain string (`bot:<name>`,
/// `room:<id>`, `board:<slug>`, `archive:<key>`).
extension SidebarItem: Codable {
    var token: String {
        switch self {
        case .bot(let name): return "bot:\(name)"
        case .room(let id): return "room:\(id)"
        case .board(let slug): return "board:\(slug)"
        case .archive(let key): return "archive:\(key)"
        }
    }

    init?(token: String) {
        let kinds: [(String, (String) -> SidebarItem)] = [("bot:", { .bot($0) }), ("room:", { .room($0) }),
                                                           ("board:", { .board($0) }), ("archive:", { .archive($0) })]
        for (prefix, make) in kinds where token.hasPrefix(prefix) && token.count > prefix.count {
            self = make(String(token.dropFirst(prefix.count)))
            return
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard let item = SidebarItem(token: try c.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a sidebar item")
        }
        self = item
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(token)
    }

    /// Only Bot Chats and rooms open in their own window (boards and the archive stay in the main window).
    var opensInWindow: Bool {
        switch self {
        case .bot, .room: return true
        case .board, .archive: return false
        }
    }
}

// MARK: - window content

enum DetachedPane {
    static let sceneId = "pane"

    enum Content: Equatable {
        case bot(Bot)
        case room(String)
        /// Still connecting (or reconnecting): the item may come back.
        case waiting
        /// Connected, and the bot or room is not there (deleted, disbanded) or cannot open in a window.
        case gone(String)
    }

    static func content(_ item: SidebarItem?, connected: Bool, bots: [Bot], rooms: [RoomSummary]) -> Content {
        guard let item, item.opensInWindow else { return .gone("This window can show a Bot Chat or a group chat.") }
        switch item {
        case .bot(let name):
            if let bot = bots.first(where: { $0.name == name }) { return .bot(bot) }
            return connected ? .gone("The bot @\(name) is no longer on this Hermes.") : .waiting
        case .room(let id):
            if rooms.contains(where: { $0.roomId == id }) { return .room(id) }
            return connected ? .gone("This group chat was disbanded or is not on this Hermes.") : .waiting
        case .board, .archive:
            return .gone("This window can show a Bot Chat or a group chat.")
        }
    }
}

/// A Bot Chat or a room in its own window (D9), on the main window's models.
struct DetachedPaneView: View {
    @ObservedObject var model: AppModel
    let item: SidebarItem?

    var body: some View {
        content
            .frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, minHeight: DS.Size.windowMinHeight, maxHeight: .infinity)
            .background(DS.Palette.window)
            .tint(DS.Palette.primary)
            // A window restored at launch without the main window still connects (once for the app).
            .task { await model.connectOnce() }
    }

    @ViewBuilder private var content: some View {
        switch DetachedPane.content(item, connected: model.phase.isConnected, bots: model.bots, rooms: model.rooms) {
        case .bot(let bot):
            let chat = model.chat(for: bot)
            BotChatView(chat: chat).id(PaneIdentity(bot.name, chat))
        case .room(let id):
            if let room = model.roomModel(id) {
                let activity = model.activityModel(for: room)
                RoomView(model: room, activity: activity).id(PaneIdentity(id, room, activity))
            }
        case .waiting:
            EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "Connecting to Hermes",
                           message: "This window shows its chat once the app is connected.") {
                ProgressView().controlSize(.small)
            }
            .navigationTitle("Hermes Bot")
        case .gone(let message):
            EmptyStateView(symbol: "questionmark.bubble", title: "Not available", message: message) { EmptyView() }
                .navigationTitle("Hermes Bot")
        }
    }
}

/// ⌘-double-click on a sidebar row opens it in its own window.
struct OpenInWindowGesture: ViewModifier {
    let item: SidebarItem
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        if item.opensInWindow {
            content.simultaneousGesture(TapGesture(count: 2).modifiers(.command).onEnded { openWindow(value: item) })
        } else {
            content
        }
    }
}

extension AppModel {
    @MainActor private static var launchConnect: Task<Void, Never>?

    /// `connectAtLaunch` once per app run, whichever window appears first (the main window, or a D9 window
    /// restored on its own); later callers wait for that same attempt. Try Again uses `connect()`.
    func connectOnce() async {
        if let running = Self.launchConnect { return await running.value }
        let task = Task { await self.connectAtLaunch() }
        Self.launchConnect = task
        await task.value
    }
}
