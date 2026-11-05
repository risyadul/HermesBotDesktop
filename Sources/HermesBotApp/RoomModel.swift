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
    /// Files picked, pasted or dropped for the next message (copied into the room's folder on send).
    @Published var pending: [PendingAttachment] = []
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
        RoomAttachmentStore.remove(room: room.roomId)
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
        let chips = pending.filter(\.isReady)
        guard chips.count <= RoomAttachments.maxFiles else {
            note("at most \(RoomAttachments.maxFiles) files per message, message not posted")
            return false
        }
        guard composer.canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chips.isEmpty else { return false }
        var copies: [URL] = []
        for chip in chips {
            guard let checked = chip.checked else { continue }
            do {
                copies.append(try RoomAttachmentStore.copy(checked, room: room.roomId))
            } catch {
                RoomAttachmentStore.discard(copies)
                if let i = pending.firstIndex(where: { $0.id == chip.id }) { pending[i].state = .failed(Redaction.describe(error)) }
                return false
            }
        }
        guard let text = composer.beginSend(RoomAttachments.compose(text: draft, paths: copies.map(\.path))) else {
            RoomAttachmentStore.discard(copies)
            return false
        }
        let sentIds = Set(chips.map(\.id))
        PasteboardAttachments.delete(chips.map(\.url))  // pasted images now live as room copies
        pending.removeAll { sentIds.contains($0.id) }
        let eventId = "hba-msg-\(UUID().uuidString.lowercased())"
        Task {
            do {
                let e = try await api.sendMessage(roomId: room.roomId, eventId: eventId, text: text, threadId: "main")
                AppModel.shared.log("groups.send → seq=\(e.seq) (ACK only; replies arrive through polling)")
            } catch {
                note("send failed, message not posted: \(Redaction.describe(error))")
                RoomAttachmentStore.discard(copies)
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
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let chip = pending.remove(at: i)
        PasteboardAttachments.delete([chip.url])
    }
}
