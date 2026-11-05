import AppKit
import HermesGatewayKit
import SwiftUI

// M2 Group Chat UI. Rooms have no WS push (docs/gateway-contract.md §7): `RoomModel` polls
// `groups.log {since_seq}` + `groups.state` through `RoomPoller` (HermesGatewayKit) at
// `RoomPollPolicy` cadence (1 s while anything can change, 5 s idle) and nudges it right after every
// action it sends. `RoomPoller` drops results of a stopped/restarted loop, so view
// disappear/appear cannot roll the timeline back.

enum SidebarItem: Hashable {
    case bot(String)
    case room(String)
}

@MainActor
final class RoomModel: ObservableObject, Identifiable {
    nonisolated let id: String
    @Published private(set) var room: RoomSummary
    @Published private(set) var timeline = RoomTimeline()
    @Published private(set) var driver: RoomDriverStatus?
    @Published private(set) var composer = RoomComposer()
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var busyActions: Set<String> = []
    let api: GroupsAPI
    /// Evidence hook: every applied sync (new events since the previous one).
    var onSync: ((RoomModel, [RoomEvent]) -> Void)?
    /// The room was disbanded (here) or found retired: the app drops it from the sidebar.
    var onDisbanded: ((RoomModel) -> Void)?
    private let poller: RoomPoller
    /// The room view is on screen (start/stopPolling); a failed disband resumes polling only then.
    private var wantsPolling = false
    /// App shutdown: polling never restarts.
    private var shutDown = false
    private(set) var pollCount = 0

    init(room: RoomSummary, api: GroupsAPI) {
        id = room.roomId; self.room = room; self.api = api
        poller = RoomPoller(source: api, roomId: room.roomId)
        poller.onUpdate = { [weak self] u in self?.apply(u) }
        poller.onError = { [weak self] e in self?.syncFailed(e) }
    }

    var disbanded: Bool { composer.availability == .closed }
    var lines: [RoomLine] { timeline.lines(room: room) }
    var pollInterval: TimeInterval { RoomPollPolicy.interval(driver: driver, timeline: timeline) }
    /// Something is still happening: a task is queued/running/stopping or the latest message is unsettled.
    var active: Bool { RoomPollPolicy.busy(driver: driver, timeline: timeline) }
    var pollGeneration: Int { poller.generation }
    var droppedStaleSyncs: Int { poller.droppedStale }

    // MARK: polling

    func start() {
        wantsPolling = true
        guard !shutDown, composer.isOpen else { return }
        poller.start()
    }

    func stopPolling() {
        wantsPolling = false
        poller.stop()
    }

    /// App quit: stop for good (a later failed disband must not restart polling).
    func shutdown() {
        shutDown = true
        stopPolling()
    }

    /// Ends the current wait so the next sync runs now (after a send/stop/retry/approve).
    func nudge() { poller.nudge() }

    private func apply(_ u: RoomPoller.Update) {
        timeline = u.timeline; driver = u.state.driver; room = u.state.room; lastSync = Date(); pollCount += 1
        onSync?(self, u.newEvents)
    }

    private func syncFailed(_ error: Error) {
        note("sync failed: \(Redaction.describe(error))")
        switch Self.syncFailure(error) {
        case .roomGone: markDisbanded()
        case .connectionLost: poller.stop()  // the socket is gone: polling again cannot succeed
        case .transient: break
        }
    }

    enum SyncFailure: Equatable { case roomGone, connectionLost, transient }

    /// Room-not-found is RPC code 4114 (docs/groups-contract.md); only that marks a room disbanded,
    /// never a message text. A closed or failed socket ends polling; anything else (timeout, another
    /// RPC error) is retried on the next poll.
    nonisolated static func syncFailure(_ error: Error) -> SyncFailure {
        switch error {
        case let e as GatewayClient.RPCError: return e.code == 4114 ? .roomGone : .transient
        case GatewayClient.ClientError.closed, GatewayClient.ClientError.transport, GatewayClient.ClientError.notConnected:
            return .connectionLost
        default: return .transient
        }
    }

