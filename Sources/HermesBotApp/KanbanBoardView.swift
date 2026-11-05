import AppKit
import HermesGatewayKit
import SwiftUI

// Kanban board pane (K1 + K3 + the K8 dispatcher chip): header (board switcher, filter, dispatcher chip),
// a note bar, and the lanes as a horizontally scrolling row. Cards drag between lanes and carry a context
// menu; the card details inspector is KanbanTaskInspector.swift. Look: DESIGN.md "Kanban".

extension DS {
    /// Kanban sizes (DESIGN.md "Kanban").
    enum Kanban {
        static let laneWidth: CGFloat = 248
        /// An empty lane folded into a strip: vertical label + count (KanbanColumns.isCollapsed).
        static let collapsedLaneWidth: CGFloat = 36
        static let filterWidth: CGFloat = 220
        static let logMaxHeight: CGFloat = 240
        static let descriptionHeight: CGFloat = 96
        static let commentLines = 1...5
        static let titleLines = 3
    }
}

struct KanbanBoardView: View {
    @ObservedObject var hub: KanbanHub
    @ObservedObject var model: KanbanBoardModel
    let onSelectBoard: (String) -> Void
    /// K9: open a bot's Bot Chat (a card's assignee), and whether that bot is in the roster.
    var onOpenBot: ((String) -> Void)?
    var canOpenBot: (String) -> Bool = { _ in false }
    /// The inspector opens when a card is selected unless the user closed it (KanbanInspectorRule); that
    /// choice is remembered. Visibility is @State like Bot Chat's (BotChatView.swift: an @AppStorage binding
    /// loses the no-animation transaction).
    @AppStorage("hba.kanbanInspectorClosed") private var inspectorClosedByUser = false
    @State private var showInspector = false
    /// Empty lanes the user unfolded.
    @State private var expandedLanes: Set<String> = []
    @State private var query = ""
    /// K4: one profile at a time (nil = all), and Running grouped by profile (persisted, as Desktop's).
    @State private var assigneeFilter: String?
    @AppStorage("hba.kanbanGroupRunning") private var groupRunning = false
    @State private var showWorkers = false
    @State private var showNewTask = false
    @State private var archiveCandidate: KanbanTask?
    @State private var dropTarget: String?
    /// K7: New Board / Rename / Orchestration sheet, and the Delete confirmation.
    @State private var boardSheet: BoardSheet?
    @State private var confirmDelete = false
    @Environment(\.motionEnabled) private var motion

