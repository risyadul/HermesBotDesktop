import AppKit
import HermesGatewayKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Phase { case connecting, connected, failed(String) }
    @Published var phase: Phase = .connecting
    @Published var modeText = ""
    @Published var bots: [Bot] = []
    @Published var selection: SidebarItem?
    @Published var chats: [String: ChatModel] = [:]
    @Published var rooms: [RoomSummary] = []
    @Published var roomModels: [String: RoomModel] = [:]
    @Published var showCreateRoom = false
    /// `groups.capabilities` answered at connect. False on an older Hermes Agent without `groups.*`:
    /// Group Chat is off (no "+", a notice), Bot Chat still works.
    @Published private(set) var groupsAvailable = true
    var selectedBot: String? { if case .bot(let n)? = selection { return n }; return nil }
    private(set) var backend: Backend?
    private var disconnectToken: UUID?
    /// The connect attempt in flight (nil when idle). `shutdown()` cancels it so a backend spawned while
    /// the app quits is stopped instead of outliving it; `backendLost` drops it so Try Again works at once.
    private var connectTask: Task<Void, Never>?
    /// `Backend.shutdown` of a lost backend, still running (an owned one may take up to its grace period
    /// to exit). The next attempt waits for it, so it never attaches to or spawns beside a dying backend.
    private var releasingLost: Task<Void, Never>?
    private var shuttingDown = false
    let started = Date()
#if DEBUG
    /// Scripted runs and window evidence (EvidenceDriver.swift); not compiled into release builds.
    var evidence = EvidenceState()