    private func markDisbanded() {
        guard !disbanded else { return }
        composer.close()
        poller.stop()
        onDisbanded?(self)
    }

    private func note(_ s: String) {
        notes.append(s)
        if notes.count > 20 { notes.removeFirst(notes.count - 20) }
        AppModel.shared.log("room \(room.roomId): \(s)")
    }

    // MARK: actions

    /// Same gate shape as Bot Chat: true only when accepted (the view clears its draft then). Refused
    /// (draft kept, nothing sent) while a send is in flight or once the room is closing/disbanded —
    /// whichever path called it (Return, button, script).
    func send(_ draft: String) -> Bool {
        guard let text = composer.beginSend(draft) else { return false }
        let eventId = "hba-msg-\(UUID().uuidString.lowercased())"
        Task {
            do {
                let e = try await api.sendMessage(roomId: room.roomId, eventId: eventId, text: text, threadId: "main")
                AppModel.shared.log("groups.send → seq=\(e.seq) (ACK only; replies arrive through polling)")
            } catch {
                note("send failed, message not posted: \(Redaction.describe(error))")
            }
            composer.finishSend()
            nudge()
        }
        return true
    }

    func stop() {
        perform("stop") { api in
            let n = try await api.stopRoom(roomId: self.room.roomId)
            return "groups.stop → cancelled \(n) task(s)"
        }
    }

    func retry(_ taskId: String) {
        perform("retry:\(taskId)") { api in
            let r = try await api.retry(roomId: self.room.roomId, taskId: taskId)
            return "groups.retry → \(r["task"]?["status"]?.string ?? "?")"
        }
    }

    func approve(_ a: RoomApproval, choice: String) {
        perform("approval:\(a.requestId)") { api in
            _ = try await api.approve(roomId: self.room.roomId, approval: a, choice: choice)
            return "groups.approve \(choice) → resolved"
        }
    }

    /// `groups.disband`. While it is in flight the room takes no send/stop/retry/approve; on success it
    /// is closed for good and dropped from the sidebar, on failure it reopens (and resumes polling if
    /// the view is still shown).
    func disband() async -> Bool {
        guard composer.beginClosing() else { return disbanded }
        poller.stop()
        do {
            _ = try await api.disbandRoom(roomId: room.roomId)
            note("disbanded")
            markDisbanded()
            return true
        } catch {
            note("disband failed: \(Redaction.describe(error))")
            composer.reopen()
            if wantsPolling && !shutDown { poller.start() }
            return false
        }
    }

    private func perform(_ key: String, _ op: @escaping @MainActor (GroupsAPI) async throws -> String) {
        guard composer.isOpen, !busyActions.contains(key) else { return }
        busyActions.insert(key)
        Task {
            do { note(try await op(api)) } catch {
                let msg = Redaction.describe(error)
                // 5118 on Retry: another backend process holds this room's lease, and only it can retry
                // (docs/gateway-contract.md §7.6).
                note("\(key) failed: \(msg)" + (msg.contains("5118") ? " — another Hermes process runs this room; retry it there" : ""))
            }
            busyActions.remove(key)
            nudge()
        }
    }
}

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

// MARK: - ribbon

/// The turn ribbon (DESIGN.md motif): room status chip, then one chip per member with its real state.
struct TurnRibbon: View {
    @ObservedObject var model: RoomModel
    let states: [String: RoomPresentation.MemberState]
    @ObservedObject var memory: RoomMotionMemory
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s2) {
                RoomStatusChip(status: RoomPresentation.roomStatus(model))
                ForEach(model.room.members) { m in
                    MemberChip(identity: avatars.identity(profile: m.profile, title: m.title), title: m.title,
                               state: states[m.memberId] ?? .idle, bump: memory.bumps[m.memberId] ?? 0)
                }
            }
            .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.gutter)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn status")
    }
}

