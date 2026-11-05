import AppKit
import HermesGatewayKit
import SwiftUI

// App shell: attach-first to a running Hermes backend (or spawn `hermes serve --isolated`), list the
// user's bots (`profiles.list`), chat 1:1 with one bot with a streamed reply (M1:
// `session.create` → `session.title` → `prompt.submit` → `message.start/delta/complete`), and Group
// Chat (M2, GroupChatViews.swift: `groups.list/create/send/state/log/stop/retry/approve/disband`,
// room updates by polling). The M0 groups.* round-trip lives on in `spike-harness`.
//
// Scripted verification (no clicks):
//   HERMES_BOT_APP_AUTOCHAT="<profile>|<prompt>"   select that bot and send the prompt once connected
//   HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>" create an hba- room with those bots, open it, send
//   HERMES_BOT_APP_AUTOROOM_STOP_AFTER=<s>         press Stop <s> seconds after a task is running
//   HERMES_BOT_APP_AUTOROOM_APPROVE=once|deny      answer the first pending room approval (as the button does)
//   HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>      ...after leaving the card on screen <s> seconds (evidence)
//   HERMES_BOT_APP_AUTOROOM_RETRY=1                press Retry on the first pending retry action
//   HERMES_BOT_APP_OPEN_ROOM=<room_id>             open an existing room instead of creating one
//   HERMES_BOT_APP_DISBAND_ROOMS=1                 disband the rooms this run created/opened on quit
//   HERMES_BOT_APP_EVIDENCE=<dir>                  write window snapshots + ui-log.json there
//   HERMES_BOT_APP_AUTOQUIT=1                      quit after the reply completed / room settled (normal cleanup)
//   HERMES_BOT_APP_KEEP_SESSIONS=1                 keep chat sessions on quit (default: close + delete)
//   HERMES_BOT_APP_APPEARANCE=light|dark           force the appearance (evidence of both designed modes)
// plus Backend.Options env (HERMES_BOT_APP_LOCK_DIR, HERMES_BOT_APP_FORCE_SPAWN, HERMES_BOT_APP_NO_SPAWN).
// Look and motion: DESIGN.md (tokens in DesignSystem.swift).

@main
struct HermesBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage(DS.Motion.settingKey) private var motion = true
    var body: some Scene {
        WindowGroup("Hermes Bot") { RootView(model: AppModel.shared).modifier(MotionGate()) }
            .defaultSize(DS.Size.windowDefault)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(after: .sidebar) {
                    Toggle("Animate Interface Changes", isOn: $motion)
                }
            }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // `swift run` launches a bare executable: make it a regular foreground app with a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        switch ProcessInfo.processInfo.environment["HERMES_BOT_APP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // SIGTERM and SIGINT (Ctrl+C in the launching terminal) → the same graceful path as Quit
        // (close sessions, stop only an owned backend). A repeated signal while cleanup runs is a
        // no-op (`cleanupStarted`). An owned backend is spawned in its own process group, so the
        // terminal's SIGINT does not reach it before cleanup has used it.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Close/delete our chat sessions, then stop the backend only if we spawned it. If we crash
    /// instead, `close_on_disconnect` reaps live sessions and the spawned backend's
    /// HERMES_PARENT_PID watchdog exits it.
    ///
    /// Not `.terminateLater`: that parks the run loop in a modal mode, and the MainActor
    /// continuations of the async cleanup (and the SIGTERM source on the main queue) never ran,
    /// so a scripted quit hung until SIGKILL (evidence/m1/app-attach-console.log). Instead: cancel,
    /// clean up on the normal run loop, then terminate again.
    ///
    /// Cleanup has an overall deadline (`quitDeadline`): a stuck backend (an RPC that never answers)
    /// must not hang ⌘Q, Ctrl+C or SIGTERM. Past it the app exits anyway; an owned backend is stopped
    /// first, and live sessions are reaped by `close_on_disconnect`.
    static let quitDeadline: TimeInterval = 5
    private var cleanupDone = false
    private var cleanupStarted = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupDone { return .terminateNow }
        if !cleanupStarted {
            cleanupStarted = true
            AppModel.shared.log("quit requested: cleaning up before exit")
            Task { @MainActor in
                await AppModel.shared.shutdown()
                self.finishTermination()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitDeadline) {
                MainActor.assumeIsolated {
                    guard !self.cleanupDone else { return }
                    AppModel.shared.abandonShutdown(after: Self.quitDeadline)
                    self.finishTermination()
                }
            }
        }
        return .terminateCancel
    }

    @MainActor private func finishTermination() {
        guard !cleanupDone else { return }
        cleanupDone = true
        NSApp.terminate(nil)
    }
}

