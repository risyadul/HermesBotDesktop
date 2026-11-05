import Foundation
import HermesGatewayKit

/// B3: a rewind waiting for the user's OK. `anchor` is the line the action was invoked on: the plan is re-made
/// from it when the user confirms, and dropped if it no longer aims at the same turn.
struct RewindConfirm: Identifiable, Equatable {
    let id = UUID()
    let plan: RewindPlan
    let anchor: UUID
    /// The edited text shown in the transcript (Edit only).
    let display: String?
    /// The backend refused an unconfirmed cut (`4033`): it archives later turns this transcript does not show.
    /// The confirmed rerun then sends `confirm_deep_truncate` whatever the transcript counts.
    var forced = false

    var title: String { Self.restoreTitle }
    var message: String {
        let later = plan.laterUserTurns
        let removed: String
        if forced { removed = " Later messages stored in Hermes are removed with it." } else {
            removed = later == 0 ? "" : (later == 1 ? " 1 later message is removed with it." : " \(later) later messages are removed with it.")
        }
        return Self.restoreBody + removed
    }
    var confirmLabel: String { plan.kind == .edit ? "Send Edit" : Self.restoreConfirm }

    /// Hermes Desktop's checkpoint copy (`i18n/en.ts` `assistant.thread.restore*`).
    static let restoreTitle = "Restore to this checkpoint?"
    static let restoreBody = "Everything after this prompt is removed from the conversation, and the prompt runs again from here."
    static let restoreConfirm = "Restore & Rerun"
}

/// B3: the sent message being edited in the edit sheet.
struct MessageEdit: Identifiable, Equatable {
    var id: UUID { lineId }
    let lineId: UUID
    var text: String
    /// The original message carried attachments, which an edit does not send again (as in Desktop).
    let hadAttachments: Bool
}

/// B3 regenerate / edit / restore, B4 branches, B10 error-card actions.
///
/// Rewinds follow Hermes Desktop exactly (`use-prompt-actions/rewind.ts`): one `prompt.submit` addressed by the
/// turn's durable row id (`truncate_before_row_id` + `confirm_truncate` + `confirm_empty_truncate`, and
/// `confirm_deep_truncate` once the user agreed to archive later turns). Desktop runs them in a bot's canonical
/// Bot Chat as well, so the canonical chat is cut back in place: the backend archives what the cut drops; the
/// chat itself is never closed, deleted or reset. A turn whose row id is unknown is looked up by content in
/// `session.history`; when that fails too the prompt is sent again as a new turn and nothing is cut (Desktop
/// degrades the same way, never guessing a cut). Rewinds run only while the chat is idle.
extension ChatModel {
    /// User lines that are the user's own prompts (timeline notices are not rerun).
    nonisolated static func isPrompt(_ line: ChatLine) -> Bool { SystemNotice.parse(line.text) == nil }

    /// Regenerate, edit, restore and branch need an idle, open chat.
    var canRewind: Bool { isReady && !reconnecting && !busy && activity == nil && session != nil && !branching }

    /// Shown when the turn's stored row could not be found and the prompt went out as a new message.
    nonisolated static let plainResendNote = "Hermes could not find that message in the stored conversation, so it was sent again as a new message and nothing was removed."

    // MARK: B3 actions

    /// Regenerate from a reply (or an error card's Retry): reruns the user turn above it.
    func regenerate(from lineId: UUID) {
        guard let plan = RewindPlanner.plan(.regenerate, from: lineId, in: lines, isPrompt: Self.isPrompt) else { return }
        if plan.isDeepCut { rewindConfirm = RewindConfirm(plan: plan, anchor: lineId, display: nil) } else {
            performRewind(plan, display: nil, confirmDeep: false)
        }
    }

    /// Restore from a sent message: always confirmed (Desktop's checkpoint dialog).
    func restore(from lineId: UUID) {
        guard let plan = RewindPlanner.plan(.restore, from: lineId, in: lines, isPrompt: Self.isPrompt) else { return }
        rewindConfirm = RewindConfirm(plan: plan, anchor: lineId, display: nil)
    }