#endif

    func log(_ s: String) {
        print("[app \(String(format: "%7.3f", Date().timeIntervalSince(started)))] \(s)")
    }

    func chat(for bot: Bot) -> ChatModel {
        if let c = chats[bot.name] { return c }
        let c = ChatModel(bot: bot)
#if DEBUG
        c.onTurnEvent = { [weak self] type, chat in self?.turnEvent(type, chat) }
#endif
        chats[bot.name] = c
        return c
    }

    /// Also the Try Again action. A failed attempt keeps no connection (`ConnectFlow`), and a lost
    /// connection is dropped (`backendLost`), so calling this again after `.failed` really reconnects;
    /// while an attempt runs, once connected, or while quitting, it is a no-op.
    func connect() async {
        guard !shuttingDown, connectTask == nil, backend == nil else { return }
        let task = Task { await self.attemptConnect() }
        connectTask = task
        await task.value
        if connectTask == task { connectTask = nil }
    }

    private func attemptConnect() async {
        phase = .connecting
        if let lost = releasingLost {
            await lost.value
            releasingLost = nil
        }
        AvatarStore.shared.reset()  // retry avatars that failed on the previous connection
        do {
            let b = try await ConnectFlow.open(
                connect: { try await Backend.connect(log: { line in Task { @MainActor in AppModel.shared.log(line) } }) },
                load: { b in
                    self.backend = b
                    self.disconnectToken = b.onDisconnect { [weak self] reason in
                        Task { @MainActor in self?.backendLost(b, reason: reason) }
                    }
                    try Task.checkCancellation()  // quitting: `release` stops what was just connected
                    self.modeText = b.mode.description
                    self.bots = try await Bot.list(b)
                    self.log("profiles.list → \(self.bots.map(\.name))")
                },
                release: { b in
                    // Lost while loading: `backendLost` already dropped it and is stopping it.
                    guard self.backend === b else { return }
                    self.unsubscribeDisconnect(b)
                    self.backend = nil
                    self.bots = []
                    self.modeText = ""
                    let owned = b.owned
                    await Task.detached { b.shutdown() }.value
                    self.log(owned.map { "load failed: owned backend pid \($0.pid) stopped" }
                             ?? "load failed: socket closed, attached backend left running (not ours)")
                })
            guard backend === b else { return }  // lost while loading: `backendLost` set `.failed`
            await checkGroups()
            if groupsAvailable { await loadRooms() }
            guard backend === b else { return }
            phase = .connected
#if DEBUG
            autochat()
            autoroom()
#endif
        } catch {
            let msg = Redaction.describe(error)
            log("connect failed: \(msg)")
            // `backendLost` already showed why; its message is the one to keep.
            if case .failed = phase { return }
            phase = .failed(msg)
        }
    }

    private func unsubscribeDisconnect(_ b: Backend) {
        if let t = disconnectToken { b.unsubscribe(t) }
        disconnectToken = nil
    }

    /// The gateway socket of the current backend is gone (backend quit or crashed, network drop):
    /// stop every room poller, drop the connection and its chats, and show `.failed` with Try Again.
    func backendLost(_ b: Backend, reason: String) {
        guard backend === b else { return }  // a stale backend (already released or replaced)
        log("backend disconnected: \(reason)")
        unsubscribeDisconnect(b)
        for m in roomModels.values { m.shutdown() }
        roomModels = [:]
        chats = [:]
        rooms = []
        bots = []
        modeText = ""
        backend = nil
        connectTask = nil  // an attempt still loading bails out (`backend !== b`); Try Again may start anew
        releasingLost = Task.detached { b.shutdown() }  // stops an owned backend; an attached one is left running
        phase = .failed("Lost the connection to Hermes (\(reason)).")
    }

    /// `groups.capabilities`: an older Hermes Agent has no `groups.*`, and Group Chat stays off.
    private func checkGroups() async {
        guard let groups else { return }
        do {
            _ = try await groups.capabilities()
            groupsAvailable = true
        } catch let e as GatewayClient.RPCError where e.code == -32601 {
            groupsAvailable = false  // JSON-RPC "method not found": this Hermes Agent has no `groups.*`
            log("groups.capabilities not supported, Group Chat off: \(Redaction.describe(e))")
        } catch {
            groupsAvailable = true  // transient: Group Chat stays available
            log("groups.capabilities failed, Group Chat kept on: \(Redaction.describe(error))")
        }
    }

    // MARK: rooms

    var groups: GroupsAPI? { backend.map { GroupsAPI(client: $0.client) } }

    func loadRooms() async {
        guard let groups else { return }
        do {
            rooms = try await groups.allRooms()
            log("groups.list → \(rooms.count) room(s)")
        } catch { log("groups.list failed: \(Redaction.describe(error))") }
    }

    func roomModel(_ id: String) -> RoomModel? {
        if let m = roomModels[id] { return m }
        guard let room = rooms.first(where: { $0.roomId == id }), let groups else { return nil }
        let m = RoomModel(room: room, api: groups)
#if DEBUG
        m.onSync = { [weak self] model, new in self?.roomSynced(model, new) }
#endif
        m.onDisbanded = { [weak self] model in self?.roomDisbanded(model.id) }
        roomModels[id] = m
        return m
    }

    /// A disbanded (or found-retired) room leaves the sidebar, the selection and the model cache, as
    /// `groups.list` no longer lists it.
    func roomDisbanded(_ id: String) {
        if selection == .room(id) { selection = nil }
        rooms.removeAll { $0.roomId == id }
        roomModels[id] = nil
        log("room \(id) disbanded → removed from the sidebar")
    }

    /// An app-minted room id: `hba-` + 12 hex.
    static func mintRoomId() -> String {
        "hba-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    /// `groups.create` with an app-minted id (or `roomId`). Returns an error text or nil.
    /// Debug builds also record the room for scripted runs (`roomCreated`, EvidenceDriver.swift).
    func createRoom(name: String, members: [RoomMember], roomId: String? = nil) async -> String? {
        guard let groups else { return "not connected" }
        let id = roomId ?? Self.mintRoomId()
        do {
            let room = try await groups.createRoom(roomId: id, name: name, members: members)
#if DEBUG
            roomCreated(room)
#endif
            log("groups.create → \(room.roomId) members=\(room.members.map(\.handle))")
            rooms.removeAll { $0.roomId == room.roomId }
            rooms.insert(room, at: 0)
            selection = .room(room.roomId)
            return nil
        } catch {
            return Redaction.describe(error)
        }
    }

    func shutdown() async {
        shuttingDown = true
        defer { shuttingDown = false }
        if let attempt = connectTask {  // quitting mid-connect: whatever it connected is released below
            attempt.cancel()
            await attempt.value
            connectTask = nil
        }
        if let b = backend { unsubscribeDisconnect(b) }  // our own close is not a lost connection
        for m in roomModels.values { m.shutdown() }
#if DEBUG
        await disbandCreatedRooms()
#endif
        for c in chats.values { for n in await c.close() { log(n) } }
        if let b = backend {
            let owned = b.owned
            await Task.detached { b.shutdown() }.value
            if let owned { log("owned backend pid \(owned.pid) stopped, running=\(owned.isRunning)") }
            else { log("attached backend left running (not ours)") }
            backend = nil
        }
#if DEBUG
        writeEvidence()
#endif
    }

    /// Quit deadline passed with `shutdown()` still waiting on the backend: stop an owned backend
    /// directly (briefly) so it does not outlive the app; sessions are reaped by `close_on_disconnect`.
    func abandonShutdown(after seconds: TimeInterval) {
        log("cleanup still running after \(Int(seconds)) s: quitting anyway")
        if let owned = backend?.owned {
            owned.stop(grace: 1)
            log("owned backend pid \(owned.pid) stopped, running=\(owned.isRunning)")
        }
#if DEBUG
        writeEvidence()
#endif
    }
}

extension AppModel.Phase {
    var isConnected: Bool { if case .connected = self { return true }; return false }
}
