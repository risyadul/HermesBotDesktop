import AppKit
import Combine
import HermesGatewayKit
import SwiftUI

// D5 (⌘1…9, ⌘K), D10 (Search Messages) and D15 (mute) on the app model. The pure parts are QuickSwitch.swift
// and Notifications/NotificationMutes.swift.

/// The palette on screen: Go to (⌘K) or Search Messages (⇧⌘F).
enum PaletteMode: Equatable, CaseIterable {
    case switcher, messages

    var title: String {
        switch self {
        case .switcher: return "Go to"
        case .messages: return "Messages"
        }
    }
}

/// A "jump to this message" waiting for its pane: the pane that shows `item` scrolls to `anchor` once and takes it.
@MainActor
final class MessageJumpCenter: ObservableObject {
    struct Request: Equatable {
        let item: SidebarItem
        let anchor: MessageAnchor
        let id = UUID()
    }

    @Published private(set) var pending: Request?

    func request(_ item: SidebarItem, _ anchor: MessageAnchor) { pending = Request(item: item, anchor: anchor) }

    /// The anchor for `item`'s pane, once.
    func take(for item: SidebarItem) -> MessageAnchor? {
        guard let p = pending, p.item == item else { return nil }
        pending = nil
        return p.anchor
    }
}

extension AppModel {
    func openPalette(_ mode: PaletteMode) {
        guard showCreateRoom == false, botSheet == nil, templateSource == nil else { return }
        NSApp?.activate(ignoringOtherApps: true)
        palette = mode
    }

    /// Selects a sidebar item in the main window (⌘1…9, the palette).
    func select(_ item: SidebarItem) {
        withTransaction(SidebarView.selectionTransaction) { selection = item }
    }

    /// ⌘`n`: the n-th group chat or bot the sidebar shows (`SidebarShortcuts`).
    func selectShortcut(_ n: Int) {
        guard let item = SidebarShortcuts.item(n, in: sidebarOrder) else { return }
        select(item)
    }

    /// A menu title for ⌘`n` ("Ops", "Alpha").
    func shortcutTitle(_ item: SidebarItem) -> String {
        switch item {
        case .bot(let name): return bots.first { $0.name == name }?.title ?? "@\(name)"
        case .room(let id): return rooms.first { $0.roomId == id }?.name ?? "Group chat"
        case .board(let slug): return kanban.rows.first { $0.slug == slug }?.name ?? slug
        case .archive: return "Archived group chat"
        }
    }

    var switchCandidates: [QuickSwitchCandidate] {
        QuickSwitch.candidates(rooms: rooms, bots: bots, hidden: { self.botMeta[$0].hidden }, boards: kanban.rows)
    }

    /// D10: what the app holds right now: every open Bot Chat transcript, every open room's log, and for the
    /// other rooms the log tail the sidebar's background pass fetched (`RoomDigestHub.tail`). Nothing is fetched
    /// for a search.
    var searchSources: [MessageSearch.Source] {
        let roomSources = rooms.map { room in
            MessageSearch.source(room: room, events: roomModels[room.roomId]?.timeline.events ?? roomDigests.tail(room.roomId))
        }
        let chatSources = bots.compactMap { bot in chats[bot.name].map { MessageSearch.source(bot: bot, lines: $0.lines) } }
        return roomSources + chatSources
    }

    /// Fires when what `searchSources` reads changed: a Bot Chat's transcript or an open room's log grew, the
    /// sidebar's background tails moved, or chats and rooms came or went. Debounced (a streaming reply changes
    /// the transcript on every delta) and delivered on the main queue after the change landed.
    var searchSourcesChanged: AnyPublisher<Void, Never> {
        let chatLines = $chats.map { chats in Publishers.MergeMany(chats.values.map { $0.$transcript.map { _ in () } }) }
            .switchToLatest()
        let roomLogs = $roomModels.map { rooms in Publishers.MergeMany(rooms.values.map { $0.$timeline.map { _ in () } }) }
            .switchToLatest()
        return Publishers.MergeMany(chatLines.eraseToAnyPublisher(), roomLogs.eraseToAnyPublisher(),
                                    roomDigests.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                                    $bots.map { _ in () }.eraseToAnyPublisher(), $rooms.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(MessageSearchModel.refreshDelay), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Opens a search hit: selects its Bot Chat or room and asks the pane to scroll to the message.
    func open(_ hit: MessageSearch.Hit) {
        jumps.request(hit.item, hit.anchor)
        select(hit.item)
    }

    func toggleMute(_ item: SidebarItem) {
        mutes.setMuted(item, !mutes.isMuted(item))
    }
}

/// Scrolls a transcript to a found message (D10) when its pane appears or a jump for it arrives. A short delay
/// lets the pane settle at the bottom first (BotChatView `settle`, the room's bottom anchor).
struct MessageJumpTarget: ViewModifier {
    let item: SidebarItem
    let scrollTo: (MessageAnchor) -> Void
    var beforeJump: () -> Void = {}
    @ObservedObject var jumps: MessageJumpCenter = AppModel.shared.jumps
    @Environment(\.motionEnabled) private var motion

    static let settleDelay: TimeInterval = 0.2

    func body(content: Content) -> some View {
        content
            .onAppear { consume() }
            .onChange(of: jumps.pending) { _, _ in consume() }
    }

    private func consume() {
        guard jumps.pending?.item == item else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
            guard let anchor = jumps.take(for: item) else { return }
            beforeJump()
            withDSAnimation(motion, DS.Motion.ease) {
                scrollTo(anchor)
            }
        }
    }
}

extension View {
    func messageJumpTarget(_ item: SidebarItem, proxy: ScrollViewProxy, beforeJump: @escaping () -> Void = {}) -> some View {
        messageJumpTarget(item, beforeJump: beforeJump) { anchor in
            switch anchor {
            case .chatLine(let id): proxy.scrollTo(id, anchor: .center)
            case .roomSeq(let seq): proxy.scrollTo(seq, anchor: .center)
            }
        }
    }

    func messageJumpTarget(_ item: SidebarItem, beforeJump: @escaping () -> Void = {},
                           scrollTo: @escaping (MessageAnchor) -> Void) -> some View {
        modifier(MessageJumpTarget(item: item, scrollTo: scrollTo, beforeJump: beforeJump))
    }
}