    private var name: String { hub.summary(model.slug)?.name ?? model.slug }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            noteBar
            content
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(DS.Palette.window)
        .navigationTitle(name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            KanbanTaskInspector(model: model, onArchive: { archiveCandidate = $0 }, openBotChat: botChat)
                .inspectorColumnWidth(min: DS.Size.inspectorMin, ideal: DS.Size.inspectorWidth, max: DS.Size.inspectorMax)
        }
        .onChange(of: showInspector) { _, shown in
            inspectorClosedByUser = KanbanInspectorRule.closedByUser(afterShown: shown, selection: model.selectedTaskId,
                                                                     was: inspectorClosedByUser)
        }
        .onChange(of: model.selectedTaskId) { _, id in
            setInspector(KanbanInspectorRule.shown(selection: id, closedByUser: inspectorClosedByUser))
        }
        // Polling (board and dispatcher record) pauses while no app window is on screen (KanbanHub.setActive).
        .onAppear {
            setInspector(KanbanInspectorRule.shown(selection: model.selectedTaskId, closedByUser: inspectorClosedByUser), animated: false)
            model.start(); hub.watchDispatcher(true)
        }
        .onDisappear { model.stop(); hub.watchDispatcher(false) }
        .confirmationDialog("Archive “\(archiveCandidate?.title ?? "")”?",
                            isPresented: Binding(get: { archiveCandidate != nil }, set: { if !$0 { archiveCandidate = nil } })) {
            Button("Archive", role: .destructive) {
                if let t = archiveCandidate { Task { await model.archive(t.id) } }
                archiveCandidate = nil
            }
        } message: { Text("The card leaves the board. Archived cards stay in Hermes.") }
        .confirmationDialog(KanbanBoardRules.archiveTitle(name), isPresented: $confirmDelete) {
            Button("Delete Board", role: .destructive) { deleteBoard() }
        } message: { Text(KanbanBoardRules.archiveMessage(hub.summary(model.slug))) }
        .modifier(KanbanAIConfirmation(ai: model.ai))
        .motionSheet(isPresented: Binding(get: { boardSheet != nil }, set: { if !$0 { boardSheet = nil } }), motion: motion) {
            boardSheetContent
        }
        .motionSheet(isPresented: $showNewTask, motion: motion) {
            KanbanNewTaskSheet(lanes: model.serverLanes.map(\.name), assignees: model.assigneeNames,
                               onCreate: { draft, column in await model.create(draft, column: column) },
                               onClose: { showNewTask = false })
        }
        .motionSheet(isPresented: $showWorkers, motion: motion) {
            KanbanWorkersSheet(slug: model.slug, api: model.api,
                               onOpenTask: { id in showWorkers = false; openTask(id) },
                               onChanged: { Task { await model.refresh() } },
                               onClose: { showWorkers = false })
        }
    }

    enum BoardSheet: Equatable { case new, rename, orchestration }

    @ViewBuilder private var boardSheetContent: some View {
        switch boardSheet {
        case .new?:
            KanbanBoardNameSheet(mode: .create, initialName: "", existing: hub.boards, onSave: { name in
                switch await hub.createBoard(name: name) {
                case .success(let slug): onSelectBoard(slug); return nil
                case .failure(let f): return f.message
                }
            }, onClose: { boardSheet = nil })
        case .rename?:
            KanbanBoardNameSheet(mode: .rename(slug: model.slug), initialName: name, existing: hub.boards,
                                 onSave: { await hub.renameBoard(model.slug, to: $0) }, onClose: { boardSheet = nil })
        case .orchestration?:
            KanbanOrchestrationSheet(api: model.api, onClose: { boardSheet = nil })
        case nil:
            EmptyView()
        }
    }

    /// K7 Delete: archive, then go to another board (the gone board's pane would only say so).
    private func deleteBoard() {
        let slug = model.slug, next = Self.otherBoard(hub.rows, current: slug), select = onSelectBoard
        Task {
            if await hub.archiveBoard(slug) == nil, let next { select(next) }
        }
    }

    /// K9: the card's assignee Bot Chat, when that bot is in the roster.
    private func botChat(_ task: KanbanTask) -> (() -> Void)? {
        guard let who = task.assignee, let onOpenBot, canOpenBot(who) else { return nil }
        return { onOpenBot(who) }
    }

    /// Where "Go to Another Board" leads: the first other listed board, or nil when there is none.
    static func otherBoard(_ rows: [KanbanSidebarRow], current: String) -> String? {
        rows.first { $0.slug != current }?.slug
    }

    private var subtitle: String {
        let total = model.serverLanes.filter { $0.name != KanbanColumns.archived }.reduce(0) { $0 + $1.tasks.count }
        return total == 1 ? "1 task" : "\(total) tasks"
    }

    // MARK: toolbar + header

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showNewTask = true } label: { Label("New Task", systemImage: "plus") }
                .labelStyle(.titleAndIcon)
                .help("Create a task on this board")
                .disabled(model.state != .ready)
            Button { setInspector(!showInspector) } label: { Label("Card Details", systemImage: "sidebar.trailing") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide card details (⌥⌘I)")
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            let rows = hub.rows
            if rows.count > 1 {
                Menu {
                    ForEach(rows) { row in
                        Button { onSelectBoard(row.slug) } label: {
                            if row.slug == model.slug { Label(row.name, systemImage: "checkmark") } else { Text(row.name) }
                        }
                    }
                } label: { Label(name, systemImage: "rectangle.split.3x1") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Switch board")
            }
            KanbanBoardMenu(hub: hub, slug: model.slug, onNew: { boardSheet = .new }, onRename: { boardSheet = .rename },
                            onOrchestration: { boardSheet = .orchestration }, onDelete: { confirmDelete = true },
                            onSelectBoard: onSelectBoard)
            TextField("Filter by title or @assignee", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: DS.Kanban.filterWidth)
            KanbanFilterMenu(assignee: $assigneeFilter, profiles: model.assigneeNames, archived: model.includeArchived,
                             onArchived: { model.setIncludeArchived($0) }, groupRunning: $groupRunning)
            Button { showWorkers = true } label: { Label("Workers", systemImage: "cpu") }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .help("Active workers: inspect, terminate or reclaim a run")
                .disabled(model.state != .ready)
            Spacer(minLength: DS.Space.s2)
            DispatcherChipView(model: hub.dispatcher)
        }
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s2)
    }

    @ViewBuilder private var noteBar: some View {
        if let error = model.error {
            note(error, symbol: "exclamationmark.triangle.fill", color: DS.Palette.danger) { model.dismissError() }
        } else if let notice = model.notice {
            note(notice, symbol: "exclamationmark.circle.fill", color: DS.Palette.attention) { model.dismissNotice() }
        } else if let sync = model.syncError {
            note("Board not refreshed: \(sync). Retrying.", symbol: "arrow.clockwise", color: DS.Palette.muted, dismiss: nil)
        } else if let board = hub.boardNote {
            note(board.text, symbol: board.isError ? "exclamationmark.triangle.fill" : "checkmark.circle",
                 color: board.isError ? DS.Palette.danger : DS.Palette.muted) { hub.dismissBoardNote() }
        }
    }

    private func note(_ text: String, symbol: String, color: Color, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: symbol).font(DS.Typeface.iconSmall)
            Text(text).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: DS.Space.s2)
            if let dismiss { IconButton(symbol: "xmark", label: "Dismiss", action: dismiss) }
        }
        .font(DS.Typeface.meta)
        .foregroundStyle(color)
        .padding(.horizontal, DS.Space.s4)
        .frame(minHeight: DS.Size.controlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            EmptyStateView(symbol: "rectangle.split.3x1", title: "Loading board", message: "Fetching the cards from Hermes.") {
                ProgressView().controlSize(.small)
            }
        case .unavailable:
            EmptyStateView(symbol: "rectangle.split.3x1", title: "Kanban is off in Hermes",
                           message: "Turn on the kanban plugin in Hermes to see this board here.") {
                Button("Try Again") { model.stop(); model.start() }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
        case .gone:
            EmptyStateView(symbol: "rectangle.slash", title: KanbanBoardModel.goneMessage,
                           message: "It is no longer on Hermes' board list. Its cards cannot be changed from here.") {
                if let next = Self.otherBoard(hub.rows, current: model.slug) {
                    Button("Go to Another Board") { onSelectBoard(next) }.buttonStyle(DSButtonStyle(kind: .primary))
                }
            }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't load this board", message: message) {
                Button("Try Again") { model.stop(); model.start() }.buttonStyle(DSButtonStyle(kind: .primary))
            }
        case .ready:
            lanes
        }
    }

    private var lanes: some View {
        let visible = KanbanFilter.apply(KanbanProfileFilter.apply(model.lanes, assignee: assigneeFilter), query: query)
        let filtering = !KanbanFilter.terms(query).isEmpty || assigneeFilter != nil
        let names = model.serverLanes.map(\.name)
        let now = model.serverNow ?? Int(Date().timeIntervalSince1970)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DS.Space.s3) {
                    ForEach(visible) { lane in
                        laneColumn(lane, in: visible, filtering: filtering, now: now, names: names).id(lane.name)
                    }
                }
                .padding(DS.Space.s4)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // The selected card's lane is scrolled into view (the least distance) when the selection changes
            // and when the board narrows, e.g. as the inspector opens.
            .onChange(of: model.selectedTaskId) { _, _ in reveal(proxy, in: visible, animated: true) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in reveal(proxy, in: visible, animated: false) }
            .onAppear { reveal(proxy, in: visible, animated: false) }
        }
        .overlay {
            if filtering && visible.allSatisfy(\.tasks.isEmpty) {
                Text(KanbanFilter.terms(query).isEmpty ? "No cards for @\(assigneeFilter ?? "")" : "No cards match “\(query)”")
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
            }
        }
    }

    @ViewBuilder
    private func laneColumn(_ lane: KanbanLane, in visible: [KanbanLane], filtering: Bool, now: Int, names: [String]) -> some View {
        let targeted = dropTarget == lane.name
        Group {
            if KanbanColumns.isCollapsed(lane, in: visible, expanded: expandedLanes) {
                KanbanCollapsedLaneView(lane: lane, targeted: targeted) { setExpanded(lane.name, true) }
            } else {
                KanbanLaneView(lane: lane, filtering: filtering, now: now, targeted: targeted,
                               model: model, laneNames: names,
                               groupByProfile: KanbanProfileFilter.groupsLane(lane, enabled: groupRunning),
                               onSelect: { model.select($0.id) }, onOpen: open, onArchive: { archiveCandidate = $0 },
                               botChat: botChat,
                               onCollapse: lane.tasks.isEmpty && expandedLanes.contains(lane.name)
                                   ? { setExpanded(lane.name, false) } : nil)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, !KanbanColumns.locked.contains(lane.name),
                  lane.name != KanbanColumns.archived, model.task(id) != nil else { return false }
            Task { await model.move(id, to: lane.name) }
            return true
        } isTargeted: { on in
            if on { dropTarget = lane.name } else if dropTarget == lane.name { dropTarget = nil }
        }
    }

    private func setExpanded(_ lane: String, _ expanded: Bool) {
        withDSAnimation(motion, DS.Motion.ease) {
            if expanded { expandedLanes.insert(lane) } else { expandedLanes.remove(lane) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy, in lanes: [KanbanLane], animated: Bool) {
        guard let lane = KanbanColumns.lane(containing: model.selectedTaskId, in: lanes) else { return }
        withDSAnimation(animated && motion, DS.Motion.ease) { proxy.scrollTo(lane) }
    }

    private func setInspector(_ shown: Bool, animated: Bool = true) {
        guard shown != showInspector else { return }
        withDSAnimation(animated && motion) { showInspector = shown }
    }

    /// "Open" (context menu, accessibility action): select and show the details even if the user had closed
    /// them. A plain click only selects (the inspector follows KanbanInspectorRule).
    private func open(_ task: KanbanTask) { openTask(task.id) }

    private func openTask(_ id: String) {
        inspectorClosedByUser = false  // before selecting, so the selection handler agrees
        model.select(id)
        setInspector(true)
    }
}

/// An empty lane folded into a slim strip: count, vertical label, lock for dispatcher-only lanes. Click
/// unfolds it; it still takes dropped cards (the parent's drop destination), and a dropped card unfolds it.
struct KanbanCollapsedLaneView: View {
    let lane: KanbanLane
    let targeted: Bool
    let onExpand: () -> Void

    private var locked: Bool { KanbanColumns.locked.contains(lane.name) }

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: DS.Space.s2) {
                Text("\(lane.tasks.count)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                VerticalLabel {
                    Text(KanbanColumns.label(lane.name)).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                        .lineLimit(1)
                }
                if locked {
                    Image(systemName: "lock").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.s3)
            .frame(width: DS.Kanban.collapsedLaneWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(locked ? DS.Palette.dangerRing : DS.Palette.ring, lineWidth: DS.Stroke.focus)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show the empty \(KanbanColumns.label(lane.name)) lane")
        .accessibilityLabel("\(KanbanColumns.label(lane.name)), empty")
        .accessibilityHint("Shows the lane")
    }
}

/// Lays its content out turned 90° clockwise: reports the content's size with width and height swapped.
private struct VerticalLabel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Rotated { content.rotationEffect(.degrees(90)) }
    }

    private struct Rotated: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
            return CGSize(width: size.height, height: size.width)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        }
    }
}

