import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - views
//
// Layout and tokens: DESIGN.md (Group Chat). Toolbar (room name, Stop, room menu) → turn ribbon →
// timeline (rows from `RoomPresentation`, action cards) → note bar → composer. The inspector column shows
// the open thread (RoomThreadViews.swift) or, otherwise, the Activity panel. Drafts live in `RoomModel`
// (per thread), so they survive switching panes.
// Every action still goes through `RoomModel` (send gate, perform keys, disband), exactly as in M2.
// Room-level "working" has one home, the ribbon's room chip: the timeline does not repeat it.

struct RoomView: View {
    @ObservedObject var model: RoomModel
    /// The room's Activity panel model (nil without a backend: the panel then shows turn status only).
    var activity: RoomActivityModel? = nil
    @ObservedObject private var avatars = AvatarStore.shared
    @StateObject private var memory: RoomMotionMemory
    @State private var confirmDisband = false
    @State private var showRename = false
    /// Change Members… (C2.2): the sheet, and the flow it shows (a fresh one per opening).
    @State private var showMembers = false
    @State private var memberChange: RoomMemberChange?
    @State private var dismissedNote: String?
    @FocusState private var composerFocused: Bool
    @State private var paste = AttachmentPasteMonitor()
    @State private var dropTargeted = false
    /// Persisted Activity panel visibility, bound through a @State copy as in BotChatView (an @AppStorage
    /// write reaches the view outside the toggle's transaction, so the no-animation path still slid it).
    @AppStorage("hba.roomActivity") private var storedActivity = false
    @State private var showActivity = UserDefaults.standard.object(forKey: "hba.roomActivity") as? Bool ?? false
    @Environment(\.motionEnabled) private var motion

    init(model: RoomModel, activity: RoomActivityModel? = nil) {
        self.model = model
        self.activity = activity
        _memory = StateObject(wrappedValue: RoomMotionMemory.of(model.id))
    }

    private var rows: [RoomRow] { RoomPresentation.rows(lines: model.lines, events: model.timeline.events) }