/// The room-level chip: the single place that says the room is working.
struct RoomStatusChip: View {
    let status: RoomPresentation.RoomStatus
    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch status.tone {
            case .working: WorkingDots(color: DS.Palette.ink)
            case .blocked: Image(systemName: "exclamationmark.octagon.fill").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.danger)
            case .quiet: StatusDot(color: DS.Palette.muted)
            }
            Text(status.text)
                .font(DS.Typeface.meta.weight(.medium))
                .foregroundStyle(status.tone == .blocked ? DS.Palette.danger : DS.Palette.ink)
                .contentTransition(.identity)
        }
        .padding(.horizontal, DS.Space.gutter).frame(height: DS.Size.controlHeight)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(status.tone == .blocked ? DS.Palette.dangerRing : .clear, lineWidth: DS.Stroke.ring))
        // No width animation: a label that changes length mid-animation truncates ("Working · 1 q…").
        // The text swaps at once; the dots carry the motion.
        .accessibilityElement(children: .combine)
    }
}

/// `status-chip`. Bounces once when `bump` changes (a real state change after the baseline).
/// `needs approval` / `needs retry` use the `attention` role (fill, ring, label and a symbol), so the one
/// state that waits on the user is never confused with `waiting` (a bot-colour hairline only).
struct MemberChip: View {
    let identity: BotIdentity
    let title: String
    let state: RoomPresentation.MemberState
    let bump: Int
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            AvatarView(identity: identity, size: DS.Size.avatarChip)
            Text(title).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
            HStack(spacing: DS.Space.s1) {
                if let symbol { Image(systemName: symbol).font(DS.Typeface.iconSmall) }
                Text(state.label).font(state.needsUser ? DS.Typeface.metaStrong : DS.Typeface.meta)
            }
            .foregroundStyle(labelColor)
            .contentTransition(.identity)
        }
        .padding(.leading, DS.Space.s1).padding(.trailing, DS.Space.gutter).frame(height: DS.Size.controlHeight)
        .background(state.needsUser ? DS.Palette.attentionSoft : DS.Palette.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(border, lineWidth: DS.Stroke.ring))
        .keyframeAnimator(initialValue: CGFloat(1), trigger: bump) { [motion] content, scale in
            content.scaleEffect(motion ? scale : 1)
        } keyframes: { _ in
            SpringKeyframe(DS.Motion.chipBounce, duration: 0.17)
            SpringKeyframe(1.0, duration: 0.25)
        }
        // The bounce is the state-change motion; label and width swap at once (see RoomStatusChip).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state.label)")
    }

    private var symbol: String? {
        switch state {
        case .needsApproval: return "hand.raised.fill"
        case .deferred: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle.fill"
        case .replied: return "checkmark"
        default: return nil
        }
    }

    private var labelColor: Color {
        switch state {
        case .needsApproval, .deferred: return DS.Palette.attention
        case .failed: return DS.Palette.danger
        case .replied: return DS.Palette.ink
        default: return DS.Palette.muted
        }
    }

    private var border: Color {
        switch state {
        case .needsApproval, .deferred: return DS.Palette.attentionRing
        case .waiting: return identity.color.opacity(DS.Palette.waitingBorder)
        case .failed: return DS.Palette.dangerRing
        default: return .clear
        }
    }
}

// MARK: - rows

struct UserBubble: View {
    let text: String
    let time: Double
    var mentionHandles: Set<String> = []

