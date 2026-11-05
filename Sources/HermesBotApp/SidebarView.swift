import AppKit
import HermesGatewayKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var botMeta: BotMetaModel
    @ObservedObject private var avatars = AvatarStore.shared
    @Namespace private var selectionSpace
    @FocusState private var focused: Bool
    @FocusState private var filterFocused: Bool
    @Environment(\.motionEnabled) private var motion
    /// The filter field's text (A3); not remembered across launches.
    @State private var query = ""
    /// "Hidden (n)" expanded; session-only, like Desktop's reveal toggle.
    @State private var hiddenExpanded = false

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _botMeta = ObservedObject(wrappedValue: model.botMeta)
    }

    /// C1.4: pinned rooms first, then the user's order (local, `RoomOrderStore`).
    @ObservedObject private var roomOrder = RoomOrderStore.shared

    private var shownRooms: [RoomSummary] { roomOrder.sorted(model.rooms).filter { SidebarFilter.matches($0, query: query) } }
    private var roster: BotRoster {
        BotRoster(bots: model.bots, meta: botMeta.meta, query: query, hiddenExpanded: hiddenExpanded)
    }
    private var shownBoards: [KanbanSidebarRow] { model.kanban.rows.filter { SidebarFilter.matches($0, query: query) } }

    /// What the arrow keys walk: the rows on screen, in drawing order.
    private var order: [SidebarItem] {
        shownRooms.map { .room($0.roomId) } + roster.rows.map { .bot($0.name) } + shownBoards.map { .board($0.slug) }
            + model.desktopArchive.sidebarRooms(query: query).map { .archive($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    sectionHeader("Group Chats") {
                        IconButton(symbol: "plus", label: "New group chat") { model.showCreateRoom = true }
                            .disabled(model.backend == nil || model.bots.count < 2 || !model.groupsAvailable)
                    }
                    if !model.groupsAvailable {
                        Text("Group Chat needs Hermes Agent v2026.9.14 or later.")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    } else if model.rooms.isEmpty {
                        Text(model.phase.isConnected ? "No group chats yet" : "Not loaded yet")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    if SidebarFilter.isActive(query) && order.isEmpty {
                        Text("No matches")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    ForEach(shownRooms) { room in
                        row(.room(room.roomId)) { roomRow(room) }
                            .roomOrdering(room, rooms: model.rooms, store: roomOrder) { select(.room(room.roomId)) }
                    }
                    sectionHeader("Bots") {
                        IconButton(symbol: "plus", label: "New bot") { model.newBot() }
                            .disabled(model.backend == nil || model.botSheet != nil)
                    }
                    if model.bots.isEmpty {
                        Text(model.phase.isConnected ? "No profiles found" : "Not loaded yet")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    if let error = botMeta.lastError {
                        Text(error)
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    let roster = roster
                    ForEach(roster.visible) { bot in botRowButton(bot) }
                    if roster.showHiddenSection {
                        hiddenHeader(roster)
                        if roster.showHiddenRows {
                            ForEach(roster.hidden) { bot in botRowButton(bot) }
                        }
                    }
                    sectionHeader("Boards") { EmptyView() }
                    KanbanSidebarRows(hub: model.kanban, connected: model.phase.isConnected,
                                      matches: { SidebarFilter.matches($0, query: query) }) { board in
                        row(.board(board.slug)) { KanbanBoardRowContent(row: board) }
                    }
                    DesktopArchiveSection(archive: model.desktopArchive, query: query, selection: model.selection,
                                          keyboardFocus: focused, space: selectionSpace, onSelect: select,
                                          onContinue: { model.continueArchivedRoom($0) },
                                          onRemove: { model.removeArchivedRoom($0) })
                }
                .padding(.horizontal, DS.Space.s2).padding(.bottom, DS.Space.s3)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            Hairline()
            footer
        }
    }

    /// A3: the standard filter field (a rounded text field, as on the Kanban board); never bound to ⌘F, which
    /// stays free for Find in chat. Return or ↓ selects the first match and moves to the list; Escape clears.
    private var filterField: some View {
        TextField("Filter", text: $query, prompt: Text("Filter"))
            .textFieldStyle(.roundedBorder)
            .focused($filterFocused)
            .onSubmit(selectFirstMatch)
            .onKeyPress(.downArrow) {
                selectFirstMatch()
                return .handled
            }
            .onExitCommand { query = "" }
            .accessibilityLabel("Filter group chats, bots and boards")
            .help("Filter group chats, bots and boards by name, @handle or model")
            .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s1)
    }

    private func selectFirstMatch() {
        guard let first = order.first else { return }
        select(first)
        filterFocused = false
        focused = true
    }

    /// "Hidden (n)": collapsed by default; a filter shows the matching hidden bots without expanding it.
    private func hiddenHeader(_ roster: BotRoster) -> some View {
        Button { hiddenExpanded.toggle() } label: {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: roster.showHiddenRows ? "chevron.down" : "chevron.right")
                    .font(DS.Typeface.meta)
                Text("Hidden (\(roster.hiddenTotal))").font(DS.Typeface.captionStrong)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.muted)
            .frame(minHeight: DS.Size.sectionHeader)
            .padding(.horizontal, DS.Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(SidebarFilter.isActive(query))
        .accessibilityLabel("Hidden bots, \(roster.hiddenTotal)")
        .accessibilityValue(roster.showHiddenRows ? "expanded" : "collapsed")
    }

    private func botRowButton(_ bot: Bot) -> some View {
        row(.bot(bot.name)) { botRow(bot) }
            .contextMenu { botMenu(bot) }
    }

    /// A1: Open, Pin/Unpin, Hide/Unhide, Copy @handle; A8/A11/A12: Edit…, Duplicate, Delete… (`BotRowMenu`).
    @ViewBuilder private func botMenu(_ bot: Bot) -> some View {
        let meta = botMeta[bot.name]
        let saving = botMeta.isSaving(bot.name)
        ForEach(BotRowMenu.items(meta), id: \.self) { item in
            switch item {
            case .open:
                Button(BotRowMenu.title(item)) { select(.bot(bot.name)) }
                Divider()
            case .pin, .unpin:
                Button(BotRowMenu.title(item)) { botMeta.setPinned(bot.name, item == .pin) }.disabled(saving)
            case .hide, .unhide:
                Button(BotRowMenu.title(item)) { botMeta.setHidden(bot.name, item == .hide) }.disabled(saving)
                Divider()
            case .copyHandle:
                Button(BotRowMenu.title(item)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BotRowMenu.handle(bot), forType: .string)
                }
            default:
                EmptyView()
            }
        }
        Divider()
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
    }

    private func sectionHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
            Spacer()
            trailing()
        }
        .frame(minHeight: DS.Size.sectionHeader)
        .padding(.horizontal, DS.Space.s2).padding(.top, DS.Space.s3).padding(.bottom, DS.Space.s0)
        .accessibilityAddTraits(.isHeader)
    }

    private func row<Content: View>(_ item: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button { select(item) } label: {
            content()
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .frame(maxWidth: .infinity, minHeight: DS.Size.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: model.selection == item, keyboardFocus: focused, space: selectionSpace))
        .accessibilityAddTraits(model.selection == item ? .isSelected : [])
    }

    /// Last message + age, "needs you" badge, live dot (RoomDigests.swift).
    private func roomRow(_ room: RoomSummary) -> some View {
        RoomRowContent(room: room, digests: model.roomDigests, live: model.roomModels[room.roomId],
                       onScreen: model.selection == .room(room.roomId), pinned: roomOrder.isPinned(room.roomId))
    }

    private func botRow(_ bot: Bot) -> some View {
        HStack(spacing: DS.Space.gutter) {
            AvatarView(identity: avatars.identity(profile: bot.name, title: bot.title))
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                HStack(spacing: DS.Space.s2) {
                    Text(bot.title).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if bot.isDefault && bot.title.lowercased() != "default" { DefaultTag() }
                }
                if let sub = bot.model ?? bot.description {
                    Text(sub).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if botMeta[bot.name].pinned {
                Image(systemName: "pin.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .help("Pinned to the top")
                    .accessibilityLabel("Pinned")
            }
            if let chat = model.chats[bot.name] { BotChatBadge(chat: chat) }
        }
    }

    /// Connection footer: dot + the backend in two or three words (fits the 220 pt minimum sidebar
    /// without truncating); the full mode text is the tooltip.
    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            switch model.phase {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .failed:
                StatusDot(color: DS.Palette.danger)
                Text("Not connected")
            case .connected:
                StatusDot(color: DS.Palette.statusOK)
                Text(connectionLabel)
            }
            Spacer(minLength: 0)
        }
        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.gutter)
        .help(model.modeText)
        .accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        switch model.backend?.mode {
        case .attached(let a)?: return a.role == .desktopServe ? "Hermes Desktop" : "hermes serve"
        case .spawned?: return "Private hermes serve"
        case nil: return "Connected"
        }
    }

    private func select(_ item: SidebarItem) {
        withTransaction(Self.selectionTransaction) { model.selection = item }
    }

    /// Switching panes is never an animated transaction. An animated one (the spring this used) keeps every
    /// pane it removes on screen, fully opaque, until the animation settles (~0.7 s), so switching quickly
    /// showed an older room under the new pane's fade-in, and animated the new pane's whole first layout.
    /// The incoming pane fades in on its own (`PaneArrival`).
    static var selectionTransaction: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    /// Up/down arrows move the selection through rooms, bots, then boards (the sidebar is focusable).
    private func move(_ direction: MoveCommandDirection) {
        let items = order
        guard !items.isEmpty else { return }
        let i = model.selection.flatMap { items.firstIndex(of: $0) }
        switch direction {
        case .up: select(items[max(0, (i ?? items.count) - 1)])
        case .down: select(items[min(items.count - 1, (i ?? -1) + 1)])
        default: break
        }
    }
}