    /// The inspector column holds the open thread, else the Activity panel when that is on.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { showActivity || model.openThread != nil },
                set: { shown in if !shown { showActivity = false; model.openThread = nil } })
    }

    /// Column changes animate with the system inspector slide only while motion is on.
    private func inspectorChange(_ change: () -> Void) {
        if motion { change() } else { withDSAnimation(false) { change() } }
    }
    private var memberStates: [String: RoomPresentation.MemberState] {
        RoomPresentation.memberStates(room: model.room, timeline: model.timeline, driver: model.driver)
    }

    var body: some View {
        let rows = self.rows
        let actions = model.driver?.pendingActions ?? []
        VStack(spacing: 0) {
            TurnRibbon(model: model, states: memberStates, memory: memory)
            Hairline()
            if rows.isEmpty && actions.isEmpty && !model.active {
                switch Self.emptyKind(synced: model.lastSync != nil, syncFailed: model.notes.contains { RoomNote($0).failed }) {
                case .loading: loadingRoom
                case .empty: emptyRoom
                }
            } else {
                timeline(rows, actions: actions)
            }
            noteBar
            composer
        }
        // As in BotChatView: no intrinsic minimum, so the Activity inspector split never widens past the
        // window at the 820 pt minimum (InspectorLayoutTests).
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(DS.Palette.window)
        .overlay { if dropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard model.composer.isOpen, !files.isEmpty else { return false }
            model.addAttachments(files)
            return true
        } isTargeted: { dropTargeted = $0 && model.composer.isOpen }
        .onChange(of: composerFocused) { _, f in paste.focused = f }
        .onChange(of: model.focusRequest) { _, r in if r?.thread == RoomThreads.main { composerFocused = true } }
        .onDisappear { paste.remove() }
        .navigationTitle(model.room.name)
        .navigationSubtitle("\(model.room.members.count) bots")
        .toolbar { toolbar }
        .inspector(isPresented: inspectorShown) {
            Group {
                if let thread = model.openThread {
                    RoomThreadPane(model: model, thread: thread, row: { rowView($0, inThreadPane: true) },
                                   identity: { identity($0.memberId, title: $0.title) })
                } else {
                    RoomActivityPanel(room: model, activity: activity)
                }
            }
            .inspectorColumnWidth(min: DS.Size.inspectorMin, ideal: DS.Size.inspectorWidth, max: DS.Size.inspectorMax)
        }
        .onChange(of: showActivity) { _, shown in storedActivity = shown }
        .onAppear {
            model.start()
            let model = model
            paste.install(canAttach: { model.composer.isOpen }, attach: { model.addAttachments($0) })
        }
        .onDisappear { model.stopPolling() }
        .onChange(of: model.lastSync) { _, sync in
            if sync != nil { memory.setBaselineIfNeeded(model.timeline.cursor) }
        }
        .onChange(of: memberStates) { _, s in memory.observe(s) }
        .motionSheet(isPresented: $showRename, motion: motion) {
            RenameRoomView(current: model.room.name, onRename: { model.rename($0) }, onClose: { showRename = false })
        }
        .motionSheet(isPresented: $showMembers, motion: motion) {
            // The flow outlives the binding, so the sheet keeps its content while it slides out.
            if let memberChange {
                ChangeMembersSheet(change: memberChange, bots: AppModel.shared.bots, onClose: { showMembers = false })
            }
        }
        .confirmationDialog("Disband \(model.room.name)?", isPresented: $confirmDisband) {
            Button("Disband", role: .destructive) { Task { _ = await model.disband() } }
        } message: { Text("The room id is retired for good. This cannot be undone.") }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            RoomAvatarStack(identities: model.room.members.map { identity($0.memberId) })
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.circle") }
                .labelStyle(.titleAndIcon)
                .help("Stop the running turns in this room")
                .disabled(!model.active || model.busyActions.contains("stop") || !model.composer.isOpen)
            Menu {
                Button("Rename…") { showRename = true }
                    .disabled(model.busyActions.contains("rename"))
                // Needs the loaded log: the new room gets this room's recent messages as context.
                Button("Change Members…") {
                    memberChange = AppModel.shared.memberChange(for: model)
                    showMembers = true
                }
                    .disabled(model.lastSync == nil)
                Divider()
                Button("Disband Room…", role: .destructive) { confirmDisband = true }
            } label: { Label("Room", systemImage: "ellipsis.circle") }
                .help("Room actions")
                .disabled(!model.composer.isOpen)
        }
        ToolbarItem(placement: .primaryAction) {
            // ⌥⌘I as in Bot Chat: the two panes are never on screen together. System inspector animation with
            // motion on; a no-animation transaction with it off.
            Button {
                inspectorChange {
                    // A thread in the column: Activity takes it over (closing the thread), rather than hiding it.
                    if model.openThread != nil { model.openThread = nil; showActivity = true } else { showActivity.toggle() }
                }
            } label: { Label("Activity", systemImage: "sidebar.trailing") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide what each bot is doing (⌥⌘I)")
        }
    }

    // MARK: timeline

    private func timeline(_ rows: [RoomRow], actions: [RoomPendingAction]) -> some View {
        let threads = Dictionary(model.timeline.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func timelineRow(_ row: RoomRow) -> some View { self.timelineRow(row, threads: threads) }
        return ScrollViewReader { proxy in
            ScrollView {
                // Older rows lazy, the rows seen on open laid out eagerly (EagerTail: why not all of one kind).
                let tail = EagerTail.start(of: rows) { $0.approximateLines }
                VStack(alignment: .leading, spacing: DS.Space.timeline) {
                    LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                        ForEach(rows[..<tail]) { row in timelineRow(row) }
                    }
                    ForEach(rows[tail...]) { row in timelineRow(row) }
                    ForEach(actions) { action in
                        ActionCard(model: model, action: action, memory: memory, identity: identity)
                            .id(action.id)
                            .transition(motion ? .arrive(from: .bottomLeading) : .identity)
                    }
                }
                .padding(.horizontal, DS.Space.s5).padding(.top, DS.Space.s4).padding(.bottom, DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion && memory.baseline != nil ? DS.Motion.spring : nil, value: rows.map(\.id))
                .animation(motion && memory.baseline != nil ? DS.Motion.spring : nil, value: rows.last.map(passCount))
                .animation(motion ? DS.Motion.ease : nil, value: actions.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.timeline.cursor) { _, _ in
                guard let id = model.lines.last?.id else { return }
                withDSAnimation(motion, DS.Motion.ease) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: actions.map(\.id)) { _, ids in
                guard let id = ids.last else { return }
                withDSAnimation(motion, DS.Motion.ease) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// A timeline row plus its thread links: the label above a message in another thread, the reply count
    /// under a message a thread hangs off.
    private func timelineRow(_ row: RoomRow, threads: [String: RoomThreadSummary]) -> some View {
        let isUser: Bool = { if case .user = row.kind { return true }; return false }()
        let anchored = threads[RoomThreads.anchored(at: row.id)]
        return VStack(alignment: isUser ? .trailing : .leading, spacing: DS.Space.s1) {
            if row.isMessage && row.threadId != RoomThreads.main {
                RoomThreadLink(style: .label, text: RoomPresentation.threadTitle(threads[row.threadId])) { open(row.threadId) }
                    .padding(.leading, isUser ? 0 : DS.Size.contentInset)
            }
            rowView(row)
            if row.isMessage, row.threadId == RoomThreads.main, let anchored {
                RoomThreadLink(style: .replies, text: RoomPresentation.replyCount(anchored.messageCount)) { open(anchored.id) }
                    .padding(.leading, isUser ? 0 : DS.Size.contentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .id(row.id)
        .transition(transition(for: row))
    }

    private func open(_ thread: String) {
        inspectorChange { model.showThread(thread) }
    }

    private func passCount(_ row: RoomRow) -> Int {
        if case .passes(let p) = row.kind { return p.count }
        return 0
    }

    /// Only rows after the baseline (first data this room showed) animate in; history never does.
    private func transition(for row: RoomRow) -> AnyTransition {
        guard motion, memory.isNew(row.id) else { return .identity }
        switch row.kind {
        case .user: return .arrive(from: .bottomTrailing)
        case .divider: return .drawFromCentre
        default: return .arrive(from: .bottomLeading)
        }
    }

    /// One row. Messages carry their actions (hover strip + context menu): Reply to @bot, Reply in thread
    /// (not inside the thread pane, whose composer already posts to the thread) and Copy.
    @ViewBuilder func rowView(_ row: RoomRow, inThreadPane: Bool = false) -> some View {
        switch row.kind {
        case .user(let text):
            let parts = RoomAttachments.split(text)
            let roomId = model.room.roomId
            UserBubble(text: parts.text, time: row.time, mentionHandles: Set(model.room.members.map(\.handle)),
                       attachments: RoomAttachments.mediaRefs(parts.paths),
                       autoResolve: { RoomAttachmentStore.contains($0.path, room: roomId) })
                .messageActions(messageActions(row, memberId: nil, inThreadPane: inThreadPane), alignment: .topTrailing)
        case .member(let memberId, let author, let text):
            MemberMessage(identity: identity(memberId, title: author), author: author, time: row.time) {
                MessageBody(text: text, mentions: Set(model.room.members.map(\.handle))).equatable()
            }
            .messageActions(messageActions(row, memberId: memberId, inThreadPane: inThreadPane), alignment: .topTrailing)
        case .passes(let passes):
            PassLine(passes: passes, memory: memory, identity: { identity($0.memberId, title: $0.author) })
        case .divider(let text):
            RoundDivider(text: text)
        case .status(let memberId, let author, let text):
            StatusLine(identity: memberId.map { identity($0, title: author) }, text: "\(author) · \(text)")
        case .failure(let memberId, let author, let text):
            FailureCard(identity: identity(memberId, title: author), author: author, text: text)
        }
    }

    private func messageActions(_ row: RoomRow, memberId: String?, inThreadPane: Bool) -> RoomMessageActions {
        let seq = row.id, model = model
        return RoomMessageActions(
            replyHandle: model.room.member(memberId)?.handle,
            onReply: { inspectorChange { model.replyToMember(seq: seq) } },
            onReplyInThread: inThreadPane || !model.composer.isOpen ? nil : { inspectorChange { model.replyInThread(seq: seq) } },
            copyText: RoomPresentation.copyText(row),
            onCreateTask: RoomPresentation.copyText(row).map { text in
                let seed = KanbanTaskSeed.room(text: text, member: model.room.member(memberId), roomName: model.room.name)
                return { AppModel.shared.composeTask(from: seed) }
            })
    }

    enum EmptyKind: Equatable { case loading, empty }

    /// A room with no rows yet is loading until its first sync lands (or fails: the note bar then says why),
    /// not "No messages yet": opening a busy room flashed the empty state before its history.
    nonisolated static func emptyKind(synced: Bool, syncFailed: Bool) -> EmptyKind {
        synced || syncFailed ? .empty : .loading
    }

    private var loadingRoom: some View {
        EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "Opening \(model.room.name)",
                       message: "Loading the conversation from Hermes.") {
            ProgressView().controlSize(.small).accessibilityLabel("Loading")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Centred in the pane (not pinned to the composer by the bottom-anchored scroll view).
    private var emptyRoom: some View {
        EmptyStateView(symbol: "bubble.left.and.bubble.right",
                       title: "No messages yet",
                       message: "Write to everyone, or start with @handle to ask one bot. Bots answer in turns.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The model's latest note in plain words (`RoomNote`). Failures stay until the next note; a
    /// success note can be dismissed.
    @ViewBuilder private var noteBar: some View {
        if let raw = model.notes.last, dismissedNote != "\(model.notes.count)|\(raw)" {
            let note = RoomNote(raw)
            HStack(spacing: DS.Space.s2) {
                Image(systemName: note.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(DS.Typeface.iconSmall)
                Text(note.text).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: DS.Space.s2)
                if !note.failed {
                    IconButton(symbol: "xmark", label: "Dismiss") { dismissedNote = "\(model.notes.count)|\(raw)" }
                }
            }
            .font(DS.Typeface.meta)
            .foregroundStyle(note.failed ? DS.Palette.danger : DS.Palette.muted)
            .padding(.leading, DS.Space.s5).padding(.trailing, DS.Space.s4)
            .frame(minHeight: DS.Size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(raw)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ComposerBox(placeholder: "Message \(model.room.name). Start with @handle to address one bot",
                        draft: mainDraft,
                        canSend: canSend,
                        onSend: send, focus: $composerFocused,
                        onTab: { MentionSuggestions.acceptFirst(&mainDraft.wrappedValue, members: model.room.members) },
                        onAttach: attachAction,
                        attachments: model.pending,
                        onRemoveAttachment: { model.removeAttachment($0) })
                .overlay(alignment: .topLeading) {
                    MentionSuggestions(draft: mainDraft, members: model.room.members, identity: { identity($0.memberId, title: $0.title) })
                        .alignmentGuide(.top) { $0[.bottom] + DS.Space.s1 }
                }
            HStack(spacing: DS.Space.s3) {
                KeyHint(keys: "Return", label: "send")
                KeyHint(keys: "@", label: "mention")
                Spacer()
                footer
            }
        }
        .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
    }

    /// Sync footer: when the room last updated and how often it checks (rooms are polled, not pushed).
    private var footer: some View {
        let sync = model.lastSync.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "not yet"
        let every = model.pollInterval == 0 ? "now" : String(format: "every %.0fs", model.pollInterval)
        return Text("Synced \(sync) · \(every) · seq \(model.timeline.cursor)")
            .font(DS.Typeface.caption.monospacedDigit()).foregroundStyle(DS.Palette.muted)
            .lineLimit(1)
            .help("Group chats update by polling groups.log and groups.state.")
    }

    /// The paperclip, while the room accepts messages.
    private var attachAction: (() -> Void)? {
        guard model.composer.isOpen else { return nil }
        return { pickFiles() }
    }

    /// The room composer's draft (`main`), kept by the model.
    private var mainDraft: Binding<String> {
        Binding(get: { model.draft(RoomThreads.main) }, set: { model.setDraft($0, thread: RoomThreads.main) })
    }

    /// Text, or at least one ready attachment, and the room accepts messages.
    private var canSend: Bool {
        guard model.composer.canSend else { return false }
        let hasText = !model.draft(RoomThreads.main).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || model.pending.contains(where: \.isReady)
    }

    /// The model clears the draft only when it accepted it (a closing/disbanded room keeps it).
    private func send() {
        model.submit(thread: RoomThreads.main)
    }

    private func pickFiles() {
        let model = model
        pickAttachments(message: "Attach files for the bots in \(model.room.name). They get a copy they can open.") {
            model.addAttachments($0)
        }
    }

    // MARK: identity

    private func identity(_ memberId: String?) -> BotIdentity {
        identity(memberId, title: nil)
    }

    private func identity(_ memberId: String?, title: String?) -> BotIdentity {
        let m = model.room.member(memberId)
        return avatars.identity(profile: m?.profile ?? memberId ?? "bot", title: title ?? m?.title)
    }
}