    var body: some View {
        HStack {
            Spacer(minLength: DS.Size.userBubbleInset)
            VStack(alignment: .trailing, spacing: DS.Space.s0) {
                Text(Self.mentions(text, handles: mentionHandles))
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.proseLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if time > 0 { TimeLabel(time: time) }
            }
            .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
            .background(DS.Palette.primarySoft, in: UnevenRoundedRectangle(
                topLeadingRadius: DS.Radius.bubble, bottomLeadingRadius: DS.Radius.bubble,
                bottomTrailingRadius: DS.Radius.inline, topTrailingRadius: DS.Radius.bubble, style: .continuous))
            .frame(maxWidth: DS.Size.userWidth, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }

    /// @mentions of real members (and @all/@everyone) in bold ink: graphite is the accent.
    static func mentions(_ text: String, handles: Set<String>) -> AttributedString {
        var a = AttributedString(text)
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w@])@([A-Za-z0-9][A-Za-z0-9._:-]*)") else { return a }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let h = ns.substring(with: m.range(at: 1))
            guard handles.contains(h) || ["all", "everyone"].contains(h.lowercased()),
                  let r = Range(m.range, in: text), let ar = Range(r, in: a) else { continue }
            a[ar].font = DS.Typeface.bodyStrong
        }
        return a
    }
}

struct MemberMessage<Content: View>: View {
    let identity: BotIdentity
    let author: String
    let time: Double
    var trailingNote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.gutter) {
            AvatarView(identity: identity, size: DS.Size.avatarMessage)
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(author).font(DS.Typeface.bodyStrong).foregroundStyle(identity.nameColor)
                    if let trailingNote { Text(trailingNote).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted) }
                    if time > 0 { TimeLabel(time: time) }
                }
                content
            }
            .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TimeLabel: View {
    let time: Double
    var body: some View {
        Text(Date(timeIntervalSince1970: time), format: .dateTime.hour().minute())
            .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
    }
}

/// Passes folded into one thin row, starting at the message content edge (`contentInset`); each avatar
/// pops in when its pass arrives live.
struct PassLine: View {
    let passes: [RoomRow.Pass]
    @ObservedObject var memory: RoomMotionMemory
    let identity: (RoomRow.Pass) -> BotIdentity
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s0) {
                ForEach(passes) { p in
                    AvatarView(identity: identity(p), size: DS.Size.avatarPass)
                        .transition(motion && memory.isNew(p.seq) ? .scale(scale: 0.4).combined(with: .opacity) : .identity)
                }
            }
            Text(RoomPresentation.passText(passes))
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .contentTransition(.identity)
        }
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}

struct StatusLine: View {
    let identity: BotIdentity?
    let text: String
    var body: some View {
        HStack(spacing: DS.Space.s2) {
            if let identity { AvatarView(identity: identity, size: DS.Size.avatarPass) }
            Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
        }
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}

/// `action-card-failure` for a failed turn.
struct FailureCard: View {
    let identity: BotIdentity
    let author: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.gutter) {
            Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.icon).foregroundStyle(DS.Palette.danger)
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text("\(author): turn failed").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
        .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
        .background(DS.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.dangerRing, lineWidth: DS.Stroke.ring))
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - action cards

/// `action-card`: a pending approval or retry from `groups.state`, drawn in the `attention` role (it
/// waits on the user). Buttons keep the M2 gating (`busyActions` key + room open) and call the same
/// `RoomModel` actions.
///
/// The card names the member, the reason (`description`) and the exact command. The approval payload
/// carries no tool name (`hosted_room_driver.py` `_report_pending_action` forwards `command`,
/// `description`, `pattern_key(s)`, `choices`, `request_id`; `tools/approval.py` builds it), so the
/// command block is labelled by what the payload holds instead of guessing a tool.
/// The command is drawn with `Text` in SF Mono, which never substitutes characters: an ASCII `-` stays
/// U+002D (SF Mono draws it wide; it is not an en dash).
struct ActionCard: View {
    @ObservedObject var model: RoomModel
    let action: RoomPendingAction
    @ObservedObject var memory: RoomMotionMemory
    let identity: (String?) -> BotIdentity
    @Environment(\.motionEnabled) private var motion
    /// When this card's one ripple started; nil when there is none (already played, or motion off).
    @State private var rippleStart: Date?

