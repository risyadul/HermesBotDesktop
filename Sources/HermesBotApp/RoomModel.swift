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
    /// A kanban board, by slug (KanbanBoardView).
    case board(String)
    /// A Hermes Desktop group chat in the read-only archive, by its archive key (DesktopArchiveModel).
    case archive(String)
}

@MainActor
final class RoomModel: ObservableObject, Identifiable {
    nonisolated let id: String
    @Published private(set) var room: RoomSummary {
        didSet {
            // The roster supplies author names missing from events; room status/name alone do not.
            if room.members != oldValue.members {
                transcriptPresentationNeedsUpdate = true
                roomStatusPresentation = nil
            }
        }
    }
    @Published private(set) var timeline = RoomTimeline() {
        didSet {
            // Room logs are append-only with immutable seq identities. Cursor/count changes identify
            // applied messages without comparing the entire accumulated event array on every poll.
            if timeline.cursor != oldValue.cursor || timeline.events.count != oldValue.events.count {
                transcriptPresentationNeedsUpdate = true
            }
            roomStatusPresentation = nil
        }
    }
    private var transcriptPresentation: RoomTranscriptPresentation?
    private var transcriptPresentationNeedsUpdate = true
    private var roomStatusPresentation: RoomStatusPresentation?
    @Published private(set) var driver: RoomDriverStatus? {
        didSet { roomStatusPresentation = nil }
    }
    @Published private(set) var composer = RoomComposer()
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var busyActions: Set<String> = []
    /// Files picked, pasted or dropped for the next message (copied into the room's folder on send). They go
    /// with the main composer's message; thread replies are text only.
    @Published var pending: [PendingAttachment] = []
    /// Composer drafts per thread (`main` = the room composer). They live here, not in the view, so they
    /// survive switching panes; a send that fails puts its text back.
    let draftStates = RoomDraftStates()
    var drafts: [String: String] {
        get { draftStates.values }
        set { draftStates.values = newValue }
    }
    /// The thread shown in the thread pane (nil: closed).
    @Published var openThread: String?
    /// D12: the open Summarize Since You Left sheet. `RoomView` presents it from the pane; the toolbar button
    /// only sets it (a sheet anchored inside ToolbarItem content never opens).
    @Published var catchUp: RoomCatchUpModel?
    /// A composer that should take focus (Reply to @bot, Reply in thread).
    @Published private(set) var focusRequest: FocusRequest?
    let api: any RoomActions
    /// Local per-room extras removed on disband (tests pass their own).
    var pictures = RoomPictureStore.shared
    var order = RoomOrderStore.shared
    /// Evidence hook: every applied sync (new events since the previous one).
    var onSync: ((RoomModel, [RoomEvent]) -> Void)?
    /// Every applied sync (the sidebar digest follows the open room through it).
    var onApplied: ((RoomModel) -> Void)?
    /// The room's row changed name (renamed here, or elsewhere and seen by a poll).
    var onRoomChanged: ((RoomSummary) -> Void)?
    /// The room was disbanded (here) or found retired: the app drops it from the sidebar.
    var onDisbanded: ((RoomModel) -> Void)?
    private let poller: RoomPoller
    /// The room views on screen (start/stopPolling; D9: the main window and its own window can both show
    /// it); a failed disband resumes polling only while one is.
    private var viewers = PaneViewers()
    private var wantsPolling: Bool { !viewers.isEmpty }
    /// A main window shows on screen (AppModel's one visibility signal): off, the room's poller pauses and
    /// nothing it shows counts as seen; the sidebar digests keep watching the room for notifications.
    private(set) var windowOnScreen = true
    /// App shutdown: polling never restarts.
    private var shutDown = false
    /// The name of a `groups.rename` in flight: polls keep showing it until the call returns.
    private var pendingName: String?
    /// The room revision a confirmed rename produced: a sync that was already in flight carries an older
    /// `groups.state` row (the old name) and must not put it back.
    private var renamedRevision = 0
    /// Anchored threads whose quoted opening message was already sent (the log may not show it yet).
    private var openedThreads: Set<String> = []
    private(set) var pollCount = 0

    struct FocusRequest: Equatable {
        let thread: String
        let id = UUID()
    }

    init(room: RoomSummary, api: any RoomActions) {
        id = room.roomId; self.room = room; self.api = api
        poller = RoomPoller(source: api, roomId: room.roomId)
        poller.onUpdate = { [weak self] u in self?.apply(u) }
        poller.onError = { [weak self] e in self?.syncFailed(e) }
        poller.interval = { [weak self] timeline, state in
            self?.pollInterval ?? RoomPollPolicy.interval(driver: state?.driver, timeline: timeline)
        }
    }

