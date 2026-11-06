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
    @ObservedObject private var activity: BotActivityHub
    @ObservedObject private var sections: BotSectionsModel
    /// New Section… / Rename Section… (A5). The request outlives the sheet's dismissal so it does not empty
    /// while it slides away.
    @State private var sectionRequest: SectionNameRequest = .create(filing: nil)
    @State private var showSectionSheet = false
    /// Open Recent Session (A17), kept for the same reason.
    @State private var recent: RecentSessionModel?
    @State private var showRecent = false
    /// The section block a dragged bot row is over.
    @State private var dropTarget: String?

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _botMeta = ObservedObject(wrappedValue: model.botMeta)
        _activity = ObservedObject(wrappedValue: model.botActivity)
        _sections = ObservedObject(wrappedValue: model.botSections)
    }

    /// C1.4: pinned rooms first, then the user's order (local, `RoomOrderStore`).
    @ObservedObject private var roomOrder = RoomOrderStore.shared

    private var shownRooms: [RoomSummary] { roomOrder.sorted(model.rooms).filter { SidebarFilter.matches($0, query: query) } }
    private var roster: BotRoster {
        BotRoster(bots: model.bots, meta: botMeta.meta, query: query, hiddenExpanded: hiddenExpanded,
                  lastActive: activity.activity.mapValues(\.lastActive), sections: sections.sections,
                  collapsed: sections.collapsed)
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
                        IconButton(symbol: "folder.badge.plus", label: "New section") { askSectionName(.create(filing: nil)) }
                            .disabled(model.backend == nil || model.bots.isEmpty)
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
                    if let deletion = sections.lastDelete {
                        SectionUndoLine(deletion: deletion, onUndo: { sections.undoDelete(meta: botMeta.meta) },
                                        onDismiss: { sections.dismissDelete() })
                    }
                    let roster = roster
                    if roster.blocks.isEmpty {
                        ForEach(roster.visible) { bot in botRowButton(bot) }
                    } else {
                        ForEach(roster.blocks) { block in sectionBlock(block, roster) }
                    }
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
        .motionSheet(isPresented: $showSectionSheet, motion: motion) {
            SectionNameView(request: sectionRequest, onSave: saveSectionName, onClose: { showSectionSheet = false })
                .id(sectionRequest.id)
        }
        .motionSheet(isPresented: $showRecent, motion: motion) {
            if let recent { RecentSessionView(model: recent, onClose: { showRecent = false }).id(recent.id) }
        }
        .onChange(of: order, initial: true) { _, rows in model.sidebarOrder = rows }  // ⌘1…9 (D5)
    }

    // MARK: sections (A5)

    /// One section block: its header (collapse, menu), then its rows or an empty drop slot. The whole block
    /// takes a dropped bot row.
    private func sectionBlock(_ block: BotSectionBlock, _ roster: BotRoster) -> some View {
        let shows = roster.showsRows(block)
        let targeted = dropTarget == block.key
        return VStack(alignment: .leading, spacing: DS.Space.s0) {
            BotSectionHeader(title: block.section?.name ?? "Unassigned", count: block.bots.count, collapsed: !shows,
                             isSection: block.section != nil,
                             dropTargeted: targeted && !(shows && block.bots.isEmpty)) {
                sections.toggleCollapsed(block.key)
            } menu: {
                if let section = block.section { sectionMenu(section) }
            }
            .padding(.top, DS.Space.s1)
            if shows {
                if block.bots.isEmpty && block.section != nil {
                    BotSectionEmptySlot(dropTargeted: targeted)
                } else {
                    ForEach(block.bots) { bot in botRowButton(bot) }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: block.section)
        } isTargeted: { over in
            if over { dropTarget = block.key } else if dropTarget == block.key { dropTarget = nil }
        }
    }

    @ViewBuilder private func sectionMenu(_ section: BotSection) -> some View {
        let index = sections.sections.firstIndex(of: section) ?? 0
        Button("Rename Section…") { askSectionName(.rename(section)) }
        Button("Move Up") { sections.move(section.id, by: -1) }.disabled(index == 0)
        Button("Move Down") { sections.move(section.id, by: 1) }.disabled(index >= sections.sections.count - 1)
        Divider()
        Button("Delete Section", role: .destructive) { sections.delete(section.id, meta: botMeta.meta) }
    }

    /// A bot row dropped on a block: files it there (Unassigned for the Unassigned block).
    private func drop(_ items: [String], into section: BotSection?) -> Bool {
        dropTarget = nil
        let bots = items.compactMap { BotDrag.bot(from: $0, roster: model.bots) }
        guard !bots.isEmpty, model.backend != nil else { return false }
        sections.file(bots.map(\.name), into: section?.id, meta: botMeta.meta)
        return true
    }

    private func askSectionName(_ request: SectionNameRequest) {
        sectionRequest = request
        showSectionSheet = true
    }

    private func saveSectionName(_ name: String) {
        switch sectionRequest {
        case .create(let bot): sections.create(name, filing: bot.map { [$0] } ?? [], meta: botMeta.meta)
        case .rename(let section): sections.rename(section.id, to: name, meta: botMeta.meta)
        }
    }

    /// A17: the bot's newest session other than its Bot Chat, read-only in a sheet.
    private func openRecent(_ bot: Bot, _ session: BotSessionSummary) {
        recent = RecentSessionModel(bot: bot, session: session, reader: RecentSessionModel.reader(model.backend?.sessionREST))
        showRecent = true
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

    /// A bot row: click opens its Bot Chat, right-click its menu, drag files it into a section (A5).
    private func botRowButton(_ bot: Bot) -> some View {
        row(.bot(bot.name)) { botRow(bot) }
            .contextMenu { botMenu(bot) }
            .draggable(BotDrag.payload(bot)) {
                Text(bot.title).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink)
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
            }
    }

    /// A1: Open, Pin/Unpin, Hide/Unhide, Copy @handle; A17: Open Recent Session; A5: Move to Section;
    /// A8/A11/A12: Edit…, Duplicate, Delete… (`BotRowMenu`).
    @ViewBuilder private func botMenu(_ bot: Bot) -> some View {
        let meta = botMeta[bot.name]
        let saving = botMeta.isSaving(bot.name)
        ForEach(BotRowMenu.items(meta), id: \.self) { item in
            switch item {
            case .open:
                Button(BotRowMenu.title(item)) { select(.bot(bot.name)) }
            case .openRecent:
                let session = activity.activity[bot.name]?.recentSession
                Button(BotRowMenu.title(item)) { if let session { openRecent(bot, session) } }
                    .disabled(session == nil || model.backend == nil)
                Divider()
            case .pin, .unpin:
                Button(BotRowMenu.title(item)) { botMeta.setPinned(bot.name, item == .pin) }.disabled(saving)
            case .hide, .unhide:
                Button(BotRowMenu.title(item)) { botMeta.setHidden(bot.name, item == .hide) }.disabled(saving)
            case .moveToSection:
                Menu(BotRowMenu.title(item)) {
                    ForEach(BotRowMenu.sectionChoices(meta, sections: sections.sections), id: \.self) { choice in
                        switch choice {
                        case .section(let s, let current):
                            Button(s.name) { sections.file([bot.name], into: s.id, meta: botMeta.meta) }.disabled(current)
                        case .unassigned:
                            Button("Unassigned") { sections.file([bot.name], into: nil, meta: botMeta.meta) }
                        case .newSection:
                            Divider()
                            Button("New Section…") { askSectionName(.create(filing: bot.name)) }
                        }
                    }
                }
                .disabled(saving || model.backend == nil)
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
        BotManageMenu(bot: bot, model: model)  // also the Bot Chat toolbar's Bot menu
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
        .modifier(OpenInWindowGesture(item: item))  // D9: ⌘-double-click
    }

    /// Last message + age, "needs you" badge, live dot (RoomDigests.swift).
    private func roomRow(_ room: RoomSummary) -> some View {
        RoomRowContent(room: room, digests: model.roomDigests, live: model.roomModels[room.roomId],
                       onScreen: model.selection == .room(room.roomId), pinned: roomOrder.isPinned(room.roomId))
    }

    /// A4: title and the age of the last activity, then the last message (else the model or description);
    /// trailing: pin, the needs-attention badge (A6), then the Bot Chat state or the unread dot.
    private func botRow(_ bot: Bot) -> some View {
        let a = activity.activity[bot.name]
        let unread = activity.isUnread(bot.name, onScreen: model.selection == .bot(bot.name))
        return HStack(spacing: DS.Space.gutter) {
            AvatarView(identity: avatars.identity(profile: bot.name, title: bot.title))
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(bot.title).font(unread ? DS.Typeface.bodyStrong : DS.Typeface.bodyMedium)
                        .foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if bot.isDefault && bot.title.lowercased() != "default" { DefaultTag() }
                    Spacer(minLength: 0)
                    if let stamp = a?.ageStamp, stamp > 0 {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(RoomDigest.age(of: stamp, now: context.date))
                                .font(DS.Typeface.caption.monospacedDigit()).foregroundStyle(DS.Palette.muted)
                        }
                    }
                }
                if let preview = a?.preview {
                    Text(BotRowText.preview(preview))
                        .font(DS.Typeface.meta).italic(preview.fromBot != nil)
                        .foregroundStyle(unread ? DS.Palette.ink : DS.Palette.muted).lineLimit(1)
                } else if let sub = bot.model ?? bot.description {
                    Text(sub).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
            if botMeta[bot.name].pinned {
                Image(systemName: "pin.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .help("Pinned to the top")
                    .accessibilityLabel("Pinned")
            }
            if let attention = activity.attention[bot.name] { BotAttentionBadge(attention: attention) }
            if let chat = model.chats[bot.name] {
                BotChatBadge(chat: chat, unread: unread)
            } else if unread {
                UnreadDot()
            }
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
/// count of the request cards waiting on an answer (attention role), else a breathing dot while a reply runs,
/// else the unread dot (A4).
struct BotChatBadge: View {
    @ObservedObject var chat: ChatModel
    var unread = false

    enum Kind: Equatable {
        case none, replying, unread
        case waiting(Int)
    }

    static func kind(requests: Int, busy: Bool, unread: Bool = false) -> Kind {
        if requests > 0 { return .waiting(requests) }
        if busy { return .replying }
        return unread ? .unread : .none
    }

    static func accessibilityLabel(_ kind: Kind, bot: String) -> String? {
        switch kind {
        case .none: return nil
        case .replying: return "\(bot) is replying"
        case .unread: return "\(bot) has new activity"
        case .waiting(let n): return n == 1 ? "\(bot) needs your answer" : "\(bot) needs your answer (\(n) requests)"
        }
    }

    var body: some View {
        let kind = Self.kind(requests: chat.requests.count, busy: chat.busy, unread: unread)
        let label = Self.accessibilityLabel(kind, bot: chat.bot.title) ?? ""
        switch kind {
        case .none:
            EmptyView()
        case .unread:
            UnreadDot()
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