    var body: some View {
        card
            .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
            .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
            .background(DS.Palette.attentionSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.ring))
            .dsShadow(DS.Elevation.card)
            .background {
                // One ring ripple per approval request id (RoomMotionMemory), never on reopen. Drawn from
                // the clock on every frame instead of a scheduled `withAnimation`, so it is gone in the
                // same frame the motion gate closes, including during its start delay.
                if let start = rippleStart {
                    TimelineView(.animation(paused: !motion)) { context in
                        if let p = ApprovalRipple.progress(at: context.date, start: start, motion: motion) {
                            RoundedRectangle(cornerRadius: DS.Radius.card + p * DS.Motion.ringGrow, style: .continuous)
                                .stroke(DS.Palette.attention.opacity(Double(1 - p) * DS.Motion.ringOpacity), lineWidth: DS.Stroke.ring)
                                .padding(-p * DS.Motion.ringGrow)
                        }
                    }
                }
            }
            .padding(.leading, DS.Size.contentInset)
            .onAppear {
                guard case .approval(let a) = action, memory.shouldRing(a.requestId), motion else { return }
                rippleStart = Date()
            }
            // Motion off cancels the ripple for good: turning motion back on does not replay it.
            .onChange(of: motion) { _, on in if !on { rippleStart = nil } }
            .task(id: rippleStart) {
                guard rippleStart != nil else { return }
                try? await Task.sleep(for: .seconds(ApprovalRipple.total))
                if !Task.isCancelled { rippleStart = nil }
            }
    }

    @ViewBuilder private var card: some View {
        switch action {
        case .approval(let a):
            let who = model.room.member(a.memberId)?.title ?? a.memberId
            let busy = model.busyActions.contains("approval:\(a.requestId)") || !model.composer.isOpen
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "hand.raised.fill").font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention)
                    AvatarView(identity: identity(a.memberId), size: DS.Size.avatarChip)
                    Text("\(who) needs your approval").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                }
                if let d = a.description, !d.isEmpty {
                    Text("Flagged: \(d)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                }
                if let c = a.command {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("Command").font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                        CodeBlock(text: c)
                    }
                }
                HStack(spacing: DS.Space.s2) {
                    if a.choices.contains("once") {
                        Button("Approve once") { model.approve(a, choice: "once") }
                            .buttonStyle(DSButtonStyle(kind: .primary)).disabled(busy)
                    }
                    if a.choices.contains("deny") {
                        Button("Deny", role: .destructive) { model.approve(a, choice: "deny") }
                            .buttonStyle(DSButtonStyle(kind: .danger)).disabled(busy)
                    }
                    if busy && model.composer.isOpen { ProgressView().controlSize(.small) }
                }
                .padding(.top, DS.Space.s1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(who) needs your approval")
        case .retry(let taskId):
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "arrow.clockwise").font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention)
                    Text("A bot turn needs a retry").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                }
                // `indeterminate` (its process died mid-turn) or `deferred` (gave up after that): the
                // backend never re-runs it on its own because it may have had side effects.
                Text("The turn ended without a confirmed result. Retry runs it again, so its side effects may repeat.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { model.retry(taskId) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(model.busyActions.contains("retry:\(taskId)") || !model.composer.isOpen)
                    .padding(.top, DS.Space.s1)
            }
        case .other(let kind):
            Text("Pending: \(kind)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
        }
    }
}

// MARK: - mentions

/// Suggestions while the draft ends in `@prefix`: room members whose handle or name starts with it.
/// Click (or Tab for the first match) replaces the prefix with `@handle `. Only edits the draft.
struct MentionSuggestions: View {
    @Binding var draft: String
    let members: [RoomMember]
    let identity: (RoomMember) -> BotIdentity
    @Environment(\.motionEnabled) private var motion

    private var matches: [RoomMember] { Self.matches(draft, members: members) }