    var disbanded: Bool { composer.availability == .closed }
    var presentation: RoomTranscriptPresentation {
        if !transcriptPresentationNeedsUpdate, let transcriptPresentation { return transcriptPresentation }
        let result = RoomTranscriptPresentation(timeline: timeline, room: room, previous: transcriptPresentation)
        transcriptPresentation = result
        transcriptPresentationNeedsUpdate = false
        return result
    }
    var lines: [RoomLine] { presentation.lines }
    var statusPresentation: RoomStatusPresentation {
        if let roomStatusPresentation { return roomStatusPresentation }
        let result = RoomStatusPresentation(timeline: timeline, room: room, driver: driver)
        roomStatusPresentation = result
        return result
    }
    var memberStates: [String: RoomPresentation.MemberState] { statusPresentation.memberStates }
    func threadPresentation(thread: String) -> RoomThreadPresentation { presentation.thread(thread) }
    var pollInterval: TimeInterval { statusPresentation.pollInterval }
    /// Something is still happening: a task is queued/running/stopping or the latest message is unsettled.
    var active: Bool { statusPresentation.active }
    /// The room view is on screen: what it shows counts as seen (sidebar "needs you"). A room pane in a window
    /// that is hidden, minimised or covered is not.
    var isOnScreen: Bool { wantsPolling && windowOnScreen }
    var pollGeneration: Int { poller.generation }
    var droppedStaleSyncs: Int { poller.droppedStale }

    // MARK: polling

    /// A room view appeared. One poller however many views show the room (`RoomPoller.start` is a no-op
    /// while it runs).
    func start(viewer: ObjectIdentifier = PaneViewers.anonymous) {
        viewers.add(viewer)
        guard !shutDown, composer.isOpen, windowOnScreen else { return }
        poller.start()
    }

    /// The app's windows left or came back on screen (`AppModel.setMainWindowOnScreen`).
    func setWindowOnScreen(_ on: Bool) {
        guard on != windowOnScreen else { return }
        windowOnScreen = on
        if !on {
            poller.stop()
        } else if wantsPolling, !shutDown, composer.isOpen {
            poller.start()
        }
    }