// MARK: - models

/// UI wrapper around `ChatTranscript` (HermesGatewayKit), which owns the submit gate and the turn
/// settling rules and is unit tested there.
@MainActor
final class ChatModel: ObservableObject, Identifiable {
    let bot: Bot
    @Published private(set) var transcript = ChatTranscript()
    private(set) var session: BotChatSession?
    /// `BotChatSession.open` in flight: `close()` waits for it, so a session opened while the app quits
    /// is still closed (and deleted) instead of outliving cleanup.
    private var opening: Task<BotChatSession, Error>?
    private var closed = false
    var onTurnEvent: ((String, ChatModel) -> Void)?

    var lines: [ChatLine] { transcript.lines }
    var busy: Bool { transcript.busy }
    var deltaCount: Int { transcript.deltaCount }

    init(bot: Bot) { self.bot = bot }

    /// Synchronous submit gate. Returns true only when the message was accepted (the caller clears
    /// its input then); false while a turn runs or for blank input, with nothing sent or changed.
    /// Being synchronous on the main actor, a second submit before the network task starts sees
    /// `busy` already set.
    @discardableResult
    func submit(_ draft: String, backend: Backend, title: String) -> Bool {
        guard let text = transcript.beginTurn(draft) else { return false }
        Task { await self.run(text, backend: backend, title: title) }
        return true
    }