    /// Opens the edit sheet for a sent message.
    func beginEdit(_ lineId: UUID) {
        guard canRewind, let line = lines.first(where: { $0.id == lineId }), line.role == .user, Self.isPrompt(line) else { return }
        let typed = PromptHistory.typed(line.text)
        editing = MessageEdit(lineId: lineId, text: typed, hadAttachments: typed != line.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cancelEdit() { editing = nil }

    /// Sends the edit: reruns the conversation from that message with the new text (confirmed first when it
    /// archives later turns). Returns false when there is nothing to send (unchanged or blank).
    @discardableResult
    func commitEdit(_ text: String) -> Bool {
        guard let e = editing else { return false }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty,
              let plan = RewindPlanner.plan(.edit, from: e.lineId, in: lines, editedPrompt: modelText(typed), isPrompt: Self.isPrompt)
        else { return false }
        editing = nil
        if plan.isDeepCut { rewindConfirm = RewindConfirm(plan: plan, anchor: e.lineId, display: typed) } else {
            performRewind(plan, display: typed, confirmDeep: false)
        }
        return true
    }

    /// The user agreed: the plan is re-made against the current transcript and sent if it still aims at the
    /// same turn with the same later turns (Desktop `revalidateEditPlan`).
    func confirmRewind() {
        guard let c = rewindConfirm else { return }
        rewindConfirm = nil
        let edited = c.display.map { modelText($0) }
        guard let fresh = RewindPlanner.plan(c.plan.kind, from: c.anchor, in: lines, editedPrompt: edited, isPrompt: Self.isPrompt),
              fresh.lineId == c.plan.lineId, c.forced || fresh.laterUserTurns == c.plan.laterUserTurns else {
            transcript.appendSystem("The conversation changed while you were deciding; nothing was sent.")
            return
        }
        performRewind(fresh, display: c.display, confirmDeep: c.forced || fresh.isDeepCut)
    }

    func cancelRewind() { rewindConfirm = nil }

    /// Resolves the turn's durable row id (by content in `session.history` when the transcript has none), then
    /// cuts the transcript back and submits. On failure the transcript comes back as it was.
    func performRewind(_ plan: RewindPlan, display: String?, confirmDeep: Bool) {
        guard canRewind, let s = session else {
            transcript.appendSystem("Wait for the current reply to finish, then try again.")
            return
        }
        let verb = Self.verb(plan.kind)
        activity = "\(verb.capitalized)…"
        Task {
            var rowId = plan.rowId
            if rowId == nil {
                do { rowId = RewindPlanner.resolveRowId(plan.sourceText, ordinal: plan.ordinal, history: try await s.historyRows()) } catch {
                    self.log("session.history failed: \(Self.message(error, bot: self.bot))")
                }
            }
            let snapshot = self.transcript
            let rebind = snapshot.durableRowIds
            let started: Bool
            if rowId != nil {
                started = self.transcript.beginRewind(at: plan.lineId, editedText: display, prompt: plan.kind == .edit ? plan.text : nil)
            } else {
                let shown = display ?? self.lines.first(where: { $0.id == plan.lineId })?.text ?? plan.text
                started = self.transcript.beginTurn(shown, prompt: plan.text) != nil
            }
            self.activity = nil
            guard started, !self.closed else {
                if !self.closed { self.transcript.appendSystem("A reply started meanwhile; nothing was sent.") }
                return
            }
            do {
                let receipt = try await s.rewind(text: plan.text, rowId: rowId, confirmDeep: confirmDeep, rebind: rebind)
                self.log("prompt.submit (\(verb)) → status=\(receipt.status) truncated=\(receipt.truncated)")
                self.apply(receipt)
                if !receipt.truncated { self.transcript.appendSystem(Self.plainResendNote) }
                self.noteSubmitStatus(receipt.status)
            } catch let e as GatewayClient.RPCError where e.code == RewindError.deepCutUnconfirmed && !confirmDeep {
                // The backend counts later turns the transcript here did not show: ask, then cut deep.
                self.transcript = snapshot
                self.rewindConfirm = RewindConfirm(plan: plan, anchor: plan.lineId, display: display, forced: true)
            } catch {
                self.transcript = snapshot
                let msg = Self.message(error, bot: self.bot)
                self.log("\(verb) failed: \(msg)")
                self.transcript.appendSystem("Couldn't \(verb): \(msg)")
            }
        }
    }

    private func apply(_ r: RewindReceipt) {
        if let map = r.survivorMap { transcript.rebindRowIds(map) } else if let users = r.survivorUserIds { transcript.rebindUserRowIds(users) }
        if let id = r.userRowId { transcript.bindSentUser(rowId: id) }
    }

    nonisolated static func verb(_ kind: RewindPlan.Kind) -> String {
        switch kind {
        case .regenerate: return "regenerate"
        case .edit: return "send the edit"
        case .restore: return "restore"
        }
    }

    // MARK: B4 branch

    /// Branch into a new chat from `lineId`: `session.branch` copies the conversation up to and including that
    /// message into a NEW stored session of this bot (listed under its recent sessions), opened read-write in a
    /// side sheet. The canonical Bot Chat is untouched. Not offered inside a branch (one side sheet at a time).
    func branchFrom(_ lineId: UUID) {
        guard !isBranch, let s = session else { return }
        guard canRewind else {
            transcript.appendSystem("Stop the current reply before branching.")
            return
        }
        branching = true
        Task {
            defer { self.branching = false }
            var rows: [HistoryRow]?
            do { rows = try await s.historyRows() } catch {
                self.log("session.history failed: \(Self.message(error, bot: self.bot))")
            }
            guard let count = BranchPlanner.count(through: lineId, lines: self.lines, history: rows) else {
                self.transcript.appendSystem("Nothing to branch from that message.")
                return
            }
            do {
                let link = try await s.branchSession(count: count, idempotencyKey: Self.branchKey())
                guard !self.closed else { link.detach(); return }
                self.log("session.branch → session_id=\(link.sessionId) stored=\(link.storedSessionId) count=\(count)")
                let m = ChatModel(bot: self.bot, opener: { _ in link })
                m.isBranch = true
                m.roster = self.roster
                m.log = self.log
                self.closeBranch()
                self.branch = m
                m.open()
            } catch {
                self.transcript.appendSystem("Couldn't branch: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    /// Desktop's per-attempt idempotency key (`branch-<ms>-<random>`): a retried request returns the same child.
    nonisolated static func branchKey(now: Date = Date()) -> String {
        "branch-\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Closes the side sheet: the branch detaches (its stored session stays, under the bot's recent sessions).
    func closeBranch() {
        branch?.close()
        branch = nil
    }

    // MARK: B10 error cards

    /// The card's buttons for an error line: Retry only when there is a turn to rerun.
    func recovery(for line: ChatLine) -> ErrorRecoveryPlan? {
        guard let f = line.failure else { return nil }
        var plan = ErrorRecoveryPlan(f)
        plan.retry = plan.retry && RewindPlanner.plan(.regenerate, from: line.id, in: lines, isPrompt: Self.isPrompt) != nil
        return plan
    }

    func retry(errorLine id: UUID) { regenerate(from: id) }

    func dismissError(_ id: UUID) { transcript.dismissError(id) }

    /// Copy diagnostics: the redacted error details blob (`ErrorDiagnostics`).
    func copyDiagnostics(_ id: UUID) {
        guard let f = lines.first(where: { $0.id == id })?.failure else { return }
        ChatCopy.copy(diagnostics(f))
    }

    func diagnostics(_ f: TurnFailure) -> String {
        ErrorDiagnostics.text(f, bot: bot.name, model: currentModel, provider: currentProvider,
                              appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// Switch provider: opens the composer's model picker (picks change this chat only, B7).
    func switchProvider() {
        if modelCatalog == nil { loadModelOptions() }
        modelPickerShown = true
    }
}