// MARK: - lane

struct KanbanLaneView: View {
    let lane: KanbanLane
    let filtering: Bool
    let now: Int
    let targeted: Bool
    @ObservedObject var model: KanbanBoardModel
    let laneNames: [String]
    /// Running split into profile groups (K4 "Group Running by profile").
    var groupByProfile = false
    let onSelect: (KanbanTask) -> Void
    let onOpen: (KanbanTask) -> Void
    let onArchive: (KanbanTask) -> Void
    /// K9: the card's assignee Bot Chat, when that bot is in the roster.
    var botChat: (KanbanTask) -> (() -> Void)? = { _ in nil }
    /// Folds an empty lane the user unfolded back into its strip.
    var onCollapse: (() -> Void)?
    @ObservedObject private var avatars = AvatarStore.shared
    @Environment(\.motionEnabled) private var motion

    private var locked: Bool { KanbanColumns.locked.contains(lane.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                    Text(KanbanColumns.label(lane.name)).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                    Text("\(lane.tasks.count)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    Spacer(minLength: 0)
                    if locked {
                        Image(systemName: "lock").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                            .accessibilityLabel("Set by the dispatcher")
                    }
                }
                .accessibilityElement(children: .combine)
                // After the combine: `.help` on the stack would reach every child and the combined tooltip
                // would repeat it once per child.
                .help(KanbanColumns.help(lane.name) ?? "")
                .accessibilityAddTraits(.isHeader)
                if let onCollapse { IconButton(symbol: "chevron.left", label: "Fold the empty lane", action: onCollapse) }
            }
            .padding(.horizontal, DS.Space.s1)
            .frame(minHeight: onCollapse == nil ? nil : DS.Size.controlHeight)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s2) {
                        if groupByProfile {
                            ForEach(KanbanProfileFilter.groups(lane.tasks), id: \.name) { group in
                                KanbanLaneGroupHeader(name: group.name, count: group.tasks.count)
                                ForEach(group.tasks) { task in card(task).id(task.id) }
                            }
                        } else {
                            ForEach(lane.tasks) { task in card(task).id(task.id) }
                        }
                        if lane.tasks.isEmpty {
                            Text(filtering ? "No matches" : "Empty")
                                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                                .padding(DS.Space.s2)
                        }
                    }
                    .animation(motion ? DS.Motion.ease : nil, value: lane.tasks.map(\.id))
                }
                .scrollIndicators(.automatic)
                // The selected card scrolls into view inside its lane (the least distance).
                .onChange(of: model.selectedTaskId) { _, id in reveal(id, proxy) }
                .onAppear { reveal(model.selectedTaskId, proxy) }
            }
        }
        .padding(DS.Space.s2)
        .frame(width: DS.Kanban.laneWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(locked ? DS.Palette.dangerRing : DS.Palette.ring, lineWidth: DS.Stroke.focus)
            }
        }
    }

    private func reveal(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id, lane.tasks.contains(where: { $0.id == id }) else { return }
        withDSAnimation(motion, DS.Motion.ease) { proxy.scrollTo(id) }
    }

    private func card(_ task: KanbanTask) -> some View {
        KanbanCardView(task: task, now: now, selected: model.selectedTaskId == task.id, pending: model.isPending(task.id),
                       identity: task.assignee.map { avatars.identity(profile: $0) })
            .onTapGesture { onSelect(task) }
            .accessibilityAction { onOpen(task) }
            .draggable(task.id)
            .contextMenu {
                KanbanTaskMenu(task: task, model: model, laneNames: laneNames, onOpen: { onOpen(task) },
                               onArchive: { onArchive(task) }, openBotChat: botChat(task))
            }
            .transition(motion ? .opacity : .identity)
    }
}

