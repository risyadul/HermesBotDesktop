import Foundation
import HermesGatewayKit

/// A message waiting for the running turn to end (roadmap B8). Kept by `ChatModel` for the app's life, so
/// it survives switching bots; files ride along as their local chips and are staged only when it is sent.
struct QueuedMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var attachments: [PendingAttachment]

    /// The row text in the queue panel: the message, plus its file names.
    var preview: String { ChatModel.displayText(text, names: attachments.map(\.name)) }
}

/// What Return and the composer's primary button do right now.
enum ComposerAction: Equatable {
    /// Start a turn (idle), or run a slash command.
    case send
    /// Redirect the running turn to the draft (`session.redirect`).
    case steer
    /// Hold the draft until the running turn ends.
    case queue
    /// Write the draft back into the queued message being edited.
    case saveEdit
}

/// Queue and steering while the bot is busy (B8), modelled on Hermes Desktop's composer queue
/// (`use-composer-queue.ts`, `use-prompt-actions` `steer`): Return steers the running turn, ⌘Return queues;
/// queued messages go out one at a time whenever the chat is idle; Stop pauses the queue; a correction the
/// turn refuses lands in the queue, so nothing typed is lost.
extension ChatModel {
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var draftIsSlash: Bool {
        SlashInvocation.classify(draft, canonical: session?.isCanonical ?? true) != nil
    }

    /// A correction can reach the running turn: a turn this client started (a reply Hermes Desktop or an
    /// earlier launch is running is never redirected from here; Return queues instead), text only.
    var canSteerTurn: Bool { busy && transcript.turnIsLocal && !pending.contains(where: \.isReady) }

    var composerAction: ComposerAction {
        if editingQueueId != nil { return .saveEdit }
        guard busy, !draftIsSlash else { return .send }
        return canSteerTurn ? .steer : .queue
    }

    /// The draft can be held: text or ready files, no file being staged, not a slash command (those run now).
    var canQueue: Bool {
        guard isReady, !draftIsSlash, !pending.contains(where: \.isSending) else { return false }
        return !trimmedDraft.isEmpty || pending.contains(where: \.isReady)
    }

    /// Whether the primary button (and Return) does anything now; mirrors `primaryAction`.
    var canPrimary: Bool {
        switch composerAction {
        case .send: return canSend
        case .steer: return isReady && !reconnecting && !trimmedDraft.isEmpty
        case .queue: return canQueue
        case .saveEdit: return true
        }
    }

    /// Return / the primary button.
    @discardableResult
    func primaryAction() -> Bool {
        switch composerAction {
        case .send: return submit()
        case .steer: return steer()
        case .queue: return enqueueDraft()
        case .saveEdit: return saveQueueEdit()
        }
    }

    /// ⌘Return: queue while a reply runs, send when idle (a slash command always runs now).
    @discardableResult
    func queueOrSend() -> Bool {
        if editingQueueId != nil { return saveQueueEdit() }
        guard busy, !draftIsSlash else { return submit() }
        return enqueueDraft()
    }

    // MARK: steer

    /// Sends the draft to the running turn with `session.redirect`. The user line is recorded first (the
    /// redirect's events can race its reply); `redirected` keeps it, `queued` (turn still building, or a
    /// compaction in flight) keeps it with a note, and a refusal or failure takes the line back and queues
    /// the text instead.
    @discardableResult
    func steer() -> Bool {
        guard isReady, !reconnecting, canSteerTurn, let s = session else { return false }
        let text = trimmedDraft
        guard let lineId = transcript.redirect(text) else { return false }
        let prompt = modelText(text)
        draft = ""
        history.reset()
        Task {
            do {
                let status = try await s.redirect(prompt)
                self.log("session.redirect → status=\(status)")
                guard self.isLive(s) else { return }
                switch status {
                case "redirected": break
                case "queued": self.transcript.appendSystem(Self.steerQueuedNote(bot: self.bot.title))
                default: self.steerRefused(lineId, text: text)
                }
            } catch {
                self.log("session.redirect failed: \(Self.message(error, bot: self.bot))")
                guard self.isLive(s) else { return }
                self.steerRefused(lineId, text: text)
            }
        }
        return true
    }

    nonisolated static func steerQueuedNote(bot: String) -> String {
        "\(bot) will read your message when the current step finishes."
    }

