import AppKit
import HermesGatewayKit
import SwiftUI

/// One bot's canonical "Bot Chat" (shared with Hermes Desktop) for the app's life. UI wrapper around
/// `ChatTranscript` (HermesGatewayKit), which owns the submit gate and the turn settling rules.
///
/// Lifecycle: `open()` runs when the bot is selected (resume, or create on confirmed absence), seeds the
/// transcript from the history and re-shows requests still open. `close()` only detaches: the chat lives
/// on in Hermes (no `session.close` / `session.delete`).
/// Slash commands: ChatModel+Slash.swift. Attachments and server requests: ChatModel+Requests.swift.
/// Queue and steering (B8): ChatModel+Queue.swift. Model, effort and context usage (B7, B9): ChatModel+Controls.swift.
@MainActor
final class ChatModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    /// Replaced when the roster is re-listed after an edit (title, description, model).
    @Published var bot: Bot
    @Published private(set) var phase: Phase = .idle
    @Published var transcript = ChatTranscript()
    /// The composer text. Owned here so it survives switching bots, and so `/undo`-style prefill can set it.
    /// Kept across launches per bot (B12, `drafts`), except while it holds a queued message being edited.
    @Published var draft = "" {
        didSet { if draft != oldValue, editingQueueId == nil { drafts?.save(draft, for: bot.name) } }
    }
    /// B12: where drafts persist (UserDefaults in the app; nil in tests unless one injects a suite).
    let drafts: ChatDraftStore?
    /// B12: ↑/↓ prompt history browsing state (ChatModel+Composer.swift).
    var history = PromptHistory()
    /// B1: the roster @mentions resolve against (the app's bots; set by AppModel, empty by default).
    var roster: @MainActor () -> [Bot] = { [] }
    /// Files picked, dropped or pasted, staged on the session until the next send.
    @Published var pending: [PendingAttachment] = []
    /// Server→client requests waiting on the user (cards above the composer), in arrival order.
    @Published var requests: [ServerRequest] = []
    /// Requests whose answer is in flight, and the last answer error per request id.
    @Published var answering: Set<String> = []
    @Published var requestErrors: [String: String] = [:]
    /// `commands.catalog`, fetched once per chat (after open); nil until loaded.
    @Published var catalog: SlashCatalog?
    /// A client-side action in flight (slash command, compaction), shown in the composer status row.
    @Published var activity: String? {
        // A queued message held back by the action goes out once it ends.
        didSet { if activity == nil, oldValue != nil { scheduleDrain() } }
    }
    /// Hermes reclaimed the live session and the kit is re-resuming it (`session.reclaimed` until
    /// `.resumed` or an error): nothing is sent meanwhile.
    @Published private(set) var reconnecting = false

    /// Messages waiting for the running turn to end (⌘Return, or a correction the turn refused), in send
    /// order. Sent one at a time whenever the chat is idle, unless `queueParked`.
    @Published var queue: [QueuedMessage] = []
    /// Stop paused the queue: entries wait until Resume, Send now or a steer.
    @Published var queueParked = false
    /// The queued message being edited in the composer (its text is the draft meanwhile).
    @Published var editingQueueId: UUID?
    /// The composer draft from before Edit, restored when the edit is saved or cancelled.
    var draftBeforeEdit = ""
    /// Fallback drain after `message.complete` / `error` when no `session.info running:false` follows.
    var drainTask: Task<Void, Never>?
    var drainFallbackDelay: UInt64 = 1_000_000_000

    /// The model, provider and effort the chat runs (`session.info`, optimistic while a pick is in flight).
    @Published var modelInfo: SessionInfoSnapshot?
    /// `model.options` for this chat; nil until loaded.
    @Published var modelCatalog: ModelCatalog?
    /// An expensive model pick waiting for the user's confirmation.
    @Published var modelConfirm: ModelConfirm?
    /// Context window occupancy (`session.info.usage`, `session.usage`, `message.complete.usage`).
    @Published var contextUsage: ContextUsage?
    @Published var contextBreakdown: ContextBreakdown?
    @Published var breakdownLoading = false
    /// Hermes is compacting the conversation (`status.update compacting|compressing` until it resumes or ends).
    @Published var compacting = false

    private(set) var session: (any ChatSessionLink)?
    private let opener: ChatOpener
    private var openTask: Task<Void, Never>?
    var catalogTask: Task<SlashCatalog?, Never>?
    /// Client-side checks for a picked file (tests inject a fake; production stats the file).
    var checkFile: (URL) throws -> ChatAttachments.Checked = { try ChatAttachments.check($0) }
    /// Pasted images sent with the running turn: deleted once it settles (the backend reads them during it).
    var sentTemporaryFiles: [URL] = []
    /// Pasted images of a `queued` send: the queued turn reads them only when it runs, after the current
    /// turn, so they are kept until `close()` (or the app's quit purge).
    var queuedTemporaryFiles: [URL] = []
    /// The pasted-image folder whose files this chat owns and deletes (tests inject a temp folder).
    var pasteFolder = PasteboardAttachments.folder
    /// How long Stop waits for the turn to settle (`message.complete` / `error`) before settling it locally.
    var stopSettleDelay: UInt64 = 5_000_000_000
    /// Approval cards already reported with `approval.received` (once per request id).
    var acknowledged: Set<String> = []
    private(set) var closed = false
    var onTurnEvent: ((String, ChatModel) -> Void)?
    var log: (String) -> Void = { AppModel.shared.log($0) }

    var lines: [ChatLine] { transcript.lines }
    var busy: Bool { transcript.busy }
    var deltaCount: Int { transcript.deltaCount }
    var streamingText: String { transcript.lastBotText }
    var isReady: Bool { phase == .ready }

    init(bot: Bot, opener: @escaping ChatOpener, drafts: ChatDraftStore? = nil) {
        self.bot = bot
        self.opener = opener
        self.drafts = drafts
        draft = drafts?.draft(for: bot.name) ?? ""
    }

    // MARK: - open / close

    /// Opens the chat once (no-op while loading or open). Also the Retry action after `.failed`.
    func open() {
        switch phase {
        case .loading, .ready: return
        case .idle, .failed: break
        }
        guard !closed else { return }
        phase = .loading
        let opener = opener, bot = bot
        openTask = Task {
            do {
                let s = try await opener(bot)
                guard !self.closed else { s.detach(); return }
                self.adopt(s)
            } catch {
                guard !self.closed else { return }
                let msg = Self.message(error, bot: bot)
                self.log("bot chat open failed: profile=\(bot.name): \(msg)")
                self.phase = .failed(msg)
            }
        }
    }

    private func adopt(_ s: any ChatSessionLink) {
        session = s
        // FIFO onto the main actor: one Task per event would not guarantee delta order.
        s.onEvent { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(e) } } }
        transcript.seed(history: s.history)
        // Mid-turn (Desktop or an earlier launch is running a reply): join it with the gate closed, so a
        // send here cannot redirect-interrupt that turn.
        if let t = s.inflight { transcript.resumeRunningTurn(t) }
        for r in s.openRequests { receive(r) }
        modelInfo = s.openInfo
        contextUsage = s.openInfo?.usage
        phase = .ready
        log("bot chat opened: profile=\(bot.name) session_id=\(s.sessionId) stored=\(s.storedSessionId) "
            + "history=\(s.history.count) open_requests=\(s.openRequests.count) running=\(s.inflight != nil)")
        loadCatalog()
        loadModelOptions()
        if contextUsage == nil { refreshUsage() }
        drainQueue()
    }

    /// Detach only: the canonical chat stays in Hermes for Hermes Desktop and the next launch.
    func close() {
        closed = true
        openTask?.cancel()
        catalogTask?.cancel()
        drainTask?.cancel()
        session?.detach()
        session = nil
        // Chips are local (never staged before a send); only pasted image files need cleaning up, including
        // those of sends still running or queued (detached, this chat no longer learns when they are read).
        let queuedFiles = queue.flatMap { $0.attachments.map(\.url) }
        PasteboardAttachments.delete(pending.map(\.url) + sentTemporaryFiles + queuedTemporaryFiles + queuedFiles,
                                     folder: pasteFolder)
        pending = []
        queue = []
        sentTemporaryFiles = []
        queuedTemporaryFiles = []
    }

    /// User-facing, token-free text for an open/send failure.
    static func message(_ error: Error, bot: Bot) -> String {
        // 4090 SESSION_NOT_OWNED: another backend process holds the chat's lease (`methods_prompt.py:774-777`).
        if let e = error as? GatewayClient.RPCError, e.code == 4090 {
            return BotChatError.sessionNotOwned(bot: bot.title).description
        }
        return Redaction.describe(error)
    }

    // MARK: - send

    /// What the composer's Send button mirrors (the same rules as `submit`).
    var canSend: Bool {
        guard isReady, !reconnecting else { return false }
        switch SlashInvocation.classify(draft, canonical: session?.isCanonical ?? true) {
        case .compress: return !busy && activity == nil  // `runSlash` refuses compacting mid-turn
        case .exec: return activity == nil
        case .stop, .help, .unavailable: return true
        case nil: break
        }
        guard activity == nil, !busy, !pending.contains(where: \.isSending) else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending.contains(where: \.isReady)
    }

    /// Synchronous submit gate for the composer (Return / Send). Returns true only when the draft was
    /// accepted (it is cleared then); false while a turn or a client action (`activity`) runs, while a
    /// reclaimed session is being reopened, before the chat is open, or for blank input, with nothing
    /// sent or changed. Slash commands are handled client-side first (`SlashInvocation`).
    /// Ready chips are staged and the prompt submitted in ONE task (`ChatSessionLink.submit`); refused chips
    /// stay with their error and are not sent. On failure the draft and the chips come back.
    @discardableResult
    func submit() -> Bool {
        guard phase == .ready, !reconnecting, let s = session else { return false }
        if let inv = SlashInvocation.classify(draft, canonical: s.isCanonical) {
            return runSlash(inv)
        }
        guard activity == nil, !pending.contains(where: \.isSending) else { return false }
        let chips = pending.filter(\.isReady)
        let files = chips.compactMap(\.checked)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.beginTurn(Self.displayText(text, names: chips.map(\.name))) != nil else { return false }
        let typed = draft
        let prompt = modelText(text)
        draft = ""
        history.reset()
        setChips(chips.map(\.id)) { _ in .sending }
        Task {
            do {
                let r = try await s.submit(prompt, files: files)
                self.sent(chips, status: r["status"]?.string)
            } catch {
                self.sendFailed(error, chips: chips, draft: typed)
            }
        }
        return true
    }

    /// The user line for a turn: the text, plus the attached file names (attachments carry no text of
    /// their own; file refs are model-facing only).
    nonisolated static func displayText(_ text: String, names: [String]) -> String {
        guard !names.isEmpty else { return text }
        let line = "Attached: " + names.joined(separator: ", ")
        return text.isEmpty ? line : text + "\n\n" + line
    }

    /// Submits model-facing `message` as a turn shown as `display` (slash `send` / `skill` directives).
    /// Composer chips are not involved: they stay local for the user's own next send.
    func sendDirect(_ message: String, display: String) {
        guard let s = session else { return }
        guard !reconnecting else {
            transcript.appendSystem("The Bot Chat is reconnecting; run the command again in a moment.")
            return
        }
        guard transcript.beginTurn(display) != nil else {
            transcript.appendSystem("A reply is still running; run the command again when it finishes.")
            return
        }
        Task {
            do {
                let r = try await s.submit(message, files: [])
                self.noteSubmitStatus(r["status"]?.string)
            } catch { self.failSend(error) }
        }
    }

    func sent(_ chips: [PendingAttachment], status: String?) {
        let ids = Set(chips.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        let pasted = chips.map(\.url).filter { PasteboardAttachments.isPasted($0, folder: pasteFolder) }
        // `queued`: the images ride the queued envelope and are read when that turn runs, later than the
        // current turn's end. `steered` / `redirected` never carry images (the backend only steers text-only
        // payloads; with images queued it answers `queued`, `session_auto_continue.py` `_handle_busy_submit`),
        // so any other status means this turn has read them by the time it settles.
        if status == "queued" {
            queuedTemporaryFiles += pasted
        } else if busy {
            sentTemporaryFiles += pasted
        } else {
            PasteboardAttachments.delete(pasted, folder: pasteFolder)  // the turn already settled before the submit reply
        }
        log("prompt.submit → status=\(status ?? "?") attachments=\(chips.count)")
        noteSubmitStatus(status)
    }

    /// `prompt.submit` did not start a fresh turn (`contracts/prompt_voice.py:62-76`): say what happened.
    func noteSubmitStatus(_ status: String?) {
        if let note = Self.submitNote(status, bot: bot.title) { transcript.appendSystem(note) }
    }

    static func submitNote(_ status: String?, bot: String) -> String? {
        switch status {
        case "queued": return "\(bot) is still replying elsewhere; your message is queued and runs next."
        case "steered": return "Your message was added as guidance to the reply \(bot) is already writing."
        case "redirected": return "\(bot)'s running reply was redirected to your message."
        default: return nil
        }
    }

    /// Nothing stays staged (the kit rolled back); the chips and the draft come back for another try, the
    /// chip that failed with its error.
    private func sendFailed(_ error: Error, chips: [PendingAttachment], draft typed: String) {
        let failedIndex = (error as? ChatAttachments.StageFailure)?.index
        let failedId = failedIndex.flatMap { chips.indices.contains($0) ? chips[$0].id : nil }
        setChips(chips.map(\.id)) { id in
            id == failedId ? .failed((error as? ChatAttachments.StageFailure)?.message ?? "") : .ready
        }
        if draft.isEmpty { draft = typed }
        // The draft comes back, so the unsent user line goes (a resend would otherwise show it twice).
        let msg = Self.message(error, bot: bot)
        log("send failed: \(msg)")
        transcript.retractUnsent(msg)
    }

    private func setChips(_ ids: [UUID], _ state: (UUID) -> PendingAttachment.State) {
        for i in pending.indices where ids.contains(pending[i].id) { pending[i].state = state(pending[i].id) }
    }

    private func failSend(_ error: Error) {
        let msg = Self.message(error, bot: bot)
        log("send failed: \(msg)")
        transcript.fail(msg)
    }

    /// Stop: decline the requests this turn is waiting on ("session interrupted", like Desktop), then
    /// `session.interrupt`. An explicit Stop also pauses the queue (`queueParked`), as Desktop parks it;
    /// Send now interrupts without pausing, so the settle sends the promoted message.
    func stop(parkQueue: Bool = true) {
        guard let s = session else { return }
        if parkQueue && !queue.isEmpty { queueParked = true }
        let open = requests
        dropRequests { _ in true }
        let serial = transcript.turnSerial
        Task {
            for r in open {
                try? await s.decline(r, code: ServerRequest.interruptedCode, message: "session interrupted")
            }
            do { try await s.interrupt() } catch {
                self.transcript.appendSystem("Stop failed: \(Self.message(error, bot: self.bot))")
                return
            }
            // A turn joined from a snapshot or started elsewhere may never deliver its settling event here
            // (missed before we attached): settle it locally so the gate reopens.
            try? await Task.sleep(nanoseconds: self.stopSettleDelay)
            guard self.busy, self.transcript.turnSerial == serial else { return }
            self.log("stop: no settling event after interrupt; settling the turn locally")
            self.transcript.abandon("Stopped.")
            self.turnSettled()
        }
    }

    // MARK: - events

    func apply(_ e: ChatEvent) {
        let wasBusy = busy
        transcript.apply(e)
        compacting = CompactionPhase.next(compacting, after: e)
        switch e {
        case .started: onTurnEvent?("message.start", self)
        case .delta: onTurnEvent?("message.delta", self)
        case .interim: onTurnEvent?("message.interim", self)
        case .completed(let c):
            turnSettled()
            if let u = c.usage { contextUsage = u } else if wasBusy { refreshUsage() }
            scheduleDrain()
            onTurnEvent?("message.complete", self)
        case .idle:
            turnSettled()
            drainQueue()
        case .error, .disconnected:
            if case .disconnected = e { dropRequests { _ in true } }
            reconnecting = false
            turnSettled()
            if case .error = e { scheduleDrain() }
            onTurnEvent?("turn.failed", self)
        case .info(let info):
            modelInfo = info
            if let u = info.usage { contextUsage = u }
        case .usage(let u):
            contextUsage = u
        case .status(let kind, _) where kind == "compacted" || kind == "ready":
            refreshUsage()
        case .request(let r): receive(r)
        case .requestCancelled(let id, _): dropRequests { $0.id == id }
        case .approvalsCancelled(let ids):
            dropRequests { r in
                guard case .approval(let a) = r.kind, let q = a.requestId else { return false }
                return ids.contains(q)
            }
        case .other("session.reclaimed"):
            // The old runtime's requests and running turn are gone; the re-resume re-shows open requests.
            dropRequests { _ in true }
            reconnecting = true
            if busy { transcript.fail("Hermes closed the live session; reopening the Bot Chat.") }
        case .resumed(let history, let inflight):
            reconnecting = false
            // Same path as `adopt`: the new reply's history, then its running turn (gate closed).
            transcript.seed(history: history)
            if let inflight { transcript.resumeRunningTurn(inflight) }
            log("bot chat re-resumed after reclaim: session_id=\(session?.sessionId ?? "?") "
                + "history=\(history.count) running=\(inflight != nil)")
            drainQueue()
        default: break
        }
    }

    /// The turn that carried pasted images is over: the backend has read them, so they go.
    func turnSettled() {
        guard !busy, !sentTemporaryFiles.isEmpty else { return }
        PasteboardAttachments.delete(sentTemporaryFiles, folder: pasteFolder)
        sentTemporaryFiles = []
    }
}
