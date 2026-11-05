import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - views
//
// Layout and tokens: DESIGN.md (Group Chat). Toolbar (room name, Stop, room menu) → turn ribbon →
// timeline (rows from `RoomPresentation`, action cards) → note bar → composer.
// Every action still goes through `RoomModel` (send gate, perform keys, disband), exactly as in M2.
// Room-level "working" has one home, the ribbon's room chip: the timeline does not repeat it.

struct RoomView: View {
    @ObservedObject var model: RoomModel
    @ObservedObject private var avatars = AvatarStore.shared
    @StateObject private var memory: RoomMotionMemory
    @State private var draft = ""
    @State private var confirmDisband = false
    @State private var dismissedNote: String?
    @FocusState private var composerFocused: Bool
    @Environment(\.motionEnabled) private var motion

    init(model: RoomModel) {
        self.model = model
        _memory = StateObject(wrappedValue: RoomMotionMemory.of(model.id))
    }

    private var rows: [RoomRow] { RoomPresentation.rows(lines: model.lines, events: model.timeline.events) }
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
                emptyRoom
            } else {
                timeline(rows, actions: actions)
            }
            noteBar
            composer
        }
        .background(DS.Palette.window)
        .navigationTitle(model.room.name)
        .navigationSubtitle("\(model.room.members.count) bots")
        .toolbar { toolbar }
        .onAppear { model.start() }
        .onDisappear { model.stopPolling() }
        .onChange(of: model.lastSync) { _, sync in
            if sync != nil { memory.setBaselineIfNeeded(model.timeline.cursor) }
        }
        .onChange(of: memberStates) { _, s in memory.observe(s) }
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
                Button("Disband Room…", role: .destructive) { confirmDisband = true }
            } label: { Label("Room", systemImage: "ellipsis.circle") }
                .help("Room actions")
                .disabled(!model.composer.isOpen)
        }
    }

    // MARK: timeline

    private func timeline(_ rows: [RoomRow], actions: [RoomPendingAction]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                            .transition(transition(for: row))
                    }
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

    @ViewBuilder private func rowView(_ row: RoomRow) -> some View {
        switch row.kind {
        case .user(let text):
            UserBubble(text: text, time: row.time, mentionHandles: Set(model.room.members.map(\.handle)))
        case .member(let memberId, let author, let text):
            MemberMessage(identity: identity(memberId, title: author), author: author, time: row.time) {
                MessageBody(text: text)
            }
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
                        draft: $draft,
                        canSend: model.composer.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onSend: send, focus: $composerFocused,
                        onTab: { MentionSuggestions.acceptFirst(&draft, members: model.room.members) })
                .overlay(alignment: .topLeading) {
                    MentionSuggestions(draft: $draft, members: model.room.members, identity: { identity($0.memberId, title: $0.title) })
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

    /// Clears the draft only when the model accepted it (a closing/disbanded room keeps it).
    private func send() {
        if model.send(draft) { draft = "" }
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