/// `sidebar-row`: hover tint; the selection background is one shape that slides between rows.
/// While the sidebar has keyboard focus (arrow keys move the selection) the selected row carries the
/// focus ring instead of the whole column.
struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    var keyboardFocus = false
    let space: Namespace.ID
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Palette.selected)
                            .overlay {
                                // System focus colour: keyboard focus follows the user's macOS setting.
                                if keyboardFocus {
                                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: DS.Stroke.keyboardFocus)
                                }
                            }
                            .matchedGeometryEffect(id: "sidebar.selection", in: space)
                    } else if hovering || configuration.isPressed {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.hover)
                    }
                }
        }
    }
}

/// Breathing dot on a room whose round is running.
struct RoomLiveDot: View {
    @ObservedObject var model: RoomModel
    var body: some View {
        if model.active {
            StatusDot(color: DS.Palette.primary, live: true)
                .help("A round is running")
                .accessibilityLabel("Round running")
        }
    }
}

/// A bot's Bot Chat state in its sidebar row, for every bot with an open chat (the on-screen one too): a
/// count of the request cards waiting on an answer (attention role), else a breathing dot while a reply runs.
struct BotChatBadge: View {
    @ObservedObject var chat: ChatModel

    enum Kind: Equatable {
        case none, replying
        case waiting(Int)
    }

    static func kind(requests: Int, busy: Bool) -> Kind {
        if requests > 0 { return .waiting(requests) }
        return busy ? .replying : .none
    }

    static func accessibilityLabel(_ kind: Kind, bot: String) -> String? {
        switch kind {
        case .none: return nil
        case .replying: return "\(bot) is replying"
        case .waiting(let n): return n == 1 ? "\(bot) needs your answer" : "\(bot) needs your answer (\(n) requests)"
        }
    }

    var body: some View {
        let kind = Self.kind(requests: chat.requests.count, busy: chat.busy)
        let label = Self.accessibilityLabel(kind, bot: chat.bot.title) ?? ""
        switch kind {
        case .none:
            EmptyView()
        case .replying:
            StatusDot(color: DS.Palette.primary, live: true).help(label).accessibilityLabel(label)
        case .waiting(let n):
            Text("\(n)")
                .font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.ink)
                .padding(.horizontal, DS.Space.s1 + DS.Space.s0).padding(.vertical, DS.Space.s0 / 2)
                .background(DS.Palette.attentionSoft, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.hairline))
                .help(label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}