    private func run(_ text: String, backend: Backend, title: String) async {
        do {
            if session == nil {
                let open = Task { [bot] in try await BotChatSession.open(backend, bot: bot, title: title) }
                opening = open
                defer { opening = nil }
                let s = try await open.value
                guard !closed else { return }  // `close()` awaited `open` and closes this session
                // FIFO onto the main actor: one Task per event would not guarantee delta order.
                s.onEvent { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(e) } } }
                session = s
                AppModel.shared.log("chat opened: profile=\(bot.name) session_id=\(s.sessionId) stored=\(s.storedSessionId) title=\(s.titleResult ?? .null)")
            }
            let r = try await session!.send(text)
            AppModel.shared.log("prompt.submit → \(r)")
        } catch {
            let msg = Redaction.describe(error)
            AppModel.shared.log("send failed: \(msg)")
            transcript.fail(msg)
        }
    }

    private func apply(_ e: ChatEvent) {
        transcript.apply(e)
        switch e {
        case .started: onTurnEvent?("message.start", self)
        case .delta: onTurnEvent?("message.delta", self)
        case .interim: onTurnEvent?("message.interim", self)
        case .completed: onTurnEvent?("message.complete", self)
        case .error, .disconnected: onTurnEvent?("turn.failed", self)
        default: break
        }
    }

    var streamingText: String { transcript.lastBotText }

    func close() async -> [String] {
        closed = true
        var pending = session
        session = nil
        if pending == nil, let open = opening { pending = try? await open.value }
        guard let s = pending else { return [] }
        let keep = ProcessInfo.processInfo.environment["HERMES_BOT_APP_KEEP_SESSIONS"] == "1"
        return await s.close(deleteStored: !keep)
    }
}

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
    /// Rooms this app run created (disbanded on quit only with HERMES_BOT_APP_DISBAND_ROOMS=1).
    private(set) var createdRooms: [String] = []
    var selectedBot: String? { if case .bot(let n)? = selection { return n }; return nil }
    private(set) var backend: Backend?
    private var disconnectToken: UUID?
    private var connecting = false
    private let started = Date()
    private var uiLog: [JSONValue] = []
    private var autoQuit = false
    let evidenceDir = ProcessInfo.processInfo.environment["HERMES_BOT_APP_EVIDENCE"].map { URL(fileURLWithPath: $0) }

    func log(_ s: String) {
        print("[app \(String(format: "%7.3f", Date().timeIntervalSince(started)))] \(s)")
    }

    func chat(for bot: Bot) -> ChatModel {
        if let c = chats[bot.name] { return c }
        let c = ChatModel(bot: bot)
        c.onTurnEvent = { [weak self] type, chat in self?.turnEvent(type, chat) }
        chats[bot.name] = c
        return c
    }

    /// Also the Try Again action. A failed attempt keeps no connection (`ConnectFlow`), and a lost
    /// connection is dropped (`backendLost`), so calling this again after `.failed` really reconnects;
    /// while an attempt runs, or once connected, it is a no-op.
    func connect() async {
        guard !connecting, backend == nil else { return }
        connecting = true
        defer { connecting = false }
        phase = .connecting
        AvatarStore.shared.reset()  // retry avatars that failed on the previous connection
        do {
            _ = try await ConnectFlow.open(
                connect: { try await Backend.connect(log: { line in Task { @MainActor in AppModel.shared.log(line) } }) },
                load: { b in
                    self.backend = b
                    self.disconnectToken = b.onDisconnect { [weak self] reason in
                        Task { @MainActor in self?.backendLost(b, reason: reason) }
                    }
                    self.modeText = b.mode.description
                    self.bots = try await Bot.list(b)
                    self.log("profiles.list → \(self.bots.map(\.name))")
                },
                release: { b in
                    self.unsubscribeDisconnect(b)
                    self.backend = nil
                    self.bots = []
                    self.modeText = ""
                    let owned = b.owned
                    await Task.detached { b.shutdown() }.value
                    self.log(owned.map { "load failed: owned backend pid \($0.pid) stopped" }
                             ?? "load failed: socket closed, attached backend left running (not ours)")
                })
            await checkGroups()
            if groupsAvailable { await loadRooms() }
            guard backend != nil else { return }  // lost while loading: `backendLost` set `.failed`
            phase = .connected
            autochat()
            autoroom()
        } catch {
            let msg = Redaction.describe(error)
            phase = .failed(msg)
            log("connect failed: \(msg)")
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
        Task.detached { b.shutdown() }  // stops an owned backend; an attached one is left running
        phase = .failed("Lost the connection to Hermes (\(reason)).")
    }

    /// `groups.capabilities`: an older Hermes Agent has no `groups.*`, and Group Chat stays off.
    private func checkGroups() async {
        guard let groups else { return }
        do {
            _ = try await groups.capabilities()
            groupsAvailable = true
        } catch {
            groupsAvailable = false
            log("groups.capabilities failed, Group Chat off: \(Redaction.describe(error))")
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
        m.onSync = { [weak self] model, new in self?.roomSynced(model, new) }
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
    /// With `HERMES_BOT_APP_ROOM_MANIFEST=<path>` (scripted test runs) the created room is appended to
    /// that JSON-lines manifest so `group-chat-harness cleanup @<path>` can attribute its member sessions.
    func createRoom(name: String, members: [RoomMember], roomId: String? = nil) async -> String? {
        guard let groups else { return "not connected" }
        let id = roomId ?? Self.mintRoomId()
        do {
            let room = try await groups.createRoom(roomId: id, name: name, members: members)
            if let path = ProcessInfo.processInfo.environment["HERMES_BOT_APP_ROOM_MANIFEST"], !path.isEmpty {
                do { try RoomManifest.append(RoomManifestEntry(room: room), to: URL(fileURLWithPath: path)) }
                catch { log("room manifest append failed: \(Redaction.describe(error))") }
            }
            createdRooms.append(room.roomId)
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
        if let b = backend { unsubscribeDisconnect(b) }  // our own close is not a lost connection
        for m in roomModels.values { m.shutdown() }
        if ProcessInfo.processInfo.environment["HERMES_BOT_APP_DISBAND_ROOMS"] == "1" {
            for id in createdRooms {
                if let m = roomModel(id) { log("disband \(id) → \(await m.disband() ? "ok" : "failed")") }
            }
            if !createdRooms.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)  // let the sidebar drop the rows
                snapshot("r6-after-disband")
                log("sidebar rooms after disband: \(rooms.map(\.roomId)) selection=\(selection.map { "\($0)" } ?? "nil")")
            }
        }
        for c in chats.values { for n in await c.close() { log(n) } }
        if let b = backend {
            let owned = b.owned
            await Task.detached { b.shutdown() }.value
            if let owned { log("owned backend pid \(owned.pid) stopped, running=\(owned.isRunning)") }
            else { log("attached backend left running (not ours)") }
            backend = nil
        }
        writeEvidence()
    }

    /// Quit deadline passed with `shutdown()` still waiting on the backend: stop an owned backend
    /// directly (briefly) so it does not outlive the app; sessions are reaped by `close_on_disconnect`.
    func abandonShutdown(after seconds: TimeInterval) {
        log("cleanup still running after \(Int(seconds)) s: quitting anyway")
        if let owned = backend?.owned {
            owned.stop(grace: 1)
            log("owned backend pid \(owned.pid) stopped, running=\(owned.isRunning)")
        }
        writeEvidence()
    }

    // MARK: scripted evidence

    private func autochat() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["HERMES_BOT_APP_AUTOCHAT"], let bar = spec.firstIndex(of: "|") else { return }
        autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
        let name = String(spec[..<bar]), prompt = String(spec[spec.index(after: bar)...])
        guard let bot = bots.first(where: { $0.name == name }), let backend else { log("autochat: no bot \(name)"); return }
        selection = .bot(bot.name)
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)  // let the chat view appear
            snapshot("1-selected")
            chat(for: bot).submit(prompt, backend: backend, title: "hba-app-\(Int(Date().timeIntervalSince1970))")
        }
    }

    private func turnEvent(_ type: String, _ chat: ChatModel) {
        let t = Date().timeIntervalSince(started)
        uiLog.append(["t": .number(t), "event": .string(type), "ui_bot_text_chars": .number(Double(chat.streamingText.count)),
                      "ui_delta_count": .number(Double(chat.deltaCount))])
        log("ui \(type) → bubble chars=\(chat.streamingText.count) deltas=\(chat.deltaCount)")
        // Snapshot on the next runloop turn, after SwiftUI applied the change.
        if type == "message.delta" && chat.deltaCount == 1 { DispatchQueue.main.async { self.snapshot("2-streaming") } }
        if type == "message.complete" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshot("3-complete")
                if self.autoQuit { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }

    // MARK: scripted Group Chat evidence

    private var autoRoomState: (sent: Bool, sawWorking: Bool, sawReply: Bool, stopAt: Date?, stopped: Bool, done: Bool) =
        (false, false, false, nil, false, false)
    private var autoActed: Set<String> = []

    private func autoroom() {
        let env = ProcessInfo.processInfo.environment
        if let open = env["HERMES_BOT_APP_OPEN_ROOM"], rooms.contains(where: { $0.roomId == open }) {
            autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
            createdRooms.append(open)
            selection = .room(open)
            autoRoomState.sent = true  // the scripted flow tracks an existing discussion
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); snapshot("r1-room") }
            log("autoroom: opened existing room \(open)")
            return
        }
        guard let spec = env["HERMES_BOT_APP_AUTOROOM"], let bar = spec.firstIndex(of: "|") else { return }
        autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
        let names = spec[..<bar].split(separator: ",").map(String.init)
        let prompt = String(spec[spec.index(after: bar)...])
        let members = names.compactMap { n in bots.first { $0.name == n }.flatMap(RoomMember.forBot) }
        Task {
            // The name embeds the id: a member's first prompt names the room (`[Discussion: "<name>"]`),
            // which is how cleanup attributes sessions that do not carry `Group: <id>` yet.
            let id = AppModel.mintRoomId()
            if let err = await createRoom(name: "hba app \(id)", members: members, roomId: id) {
                log("autoroom: create failed: \(err)"); return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // let the room view appear and poll once
            snapshot("r1-room")
            guard case .room(let id)? = selection, let m = roomModel(id) else { return }
            autoRoomState.sent = m.send(prompt)
            uiLog.append(["t": .number(Date().timeIntervalSince(started)), "event": "ui.send", "accepted": .bool(autoRoomState.sent)])
            log("autoroom: send accepted=\(autoRoomState.sent)")
        }
    }

    private func roomSynced(_ m: RoomModel, _ new: [RoomEvent]) {
        let t = Date().timeIntervalSince(started)
        let d = m.driver
        uiLog.append(["t": .number(t), "event": "room.sync", "room_id": .string(m.room.roomId),
                      "cursor": .number(Double(m.timeline.cursor)), "new_kinds": .array(new.map { .string($0.kind) }),
                      "working": d.map { .bool($0.working) } ?? .null,
                      "counts": .object((d?.counts ?? [:]).mapValues { .number(Double($0)) }),
                      "awaiting_discussion": .bool(m.timeline.awaitingDiscussion),
                      "pending_actions": .array((d?.pendingActions ?? []).map { .string($0.id) }),
                      "ui_lines": .number(Double(m.lines.count)), "next_poll_s": .number(m.pollInterval)])
        if !new.isEmpty || d?.working == true {
            log("ui room.sync cursor=\(m.timeline.cursor) new=\(new.map(\.kind)) working=\(d?.working ?? false) counts=\(d?.counts ?? [:]) lines=\(m.lines.count)")
        }
        guard autoRoomState.sent, !autoRoomState.done, case .room(let id)? = selection, id == m.room.roomId else { return }
        if d?.working == true && !autoRoomState.sawWorking {
            autoRoomState.sawWorking = true
            DispatchQueue.main.async { self.snapshot("r2-working") }
            if let s = ProcessInfo.processInfo.environment["HERMES_BOT_APP_AUTOROOM_STOP_AFTER"].flatMap(Double.init) {
                autoRoomState.stopAt = Date().addingTimeInterval(s)
            }
        }
        if let at = autoRoomState.stopAt, !autoRoomState.stopped, Date() >= at, (d?.counts["running"] ?? 0) > 0 {
            autoRoomState.stopped = true
            log("autoroom: pressing Stop")
            uiLog.append(["t": .number(t), "event": "ui.stop"])
            m.stop()
        }
        let env = ProcessInfo.processInfo.environment
        for action in d?.pendingActions ?? [] where !autoActed.contains(action.id) {
            switch action {
            case .approval(let a):
                guard let choice = env["HERMES_BOT_APP_AUTOROOM_APPROVE"] else { continue }
                autoActed.insert(action.id)
                log("autoroom: approval pending (\(a.command ?? "?")) → pressing \(choice)")
                // HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>: leave the card on screen that long first, so
                // the snapshot shows it at rest rather than mid-arrival with the buttons already busy.
                if let after = env["HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER"].flatMap(Double.init), after > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        self.snapshot("r-approval-pending")
                        self.uiLog.append(["t": .number(Date().timeIntervalSince(self.started)), "event": "ui.approve",
                                           "choice": .string(choice), "request_id": .string(a.requestId)])
                        m.approve(a, choice: choice)
                    }
                    continue
                }
                snapshot("r-approval-pending")
                uiLog.append(["t": .number(t), "event": "ui.approve", "choice": .string(choice), "request_id": .string(a.requestId)])
                m.approve(a, choice: choice)
            case .retry(let taskId):
                guard env["HERMES_BOT_APP_AUTOROOM_RETRY"] == "1" else { continue }
                autoActed.insert(action.id)
                log("autoroom: retry pending (\(taskId)) → pressing Retry")
                snapshot("r-retry-pending")
                uiLog.append(["t": .number(t), "event": "ui.retry", "task_id": .string(taskId)])
                m.retry(taskId)
            case .other: continue
            }
        }
        if new.contains(where: { $0.kind == "message.member" }) && !autoRoomState.sawReply {
            autoRoomState.sawReply = true
            DispatchQueue.main.async { self.snapshot("r3-first-reply") }
        }
        if autoRoomState.stopped && new.contains(where: { $0.kind == "turn.cancelled" }) {
            DispatchQueue.main.async { self.snapshot("r4-stopped") }
        }
        let pendingLeft = !(d?.pendingActions.isEmpty ?? true)
        if !m.active && !pendingLeft && m.timeline.userMessages.count > 0 && (autoRoomState.sawWorking || autoRoomState.sawReply) {
            autoRoomState.done = true
            log("autoroom: settled (working=false, discussion \(m.timeline.userMessages.last.map { "\(m.timeline.phase(of: $0))" } ?? "?"))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshot("r5-settled")
                if self.autoQuit { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }

    /// Window image as composited by the window server (`screencapture -l`), so the sidebar material and
    /// the unified toolbar show as they do on screen; `cacheDisplay` (no material, no toolbar) is the
    /// fallback when the capture fails.
    func snapshot(_ name: String) {
        guard let dir = evidenceDir, let window = NSApp.windows.first(where: \.isVisible), let view = window.contentView else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        var how = "screencapture"
        var captured = false
        if (try? capture.run()) != nil {
            capture.waitUntilExit()
            captured = capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        }
        if !captured {
            how = "cacheDisplay"
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        log("snapshot → \(url.lastPathComponent) via \(how) (bubble chars=\(chats[selectedBot ?? ""]?.streamingText.count ?? 0))")
    }

    private func writeEvidence() {
        guard let dir = evidenceDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc: JSONValue = ["mode": .string(modeText), "bots": .array(bots.map { .string($0.name) }),
                              "ui_events": .array(uiLog),
                              "final_bot_text": .string(chats[selectedBot ?? ""]?.streamingText ?? ""),
                              "rooms_created": .array(createdRooms.map(JSONValue.string))]
        try? doc.compactJSON().write(to: dir.appendingPathComponent("ui-log.json"), atomically: true, encoding: .utf8)
    }
}

// MARK: - views
//
// Layout and tokens: DESIGN.md. Window = native split view: sidebar (system material, Group Chats then
// Bots) + detail with the unified toolbar.

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarWidth, max: DS.Size.sidebarMax)
        } detail: {
            detail
                .frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.window)
        }
        .frame(minWidth: DS.Size.windowMinWidth, minHeight: DS.Size.windowMinHeight)
        .tint(DS.Palette.primary)
        .task { await model.connect() }
        .task(id: model.bots.map(\.name)) { AvatarStore.shared.load(bots: model.bots, backend: model.backend) }
        // Not `.sheet`: its slide and dimmer fade ignore the motion gate (MotionSheet.swift).
        .motionSheet(isPresented: $model.showCreateRoom, motion: motion) {
            CreateRoomView(bots: model.bots,
                           onCreate: { name, members in await model.createRoom(name: name, members: members) },
                           onClose: { model.showCreateRoom = false })
        }
    }

    /// The incoming pane fades in from 12 pt right; the outgoing one leaves at once, so switching never
    /// waits on an animation.
    private var paneTransition: AnyTransition {
        motion ? .asymmetric(insertion: .opacity.combined(with: .offset(x: DS.Motion.paneOffset)), removal: .identity) : .identity
    }

    @ViewBuilder private var detail: some View {
        ZStack {
            if let name = model.selectedBot, let bot = model.bots.first(where: { $0.name == name }) {
                BotChatView(chat: model.chat(for: bot), backend: model.backend)
                    .id(name).transition(paneTransition)
            } else if case .room(let id)? = model.selection, let room = model.roomModel(id) {
                RoomView(model: room).id(id).transition(paneTransition)
            } else {
                placeholder.transition(.opacity)
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .connecting:
            EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "Connecting to Hermes",
                           message: "Looking for a running Hermes backend first. A private hermes serve starts only if none is running.") {
                ProgressView().controlSize(.small)
            }
            .navigationTitle("Hermes Bot")
        case .failed(let e):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't reach Hermes", message: e) {
                Button("Try Again") { Task { await model.connect() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
            .navigationTitle("Hermes Bot")
        case .connected:
            EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "Pick a bot or a group chat",
                           message: model.bots.count >= 2 && model.groupsAvailable
                               ? "Chat 1:1 with one bot, or put 2 to 6 bots in a group chat that answers in turns."
                               : "Chat 1:1 with a bot from the sidebar.") {
                if model.bots.count >= 2 && model.groupsAvailable {
                    Button("New Group Chat") { model.showCreateRoom = true }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            .navigationTitle("Hermes Bot")
        }
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var avatars = AvatarStore.shared
    @Namespace private var selectionSpace
    @FocusState private var focused: Bool
    @Environment(\.motionEnabled) private var motion

    private var order: [SidebarItem] { model.rooms.map { .room($0.roomId) } + model.bots.map { .bot($0.name) } }

    var body: some View {
        VStack(spacing: 0) {
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
                    ForEach(model.rooms) { room in
                        row(.room(room.roomId)) { roomRow(room) }
                    }
                    sectionHeader("Bots") { EmptyView() }
                    if model.bots.isEmpty {
                        Text(model.phase.isConnected ? "No profiles found" : "Not loaded yet")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    }
                    ForEach(model.bots) { bot in
                        row(.bot(bot.name)) { botRow(bot) }
                    }
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

    private func roomRow(_ room: RoomSummary) -> some View {
        HStack(spacing: DS.Space.gutter) {
            RoomAvatarStack(identities: room.members.map { avatars.identity(profile: $0.profile, title: $0.title) })
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                Text(room.name).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text("\(room.members.count) bots · " + room.members.map { "@\($0.handle)" }.joined(separator: " "))
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let m = model.roomModels[room.roomId] { RoomLiveDot(model: m) }
        }
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
        withDSAnimation(motion) { model.selection = item }
    }

    /// Up/down arrows move the selection through rooms then bots (the sidebar is focusable).
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

extension AppModel.Phase {
    var isConnected: Bool { if case .connected = self { return true }; return false }
}

// MARK: - bot chat

struct BotChatView: View {
    @ObservedObject var chat: ChatModel
    let backend: Backend?
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    /// Persisted inspector visibility. The inspector binds to the @State copy below: an @AppStorage write
    /// reaches the view outside the toggle's transaction, so the no-animation path still slid the panel.
    @AppStorage("hba.botInspector") private var storedInspector = true
    @State private var showInspector = UserDefaults.standard.object(forKey: "hba.botInspector") as? Bool ?? true
    @Environment(\.motionEnabled) private var motion

    private var identity: BotIdentity { avatars.identity(profile: chat.bot.name, title: chat.bot.title) }

    var body: some View {
        VStack(spacing: 0) {
            if chat.lines.isEmpty {
                emptyChat
            } else {
                transcript
            }
            composer
        }
        // The chat column takes the width the sidebar and inspector leave. Any intrinsic minimum here is
        // inflated by the inspector split (on top of the sidebar inset) and widens it past the window,
        // clipping the inspector at the 820 pt minimum (InspectorLayoutTests).
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(DS.Palette.window)
        .navigationTitle(chat.bot.title)
        .navigationSubtitle("@\(chat.bot.name)" + (chat.bot.model.map { " · \($0)" } ?? ""))
        .toolbar {
            ToolbarItem(placement: .navigation) { AvatarView(identity: identity, size: DS.Size.avatarHero) }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // System inspector animation with motion on; a no-animation transaction with it off.
                    if motion { showInspector.toggle() } else { withDSAnimation(false) { showInspector.toggle() } }
                } label: { Label("Bot Details", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show or hide bot details (⌥⌘I)")
            }
        }
        .inspector(isPresented: $showInspector) {
            BotInspector(bot: chat.bot, identity: identity)
                .inspectorColumnWidth(min: DS.Size.inspectorMin, ideal: DS.Size.inspectorWidth, max: DS.Size.inspectorMax)
        }
        .onChange(of: showInspector) { _, shown in storedInspector = shown }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.timeline) {
                    ForEach(chat.lines) { line in
                        bubble(line).id(line.id)
                            .transition(motion ? .arrive(from: line.role == .user ? .bottomTrailing : .bottomLeading) : .identity)
                    }
                }
                .padding(.horizontal, DS.Space.s5).padding(.top, DS.Space.s4).padding(.bottom, DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion ? DS.Motion.spring : nil, value: chat.lines.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.lines.last?.text) { _, _ in
                if let id = chat.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// `empty-state` (new 1:1 chat variant): centred in the pane, the bot's own avatar instead of a symbol.
    /// No `.fixedSize(vertical:)` on these texts (unlike text inside a ScrollView): the split view measures
    /// the pane at a near-zero width, where a fixed-height text wraps one glyph per line and becomes the
    /// whole window's minimum height, pushing the sidebar, the inspector and the composer off screen
    /// (BotChatLayoutTests).
    private var emptyChat: some View {
        VStack(spacing: DS.Space.s3) {
            AvatarView(identity: identity, size: DS.Size.avatarEmpty)
                .padding(.bottom, DS.Space.s1)
            Text("Chat with \(chat.bot.title)").font(DS.Typeface.titleState).foregroundStyle(DS.Palette.ink)
            if let d = chat.bot.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                Text(d).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DS.Size.proseNarrow)
            }
            Text(ProcessInfo.processInfo.environment["HERMES_BOT_APP_KEEP_SESSIONS"] == "1"
                 ? "Separate from group chats. The session is kept when the app quits."
                 : "Separate from group chats. The session is deleted when the app quits.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Size.proseNarrow)
        }
        .padding(DS.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            // Return goes through `send()` too (`.onSubmit` ignores the Button's disabled state), so
            // the gate lives in `send()`/`ChatModel.submit`, not in `.disabled`.
            ComposerBox(placeholder: "Message \(chat.bot.title)", draft: $draft, canSend: canSend,
                        onSend: send, focus: $composerFocused)
            HStack(spacing: DS.Space.s3) {
                KeyHint(keys: "Return", label: "send")
                Spacer()
                if chat.busy {
                    HStack(spacing: DS.Space.s2) {
                        WorkingDots(color: identity.nameColor)
                        Text("\(chat.bot.title) is replying").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    }
                    .transition(.opacity)
                }
            }
            .animation(motion ? DS.Motion.ease : nil, value: chat.busy)
        }
        .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
    }

    private var canSend: Bool {
        backend != nil && !chat.busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clears the draft only when the model accepted it: Return while a turn runs keeps the draft.
    private func send() {
        guard let backend else { return }
        if chat.submit(draft, backend: backend, title: "hba-app-\(Int(Date().timeIntervalSince1970))") { draft = "" }
    }

    @ViewBuilder private func bubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .user:
            UserBubble(text: line.text, time: 0)
        case .bot:
            MemberMessage(identity: identity, author: chat.bot.title, time: 0,
                          trailingNote: line.interim ? "interim" : (line.streaming ? "streaming" : nil)) {
                StreamingText(text: line.text, streaming: line.streaming, caret: identity.color)
            }
        case .error:
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.iconSmall)
                Text(line.text).textSelection(.enabled)
            }
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .padding(.leading, DS.Size.contentInset)
        }
    }
}

/// Streamed reply: grows with an opacity content transition and a blinking caret in the bot colour while
/// `streaming`; settles to `MessageBody` (markdown + code) when the turn completes.
struct StreamingText: View {
    let text: String
    let streaming: Bool
    let caret: Color
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        if streaming {
            HStack(alignment: .lastTextBaseline, spacing: DS.Space.s0 / 2) {
                Text(text.isEmpty ? " " : text)
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.proseLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(motion ? DS.Motion.stream : nil, value: text)
                Caret(color: caret)
            }
        } else {
            MessageBody(text: text)
        }
    }
}

struct Caret: View {
    let color: Color
    @Environment(\.motionEnabled) private var motion
    var body: some View {
        Group {
            if motion {
                PhaseAnimator([true, false]) { on in
                    RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(color).opacity(on ? 1 : 0)
                } animation: { _ in .linear(duration: DS.Motion.caretBlink) }
            } else {
                RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(color)
            }
        }
        .frame(width: DS.Size.caret.width, height: DS.Size.caret.height)
        .accessibilityHidden(true)
    }
}

/// Native inspector: identity header (name, @handle, a "Default profile" tag when it is the default),
/// then About / Model / Provider / Skills. The handle already names the profile, so there is no separate
/// Profile field repeating it.
struct BotInspector: View {
    let bot: Bot
    let identity: BotIdentity
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                HStack(alignment: .top, spacing: DS.Space.s3) {
                    AvatarView(identity: identity, size: DS.Size.avatarInspector)
                    VStack(alignment: .leading, spacing: DS.Space.s0) {
                        Text(bot.title).font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink).lineLimit(1)
                        Text("@\(bot.name)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                        if bot.isDefault { DefaultTag(text: "Default profile").padding(.top, DS.Space.s0) }
                    }
                }
                Hairline()
                if let d = bot.description, !d.isEmpty { field("About", d) }
                field("Model", bot.model ?? "Not set in profile")
                if let p = bot.provider { field("Provider", p) }
                if let n = bot.skillCount { field("Skills", "\(n)") }
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s0) {
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            Text(value).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small neutral tag for the default profile (sidebar row, inspector).
struct DefaultTag: View {
    var text = "default"
    var body: some View {
        Text(text).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            .padding(.horizontal, DS.Space.s1 + DS.Space.s0 / 2).padding(.vertical, DS.Space.s0 / 2)
            .background(DS.Palette.selected, in: RoundedRectangle(cornerRadius: DS.Radius.inline, style: .continuous))
    }
}

// MARK: - settings

struct SettingsView: View {
    @AppStorage(DS.Motion.settingKey) private var motion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Form {
            Toggle("Animate interface changes", isOn: $motion)
            Text(reduceMotion
                 ? "Reduce Motion is on in System Settings, so animations stay off."
                 : "New messages, turn status changes and approvals animate once. Reduce Motion in System Settings also turns this off.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: DS.Size.settingsWidth)
    }
}