    /// A room view went away; polling stops when no other view (another window, D9) still shows the room.
    func stopPolling(viewer: ObjectIdentifier = PaneViewers.anonymous) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        poller.stop()
    }

    var isPolling: Bool { poller.isRunning }

    /// App quit: stop for good (a later failed disband must not restart polling).
    func shutdown() {
        shutDown = true
        viewers.removeAll()
        poller.stop()
    }

    /// Ends the current wait so the next sync runs now (after a send/stop/retry/approve).
    func nudge() { poller.nudge() }

    private func apply(_ u: RoomPoller.Update) {
        if timeline.cursor != u.timeline.cursor || timeline.latestSeq != u.timeline.latestSeq
            || timeline.gapDetected != u.timeline.gapDetected || timeline.events.count != u.timeline.events.count {
            timeline = u.timeline
        }
        if driver != u.state.driver { driver = u.state.driver }
        lastSync = Date(); pollCount += 1
        let incoming = u.state.room.revision < renamedRevision ? room : u.state.room
        setRoom(pendingName.map { incoming.renamed($0) } ?? incoming)
        onSync?(self, u.newEvents)
        onApplied?(self)
    }

    private func setRoom(_ r: RoomSummary) {
        let renamed = r.name != room.name
        if room != r { room = r }
        if renamed { onRoomChanged?(r) }
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
        RoomAttachmentStore.remove(room: room.roomId)
        // Local extras of the room (C1.4 order, C1.8 picture) go with it.
        pictures.removePicture(room: room.roomId)
        order.forget(room.roomId)
        composer.close()
        poller.stop()
        onDisbanded?(self)
    }

    /// Adds a line to the note bar (and the app log). Change Members notes a failed carry-over on the new room.
    func note(_ s: String) {
        notes.append(s)
        if notes.count > 20 { notes.removeFirst(notes.count - 20) }
        AppModel.shared.log("room \(room.roomId): \(s)")
    }

    // MARK: actions

    /// Sends the composer draft of `thread` and clears it when accepted (Return, Send button).
    @discardableResult
    func submit(thread: String = RoomThreads.main) -> Bool {
        guard send(drafts[thread] ?? "", thread: thread) else { return false }
        drafts[thread] = ""
        return true
    }

    /// Same gate shape as Bot Chat: true only when accepted (the caller clears its draft then). Refused
    /// (draft kept, nothing sent) while a send is in flight or once the room is closing/disbanded —
    /// whichever path called it (Return, button, script). `thread` is the `thread_id`: `main` from the room
    /// composer, a thread id from the thread pane. The first message of a thread started from a `main`
    /// message quotes that message (members only see their thread, `RoomThreads.opening`).
    func send(_ draft: String, thread: String = RoomThreads.main) -> Bool {
        let chips = thread == RoomThreads.main ? pending.filter(\.isReady) : []
        guard chips.count <= RoomAttachments.maxFiles else {
            note("at most \(RoomAttachments.maxFiles) files per message, message not posted")
            return false
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty ? !chips.isEmpty : true,
              composer.beginSend(typed.isEmpty ? RoomAttachments.header : typed) != nil else { return false }
        let ids = Set(chips.map(\.id))
        setChips(ids, .sending)
        let files = chips.compactMap(\.checked), roomId = room.roomId
        let eventId = "hba-msg-\(UUID().uuidString.lowercased())"
        let quote = openingQuote(thread)
        Task {
            defer { composer.finishSend(); nudge() }
            // Copied off the main thread: ten files from another volume (no APFS clone) would stall the UI.
            let copied = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                var out: [URL] = []
                do {
                    for f in files { out.append(try RoomAttachmentStore.copy(f, room: roomId)) }
                    return .success(out)
                } catch {
                    RoomAttachmentStore.discard(out)
                    return .failure(error)
                }
            }.value
            let copies: [URL]
            switch copied {
            case .failure(let error):
                return sendFailed(ids, draft: draft, thread: thread, note: "\(Redaction.describe(error)) Message not posted.")
            case .success(let c):
                copies = c
            }
            var text = RoomAttachments.compose(text: typed, paths: copies.map(\.path))
            if let quote { text = RoomThreads.opening(text, quoting: quote.author, quote.text) }
            guard text.utf8.count <= RoomComposer.maxTextBytes else {
                RoomAttachmentStore.discard(copies)
                let what = copies.isEmpty ? "The message is" : "The message and its file list are"
                return sendFailed(ids, draft: draft, thread: thread, note: "\(what) too long. Message not posted.")
            }
            do {
                let e = try await api.sendMessage(roomId: roomId, eventId: eventId, text: text, threadId: thread)
                AppModel.shared.log("groups.send → seq=\(e.seq) thread=\(thread) (ACK only; replies arrive through polling)")
                if quote != nil { openedThreads.insert(thread) }
                // Sent: pasted originals now live as the room's copies.
                PasteboardAttachments.delete(pending.filter { ids.contains($0.id) }.map(\.url))
                pending.removeAll { ids.contains($0.id) }
            } catch {
                // The copies stay: a timed-out send may still have been posted, and its paths must keep working.
                sendFailed(ids, draft: draft, thread: thread,
                           note: "send failed, the message may not have been posted: \(Redaction.describe(error))")
            }
        }
        return true
    }

    /// A send that did not go out: its chips are ready again and its text goes back to its composer (unless
    /// the user already typed something new there).
    private func sendFailed(_ ids: Set<UUID>, draft: String, thread: String, note text: String) {
        note(text)
        setChips(ids, .ready)
        if (drafts[thread] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drafts[thread] = draft }
    }

    /// The message a new anchored thread quotes: only for its first message (no user message in the
    /// thread yet, none sent from here), and only while the anchor is in the log.
    private func openingQuote(_ thread: String) -> (author: String, text: String)? {
        guard let seq = RoomThreads.anchorSeq(of: thread), !openedThreads.contains(thread),
              !timeline.events.contains(where: { $0.kind == "message.user" && RoomThreads.id(of: $0) == thread }),
              let line = timeline.lines(room: room).first(where: { $0.id == seq }),
              line.kind == .user || line.kind == .member else { return nil }
        return (line.author, RoomAttachments.split(line.text).text)
    }

    private func setChips(_ ids: Set<UUID>, _ state: PendingAttachment.State) {
        for i in pending.indices where ids.contains(pending[i].id) { pending[i].state = state }
    }

    func stop() {
        perform("stop") { api in
            let n = try await api.stopRoom(roomId: self.room.roomId, cancelId: "hba-stop-\(UUID().uuidString.lowercased())")
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
            _ = try await api.disbandRoom(roomId: room.roomId, cancelId: "hba-disband-\(UUID().uuidString.lowercased())")
            note("disbanded")
            markDisbanded()
            return true
        } catch {
            note("disband failed: \(Redaction.describe(error))")
            composer.reopen()
            if wantsPolling && windowOnScreen && !shutDown { poller.start() }
            return false
        }
    }

    private func perform(_ key: String, _ op: @escaping @MainActor (any RoomActions) async throws -> String) {
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

    /// `groups.rename` (room menu → Rename…). Optimistic: the new name shows at once (toolbar, sidebar) and
    /// polls keep it while the call runs; a failure puts the old name back and says why in the note bar.
    /// False (nothing sent) for a blank, too long or unchanged name, a rename already in flight, or a room
    /// that is closing/closed.
    @discardableResult
    func rename(_ raw: String) -> Bool {
        guard composer.isOpen, pendingName == nil, let name = RoomSummary.normalizedName(raw), name != room.name else { return false }
        let previous = room.name, roomId = room.roomId
        let eventId = "hba-rename-\(UUID().uuidString.lowercased())"
        pendingName = name
        busyActions.insert("rename")
        setRoom(room.renamed(name))
        Task {
            do {
                let renamed = try await api.renameRoom(roomId: roomId, eventId: eventId, name: name)
                pendingName = nil
                renamedRevision = max(renamedRevision, renamed.revision)
                setRoom(renamed.roomId == roomId ? renamed : room.renamed(renamed.name))
                note("groups.rename → \(renamed.name)")
            } catch {
                pendingName = nil
                if room.name == name { setRoom(room.renamed(previous)) }
                note("rename failed: \(Redaction.describe(error))")
            }
            busyActions.remove("rename")
            nudge()
        }
        return true
    }
}