    static func matches(_ draft: String, members: [RoomMember]) -> [RoomMember] {
        guard let r = draft.range(of: "(?:^|\\s)@([A-Za-z0-9._:-]*)$", options: .regularExpression) else { return [] }
        let q = String(draft[r].drop(while: { $0 != "@" }).dropFirst()).lowercased()
        return members.filter { q.isEmpty || $0.handle.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q) }
    }

    /// Tab in the composer: accept the first (highlighted) match. False when no suggestion is showing.
    static func acceptFirst(_ draft: inout String, members: [RoomMember]) -> Bool {
        guard let m = matches(draft, members: members).first else { return false }
        insert(m, into: &draft)
        return true
    }

    var body: some View {
        let list = matches
        VStack(alignment: .leading, spacing: 0) {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        Button { insert(m) } label: {
                            HStack(spacing: DS.Space.s2) {
                                AvatarView(identity: identity(m), size: DS.Size.avatarSuggestion)
                                Text(m.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                                Spacer(minLength: DS.Space.s3)
                                Text("@\(m.handle)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            }
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Size.fieldInset)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SuggestionRowStyle(highlighted: i == 0))
                    }
                }
                .padding(DS.Space.s1)
                .frame(width: DS.Size.popoverWidth)
                .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                .dsShadow(DS.Elevation.popover)
                .transition(motion ? .scale(scale: DS.Motion.pressedScale, anchor: .bottomLeading).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion ? DS.Motion.pop : nil, value: list.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention suggestions")
    }

    private func insert(_ m: RoomMember) { Self.insert(m, into: &draft) }

    static func insert(_ m: RoomMember, into draft: inout String) {
        guard let r = draft.range(of: "@[A-Za-z0-9._:-]*$", options: .regularExpression) else { return }
        draft.replaceSubrange(r, with: "@\(m.handle) ")
    }
}

struct SuggestionRowStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .background(hovering || highlighted || configuration.isPressed ? DS.Palette.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
    }
}

// MARK: - create sheet

struct CreateRoomView: View {
    let bots: [Bot]
    let onCreate: (String, [RoomMember]) async -> String?
    /// Closes the sheet (Cancel, Escape, or a successful create). The sheet is presented by
    /// `motionSheet`, not SwiftUI, so `\.dismiss` would not reach it.
    let onClose: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var name = "Group chat"
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var creating = false
    /// The Name field takes focus on open, as it did under SwiftUI's `.sheet`.
    @FocusState private var nameFocused: Bool

    private var eligible: [(Bot, RoomMember)] { bots.compactMap { b in RoomMember.forBot(b).map { (b, $0) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("New group chat").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden()
                    .focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Members").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s2), GridItem(.flexible(), spacing: DS.Space.s2)],
                          spacing: DS.Space.s2) {
                    ForEach(eligible, id: \.0.name) { bot, _ in memberToggle(bot) }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s2) {
                Text("\(picked.count) of 2 to 6 bots").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    creating = true
                    Task {
                        let members = eligible.filter { picked.contains($0.0.name) }.map(\.1)
                        error = await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), members)
                        creating = false
                        if error == nil { onClose() }
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !(2...6).contains(picked.count) || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
    }

    private func memberToggle(_ bot: Bot) -> some View {
        let on = picked.contains(bot.name)
        let id = avatars.identity(profile: bot.name, title: bot.title)
        return Toggle(isOn: Binding(get: { on }, set: { if $0 { picked.insert(bot.name) } else { picked.remove(bot.name) } })) {
            HStack(spacing: DS.Space.s2) {
                AvatarView(identity: id, size: DS.Size.avatarSuggestion)
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    Text("@\(bot.name)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, DS.Space.s2).frame(maxWidth: .infinity, minHeight: DS.Size.memberToggleHeight, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(on ? id.color : DS.Palette.hairline, lineWidth: on ? DS.Stroke.selectedToggle : DS.Stroke.hairline))
    }
}