    private func steerRefused(_ lineId: UUID, text: String) {
        transcript.retract(lineId)
        queue.append(QueuedMessage(text: text, attachments: []))
        drainQueue()
    }

    // MARK: queue

    /// Moves the draft and its ready files into the queue (they leave the composer). Sends at once when idle.
    @discardableResult
    func enqueueDraft() -> Bool {
        guard canQueue else { return false }
        let chips = pending.filter(\.isReady)
        let ids = Set(chips.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        queue.append(QueuedMessage(text: trimmedDraft, attachments: chips))
        draft = ""
        history.reset()
        drainQueue()
        return true
    }

    /// Sends the first queued message (skipping one being edited) when the chat is idle and the queue is not
    /// paused. One at a time: the turn it starts closes the gate until it settles, then the next follows.
    func drainQueue() {
        guard isReady, !reconnecting, !busy, !queueParked, activity == nil, let s = session,
              let entry = queue.first(where: { $0.id != editingQueueId }) else { return }
        let display = Self.displayText(entry.text, names: entry.attachments.map(\.name))
        let prompt = promptText(entry.text, chips: entry.attachments)
        guard transcript.beginTurn(display, prompt: prompt) != nil else { return }
        queue.removeAll { $0.id == entry.id }
        let files = entry.attachments.compactMap(\.checked)
        Task {
            do {
                let r = try await s.submit(prompt, files: files)
                guard self.isLive(s) else { return self.releaseAfterClose(entry.attachments) }
                self.bindUserRow(r)
                self.sent(entry.attachments, status: r["status"]?.string)
            } catch {
                // Back to the head of the queue, paused, so a failing send cannot loop.
                let msg = Self.message(error, bot: self.bot)
                self.log("queued send failed: \(msg)")
                guard self.isLive(s) else { return self.releaseAfterClose(entry.attachments) }
                self.transcript.retractUnsent(msg)
                self.queue.insert(entry, at: 0)
                self.queueParked = true
            }
        }
    }

    /// After `message.complete` / `error` the backend may still be closing the turn; `session.info
    /// running:false` drains at once, this is the fallback when it does not come.
    func scheduleDrain() {
        guard !queue.isEmpty else { return }
        drainTask?.cancel()
        let delay = drainFallbackDelay
        drainTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self.drainQueue()
        }
    }

    /// Send now: idle, the message goes out at once; while a reply runs it moves to the head and the reply is
    /// stopped (without pausing the queue), so the settle sends it next.
    func sendQueuedNow(_ id: UUID) {
        guard id != editingQueueId, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let entry = queue.remove(at: i)
        queue.insert(entry, at: 0)
        queueParked = false
        if busy { stop(parkQueue: false) } else { drainQueue() }
    }

    func deleteQueued(_ id: UUID) {
        if editingQueueId == id { cancelQueueEdit() }
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let entry = queue.remove(at: i)
        PasteboardAttachments.delete(entry.attachments.map(\.url), folder: pasteFolder)
        if queue.isEmpty { queueParked = false }
    }

    /// Resume after Stop paused the queue.
    func resumeQueue() {
        queueParked = false
        drainQueue()
    }

    // MARK: edit

    /// Loads a queued message's text into the composer; the draft that was there comes back afterwards.
    func beginQueueEdit(_ id: UUID) {
        guard editingQueueId == nil, let entry = queue.first(where: { $0.id == id }) else { return }
        draftBeforeEdit = draft
        editingQueueId = id  // first: the queued text is not saved as the bot's draft (B12)
        draft = entry.text
    }

    /// Writes the composer text back into the message (an emptied text-only message is deleted).
    @discardableResult
    func saveQueueEdit() -> Bool {
        guard let id = editingQueueId else { return false }
        let text = trimmedDraft
        endQueueEdit()
        if let i = queue.firstIndex(where: { $0.id == id }) {
            if text.isEmpty && queue[i].attachments.isEmpty { deleteQueued(id) } else { queue[i].text = text }
        }
        drainQueue()
        return true
    }

    func cancelQueueEdit() {
        guard editingQueueId != nil else { return }
        endQueueEdit()
        drainQueue()
    }

    private func endQueueEdit() {
        editingQueueId = nil  // first: the restored draft is saved again (B12)
        draft = draftBeforeEdit
        draftBeforeEdit = ""
    }
}
