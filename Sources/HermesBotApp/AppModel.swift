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
    /// Activity panel models per room (`activityModel(for:)`, RoomActivityModel.swift).
    var activityModels: [String: RoomActivityModel] = [:]
    /// Sidebar room rows: last message, age, "needs you" (RoomDigests.swift).
    let roomDigests = RoomDigestHub()
    @Published var showCreateRoom = false
    /// The Edit / Duplicate / Delete bot sheet on screen (AppModel+BotManagement.swift).
    @Published var botSheet: BotSheet?
    /// `groups.capabilities` answered at connect. False on an older Hermes Agent without `groups.*`:
    /// Group Chat is off (no "+", a notice), Bot Chat still works.
    @Published private(set) var groupsAvailable = true
    /// Kanban boards, board models and the dispatcher status of the current connection (KanbanHub.swift).
    let kanban = KanbanHub(watches: KanbanWatchList(defaults: .standard))
    /// Pin / Hide per bot, saved to the profile's `ui_meta` (A2, BotMetaModel.swift).
    let botMeta = BotMetaModel()
    /// Native notifications and the Dock badge (D1, D2: Notifications/).
    let notifications: NotificationCoordinator
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

    init() {
        let poster = UserNotificationPoster.makeIfAvailable()
        notifications = NotificationCoordinator(poster: poster)
        poster?.onRoute = { [weak self] route in self?.handleNotification(route) }
        notifications.botHidden = { [weak self] name in self?.botMeta[name].hidden ?? false }
        notifications.rooms.log = { [weak self] line in self?.log(line) }
        // A board deleted or archived elsewhere leaves the selection (its pane would show a dead board).
        kanban.onBoardsListed = { [weak self] listed in self?.boardsListed(listed) }
        // K9: a watched card finished or is blocked (AppModel+Kanban.swift).
        kanban.onCardEvent = { [weak self] event in self?.kanbanCardChanged(event) }
    }

    func boardsListed(_ listed: Set<String>) {
        if case .board(let slug)? = selection, !listed.contains(slug) {
            selection = nil
            log("board \(slug) is gone → selection cleared")
        }
    }

    /// Windows showing the main content (`RootView`); Settings and system windows are not among them.
    private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    func markMainWindow(_ window: NSWindow) {
        guard !mainWindows.contains(window) else { return }
        mainWindows.add(window)
        updateVisibility()
    }

    /// Main windows on or off screen (AppDelegate): Kanban polling pauses while none shows.
    func updateVisibility() {
        let windows = NSApp.windows.map {
            (mainWindows.contains($0), $0.isVisible, $0.isMiniaturized, $0.occlusionState.contains(.visible))
        }
        kanban.setActive(KanbanHub.onScreen(appHidden: NSApp.isHidden, windows: windows))
    }

    func log(_ s: String) {
        print("[app \(String(format: "%7.3f", Date().timeIntervalSince(started)))] \(s)")
    }

    /// The bot's canonical Bot Chat model, one per bot for the life of the connection. It opens (resume,
    /// or create on confirmed absence) when its view appears.
    func chat(for bot: Bot) -> ChatModel {
        if let c = chats[bot.name] { return c }
        let c = ChatModel(bot: bot, opener: Self.canonicalOpener(backend))
        c.onTurnEvent = { [weak self] type, chat in
#if DEBUG
            self?.turnEvent(type, chat)
#endif
            self?.notifications.turnEvent(type, chat)
        }
        notifications.track(c)
        chats[bot.name] = c
        return c
    }

    static func canonicalOpener(_ backend: Backend?) -> ChatOpener {
        { bot in
            guard let backend else { throw GatewayClient.ClientError.notConnected }
            return try await BotChatSession.openCanonical(backend, bot: bot)
        }
    }

    /// Also the Try Again action. A failed attempt keeps no connection (`ConnectFlow`), and a lost
    /// connection is dropped (`backendLost`), so calling this again after `.failed` really reconnects;
    /// while an attempt runs, once connected, or while quitting, it is a no-op.
    ///
    /// `waitForAttach` > 0: for that long, only attach (retrying discovery) before a spawn is considered — a
    /// background Hermes that was just started needs a moment to publish its rendezvous record.
    func connect(waitForAttach: TimeInterval = 0) async {
        guard !shuttingDown, connectTask == nil, backend == nil else { return }
        let task = Task { await self.attemptConnect(waitForAttach: waitForAttach) }
        connectTask = task
        await task.value
        if connectTask == task { connectTask = nil }
    }

    /// How long to wait for a just-started background Hermes (Settings → Background) to appear.
    static let backgroundAttachWait: TimeInterval = 20

    /// First connect of the app: an "At Next Launch" background Hermes is started first, then attached to.
    func connectAtLaunch() async {
        let started = await BackgroundServeSettingsModel.startPendingAtLaunch(control: BackgroundServe())
        if started { log("background Hermes started (chosen for this launch): waiting for it to publish itself") }
        await connect(waitForAttach: started ? Self.backgroundAttachWait : 0)
    }

    /// Drops the current connection on purpose (Settings → Background changed the backend) and connects again.
    func reconnect(reason: String, waitForAttach: TimeInterval = 0) async {
        if let b = backend { backendLost(b, reason: reason) }
        await connect(waitForAttach: waitForAttach)
    }

    /// Stops the app's own spawned backend (Settings → Background → Switch Now) and waits until it exited.
    /// An attached backend is never stopped.
    func stopOwnedBackend(reason: String) async {
        guard let b = backend, b.owned != nil else { return }
        backendLost(b, reason: reason)
        await releasingLost?.value
    }

    /// `Backend.connect`, optionally attach-only (retried) for `waitForAttach` seconds first.
    static func openBackend(waitForAttach: TimeInterval, log: @escaping @Sendable (String) -> Void) async throws -> Backend {
        var options = Backend.Options.fromEnvironment()
        if waitForAttach > 0, !options.forceSpawn {
            options.allowSpawn = false
            let deadline = Date().addingTimeInterval(waitForAttach)
            while true {
                do { return try await Backend.connect(options, log: log) } catch Backend.Failure.noBackend {
                    guard Date() < deadline else { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            options = .fromEnvironment()
        }
        return try await Backend.connect(options, log: log)
    }

    private func attemptConnect(waitForAttach: TimeInterval) async {
        phase = .connecting
        if let lost = releasingLost {
            await lost.value
            releasingLost = nil
        }
        AvatarStore.shared.reset()  // retry avatars that failed on the previous connection
        do {
            let b = try await ConnectFlow.open(
                connect: {
                    try await Self.openBackend(waitForAttach: waitForAttach,
                                               log: { line in Task { @MainActor in AppModel.shared.log(line) } })
                },
                load: { b in
                    self.backend = b
                    self.disconnectToken = b.onDisconnect { [weak self] reason in
                        Task { @MainActor in self?.backendLost(b, reason: reason) }
                    }
                    try Task.checkCancellation()  // quitting: `release` stops what was just connected
                    self.modeText = b.mode.description
                    self.bots = try await Bot.list(b)
                    self.botMeta.load(self.bots)
                    self.botMeta.saver = BotMetaModel.saver(b.client)
                    self.log("profiles.list → \(self.bots.map(\.name))")
                },
                release: { b in
                    // Lost while loading: `backendLost` already dropped it and is stopping it.
                    guard self.backend === b else { return }
                    self.unsubscribeDisconnect(b)
                    self.backend = nil
                    self.bots = []
                    self.botMeta.reset()
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
            kanban.connect(api: b.sessionREST.map { KanbanAPI(access: $0) })
            if groupsAvailable, let groups { notifications.rooms.start(source: groups) }
#if DEBUG
            autochat()
            autoroom()
            autoswitch()
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
        for m in activityModels.values { m.shutdown() }
        activityModels = [:]
        roomDigests.stop()
        for c in chats.values { c.close() }
        chats = [:]
        kanban.disconnect()
        notifications.reset()
        botMeta.reset()
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
        var listed: [RoomSummary]?
        do {
            rooms = try await groups.allRooms()
            notifications.rooms.setRooms(rooms)
            listed = rooms
            log("groups.list → \(rooms.count) room(s)")
        } catch { log("groups.list failed: \(Redaction.describe(error))") }
        roomDigests.start(directory: groups, listed: listed)
    }

    func roomModel(_ id: String) -> RoomModel? {
        if let m = roomModels[id] { return m }
        guard let room = rooms.first(where: { $0.roomId == id }), let groups else { return nil }
        let m = RoomModel(room: room, api: groups)
        m.onSync = { [weak self] model, new in
#if DEBUG
            self?.roomSynced(model, new)
#endif
            self?.notifications.rooms.ingest(room: model.room, events: new, driver: model.driver, latestSeq: model.timeline.cursor)
        }
        m.onDisbanded = { [weak self] model in self?.roomDisbanded(model.id) }
        m.onApplied = { [weak self] model in self?.roomDigests.absorb(model) }
        m.onRoomChanged = { [weak self] room in self?.roomRenamed(room) }
        roomModels[id] = m
        return m
    }

    /// A disbanded (or found-retired) room leaves the sidebar, the selection and the model cache, as
    /// `groups.list` no longer lists it.
    func roomDisbanded(_ id: String) {
        if selection == .room(id) { selection = nil }
        rooms.removeAll { $0.roomId == id }
        roomModels[id] = nil
        activityModels.removeValue(forKey: id)?.shutdown()
        notifications.rooms.setRooms(rooms)
        roomDigests.forget(id)
        log("room \(id) disbanded → removed from the sidebar")
    }

    /// A room's name changed (renamed here, optimistically, or seen renamed by a poll): its sidebar row follows.
    func roomRenamed(_ room: RoomSummary) {
        guard let i = rooms.firstIndex(where: { $0.roomId == room.roomId }), rooms[i].name != room.name else { return }
        rooms[i] = rooms[i].renamed(room.name)
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
            notifications.rooms.setRooms(rooms)
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
        for m in activityModels.values { m.shutdown() }
        roomDigests.stop()
        kanban.disconnect()
        notifications.reset()
#if DEBUG
        await disbandCreatedRooms()
#endif
        // Bot Chats are the bots' canonical chats (shared with Hermes Desktop): detach only, never
        // `session.close` / `session.delete`.
        for c in chats.values { c.close() }
        if !chats.isEmpty { log("bot chats detached: \(chats.keys.sorted())") }
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
    /// directly (briefly) so it does not outlive the app. Bot Chats need nothing: they are only detached.
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