// MARK: - card

struct KanbanCardView: View {
    let task: KanbanTask
    let now: Int
    let selected: Bool
    let pending: Bool
    let identity: BotIdentity?

    var body: some View {
        let flags = KanbanCardFlags(task, now: now)
        VStack(alignment: .leading, spacing: DS.Space.s1 + DS.Space.s0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(task.title.isEmpty ? task.id : task.title)
                    .font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink)
                    .lineLimit(DS.Kanban.titleLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if pending { ProgressView().controlSize(.mini) }
                if task.priority > 0 { KanbanPriorityTag(priority: task.priority) }
            }
            KanbanFlagsRow(flags: flags, progress: task.progress)
            HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                if let identity, let who = task.assignee {
                    AvatarView(identity: identity, size: DS.Size.avatarChip)
                    Text("@\(who)").lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(DS.Typeface.iconSmall)
                    Text("Unassigned")
                }
                Spacer(minLength: DS.Space.s1)
                if task.commentCount > 0 {
                    Label("\(task.commentCount)", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(task.commentCount) comments")
                }
                if let age = KanbanAge.of(task, now: now) { Text(age).monospacedDigit() }
            }
            .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
        .padding(DS.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(selected ? DS.Palette.ring : DS.Palette.hairline, lineWidth: selected ? DS.Stroke.focus : DS.Stroke.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        // After the combine, so the tooltip is the id once (on the stack it reached every child and the
        // combined tooltip read "t_1, t_1, t_1, …").
        .help(task.id)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct KanbanPriorityTag: View {
    let priority: Int
    var body: some View {
        Text("P\(priority)")
            .font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.ink)
            .padding(.horizontal, DS.Space.s1).padding(.vertical, DS.Space.s0 / 2)
            .background(DS.Palette.selected, in: RoundedRectangle(cornerRadius: DS.Radius.inline, style: .continuous))
            .accessibilityLabel("Priority \(priority)")
    }
}

/// Running / no heartbeat / blocked / needs input / won't run / failures, from the task fields only.
struct KanbanFlagsRow: View {
    let flags: KanbanCardFlags
    let progress: KanbanTask.Progress?

    var body: some View {
        let any = flags.running || flags.blocked || flags.wontRun || flags.failures > 0 || progress != nil
        if any {
            HStack(spacing: DS.Space.s2) {
                if flags.running {
                    if flags.stale {
                        tag("No heartbeat", symbol: "waveform.path.badge.minus", color: DS.Palette.attention)
                            .help("Claimed, but no worker heartbeat for 2+ minutes. The dispatcher will reclaim it.")
                    } else {
                        HStack(spacing: DS.Space.s1) {
                            StatusDot(color: DS.Palette.primary, live: true)
                            Text("Running")
                        }
                        .help("An agent is working on this now.")
                    }
                }
                if flags.blocked {
                    tag(flags.needsInput ? "Needs input" : "Blocked", symbol: "hand.raised.fill", color: DS.Palette.attention)
                }
                if flags.wontRun {
                    tag("Won't run", symbol: "person.fill.questionmark", color: DS.Palette.muted)
                        .help("Ready cards only run once a bot is assigned.")
                }
                if flags.failures > 0 {
                    tag(flags.failures == 1 ? "1 failed run" : "\(flags.failures) failed runs", symbol: "xmark.octagon",
                        color: DS.Palette.danger)
                }
                if let progress, progress.total > 0 {
                    Text("\(progress.done)/\(progress.total) subtasks")
                }
            }
            .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
    }

    private func tag(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon).foregroundStyle(color)
    }
}

// MARK: - actions menu (context menu and inspector)

/// Open, Move to ▸, Assign to ▸, Priority ▸, Open Bot Chat, AI actions (K6), Notify When Done or Blocked (K9),
/// Copy Task ID, Archive…
struct KanbanTaskMenu: View {
    let task: KanbanTask
    @ObservedObject var model: KanbanBoardModel
    let laneNames: [String]
    var onOpen: (() -> Void)?
    let onArchive: () -> Void
    var openBotChat: (() -> Void)?

    var body: some View {
        if let onOpen { Button("Open", action: onOpen) }
        KanbanMoveMenu(task: task, model: model, laneNames: laneNames)
        KanbanAssignMenu(task: task, model: model)
        KanbanPriorityMenu(task: task, model: model)
        if let who = task.assignee, let openBotChat { Button("Open Bot Chat with @\(who)", action: openBotChat) }
        Divider()
        KanbanAIMenuItems(task: task, ai: model.ai, onOpen: onOpen)
        Divider()
        if let watches = model.watches {
            KanbanWatchToggle(watches: watches, slug: model.slug, task: task) { on in
                watches.set(model.slug, task.id, watching: on)
            }
        }
        Button("Copy Task ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.id, forType: .string)
        }
        Divider()
        Button("Archive…", role: .destructive, action: onArchive)
    }
}

struct KanbanMoveMenu: View {
    let task: KanbanTask
    @ObservedObject var model: KanbanBoardModel
    let laneNames: [String]
    var title = "Move to"
    var body: some View {
        let targets = KanbanColumns.moveTargets(from: task.status, lanes: laneNames)
        Menu(title) {
            ForEach(targets, id: \.self) { lane in
                Button(KanbanColumns.label(lane)) { Task { await model.move(task.id, to: lane) } }
            }
        }
        .disabled(targets.isEmpty)
    }
}

struct KanbanAssignMenu: View {
    let task: KanbanTask
    @ObservedObject var model: KanbanBoardModel
    var title = "Assign to"
    var body: some View {
        Menu(title) {
            ForEach(model.assigneeNames, id: \.self) { name in
                Button { Task { await model.reassign(task.id, to: name) } } label: {
                    if task.assignee == name { Label("@\(name)", systemImage: "checkmark") } else { Text("@\(name)") }
                }
            }
            if task.assignee != nil {
                Divider()
                Button("Unassign") { Task { await model.reassign(task.id, to: nil) } }
            }
        }
    }
}

struct KanbanPriorityMenu: View {
    let task: KanbanTask
    @ObservedObject var model: KanbanBoardModel
    var title = "Priority"
    var body: some View {
        let options = Array(Set(KanbanBoardModel.defaultPriorities + [task.priority])).sorted(by: >)
        Menu(title) {
            ForEach(options, id: \.self) { p in
                Button { Task { await model.setPriority(task.id, p) } } label: {
                    let text = p == 0 ? "0 (normal)" : "\(p)"
                    if task.priority == p { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        }
    }
}

// MARK: - dispatcher chip (K8)

struct DispatcherChipView: View {
    @ObservedObject var model: DispatcherStatusModel
    @State private var showInfo = false

    var body: some View {
        let kind = DispatcherChip.kind(state: model.state, starting: model.starting)
        let attention = DispatcherChip.needsAttention(kind)
        HStack(spacing: DS.Space.s2) {
            if let result = model.startResult, model.startFailed {
                Text(result).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).lineLimit(1)
                    .truncationMode(.middle).help(result)
            }
            Button { showInfo.toggle() } label: {
                HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                    switch kind {
                    case .running: StatusDot(color: DS.Palette.primary)
                    case .starting, .checking: ProgressView().controlSize(.mini)
                    case .stopped, .notInstalled: Image(systemName: "pause.circle").font(DS.Typeface.iconSmall)
                    case .unknown: Image(systemName: "questionmark.circle").font(DS.Typeface.iconSmall)
                    }
                    Text(DispatcherChip.label(kind)).lineLimit(1)
                }
                .font(DS.Typeface.meta)
                .foregroundStyle(attention ? DS.Palette.attention : DS.Palette.muted)
                .padding(.horizontal, DS.Space.gutter).frame(minHeight: DS.Size.controlHeight)
                .background(attention ? DS.Palette.attentionSoft : DS.Palette.surface,
                            in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                .overlay {
                    if attention {
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.hairline)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(DispatcherChip.explanation)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { DispatcherInfo(model: model, kind: kind) }
            if kind == .stopped {
                Button("Start") { Task { await model.start() } }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .help("Run hermes gateway start")
            }
        }
    }
}

/// Popover: what the dispatcher does, and the install command when it is missing.
struct DispatcherInfo: View {
    @ObservedObject var model: DispatcherStatusModel
    let kind: DispatcherChip.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text(DispatcherChip.label(kind)).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
            Text(DispatcherChip.explanation).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch kind {
            case .notInstalled:
                Text("Install it once in Terminal; it then starts at login:").font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s2) {
                    Text(GatewayStatus.installCommand).font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: DS.Space.s2)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(GatewayStatus.installCommand, forType: .string)
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                .padding(.horizontal, DS.Space.gutter).padding(.vertical, DS.Space.s1)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            case .stopped:
                Button("Start Dispatcher") { Task { await model.start() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            case .unknown(let why):
                Text(why).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            case .running, .starting, .checking:
                EmptyView()
            }
            if let result = model.startResult {
                Text(result).font(DS.Typeface.meta).foregroundStyle(model.startFailed ? DS.Palette.danger : DS.Palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: DS.Size.popoverWidth, alignment: .leading)
    }
}