// MARK: - threads and per-message actions

extension RoomModel {
    /// Binding target for a composer: the draft of `thread`.
    func draft(_ thread: String) -> String { draftStates.state(for: thread).text }

    func setDraft(_ text: String, thread: String) { draftStates.state(for: thread).text = text }

    /// "Reply in thread" on the message at `seq`: opens its thread (a new one anchored on it for a `main`
    /// message) in the thread pane and focuses that composer.
    func replyInThread(seq: Int) {
        guard let e = timeline.events.first(where: { $0.seq == seq }) else { return }
        showThread(RoomThreads.replyThread(for: e))
    }

    func showThread(_ thread: String) {
        guard thread != RoomThreads.main else { return closeThread() }
        openThread = thread
        focusRequest = FocusRequest(thread: thread)
    }

    func closeThread() {
        openThread = nil
        focusRequest = FocusRequest(thread: RoomThreads.main)
    }

    /// "Reply to @bot" on a member message: puts `@handle ` in front of the draft of the composer that owns
    /// the message's thread (opening the thread pane for a thread message) and focuses it. Only edits the
    /// draft; the user still sends.
    func replyToMember(seq: Int) {
        guard let e = timeline.events.first(where: { $0.seq == seq }), e.kind == "message.member",
              let member = room.member(e.memberId) else { return }
        let thread = RoomThreads.id(of: e)
        if thread != RoomThreads.main { openThread = thread }
        drafts[thread] = Self.seedMention(member.handle, into: draft(thread))
        focusRequest = FocusRequest(thread: thread)
    }

    /// `@handle ` in front of `draft`, unless the draft already mentions that handle. Trailing whitespace
    /// folds to one space so the caret lands after the mention (Hermes Desktop `replyToMember`).
    nonisolated static func seedMention(_ handle: String, into draft: String) -> String {
        let tag = "@\(handle)"
        let pattern = "(?<![A-Za-z0-9._:-])" + NSRegularExpression.escapedPattern(for: tag) + "(?![A-Za-z0-9._:-])"
        if draft.range(of: pattern, options: .regularExpression) != nil { return draft }
        let seeded = "\(tag) \(draft)"
        guard let r = seeded.range(of: "\\s+$", options: .regularExpression) else { return seeded }
        return seeded.replacingCharacters(in: r, with: " ")
    }
}

// MARK: - attachments

extension RoomModel {
    /// Adds files (paperclip, drop, paste) as chips; refused files show their reason on the chip.
    func addAttachments(_ urls: [URL]) {
        guard composer.isOpen else { return }
        for url in urls where url.isFileURL {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !pending.contains(where: { $0.key == key && !$0.isFailed }) else { continue }
            pending.removeAll { $0.key == key && $0.isFailed }
            pending.append(PendingAttachment(url: url, key: key, check: { try RoomAttachments.check($0) }))
        }
    }

    func removeAttachment(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }), !pending[i].isSending else { return }
        let chip = pending.remove(at: i)
        PasteboardAttachments.delete([chip.url])
    }
}
