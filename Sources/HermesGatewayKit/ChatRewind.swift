import Foundation

// B3 (regenerate, edit a sent message, restore from a message) and B4 (branch into a new chat), as Hermes
// Desktop does them (`apps/desktop/src/app/session/hooks/use-prompt-actions/rewind.ts`,
// `use-session-actions/index.ts` `branchLoadedSession` / `forkBranch`):
// - every rewind is ONE `prompt.submit` that carries a truncation address: the gateway cuts the transcript
//   before that user turn (archiving what it drops) and runs the text as the new turn
//   (`tui_gateway/methods_prompt.py` `_parse_truncation_params` / `_truncate_history_for_submit`). Desktop
//   does this in a bot's canonical Bot Chat too (its rewind core serves the primary chat and every tile), so the
//   canonical chat is rewound in place, never deleted, closed or reset;
// - a branch is `session.branch {session_id, idempotency_key, count}`: a NEW stored session holding the first
//   `count` visible messages, with its own live runtime (`methods_session_branch.py` `_branch_live`).

/// One row of `session.history` as the rewind and branch planners need it: raw, hidden rows included (the
/// backend's branch count runs over every user/assistant row with visible text).
public struct HistoryRow: Sendable, Equatable {
    public let role: String
    public let text: String
    public let rowId: Int?
    /// `display_kind` (timeline markers, hidden notes); nil for an ordinary message.
    public let displayKind: String?

    public init(role: String, text: String, rowId: Int? = nil, displayKind: String? = nil) {
        self.role = role; self.text = text; self.rowId = rowId; self.displayKind = displayKind
    }

    init?(_ v: JSONValue) {
        guard let role = v["role"]?.string else { return nil }
        self.init(role: role, text: v["text"]?.string ?? v["content"]?.string ?? "", rowId: v["row_id"]?.int,
                  displayKind: v["display_kind"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    public static func decode(_ v: JSONValue?) -> [HistoryRow] { (v?.array ?? []).compactMap(HistoryRow.init) }

    /// A user or assistant row with visible text: what `session.branch` copies and counts.
    var isBranchVisible: Bool {
        (role == "user" || role == "assistant") && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What to resubmit for a rewind, planned from the transcript (pure).
public struct RewindPlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case regenerate, edit, restore }
    public let kind: Kind
    /// The user line the conversation is cut back to (it stays, rerun).
    public let lineId: UUID
    /// The user line's index in the planned transcript (B3 confirms and stale checks).
    public let lineIndex: Int
    /// The text submitted as the new turn (model-facing).
    public let text: String
    /// The ORIGINAL submitted text of that turn: the content key for resolving its durable row id.
    public let sourceText: String
    /// Its durable row id when the transcript knows it.
    public let rowId: Int?
    /// The ordinal of that user turn among the transcript's user lines (`expectedOrdinal`).
    public let ordinal: Int
    /// User turns after it: a cut there archives them, which needs the user's confirmation (Desktop #133716).
    public let laterUserTurns: Int

    public var isDeepCut: Bool { laterUserTurns > 0 }

    public init(kind: Kind, lineId: UUID, lineIndex: Int, text: String, sourceText: String, rowId: Int?, ordinal: Int,
                laterUserTurns: Int) {
        self.kind = kind; self.lineId = lineId; self.lineIndex = lineIndex; self.text = text; self.sourceText = sourceText
        self.rowId = rowId; self.ordinal = ordinal; self.laterUserTurns = laterUserTurns
    }
}

public enum RewindPlanner {
    /// The user line a rewind from `lineId` reruns: the line itself when it is a user line, else the nearest
    /// user line before it (Desktop `planReload`: the user turn above the reply). `isPrompt` leaves out user
    /// lines that are not the user's own prompts (timeline notices).
    public static func userIndex(for lineId: UUID, in lines: [ChatLine], isPrompt: (ChatLine) -> Bool = { _ in true }) -> Int? {
        guard let i = lines.firstIndex(where: { $0.id == lineId }) else { return nil }
        return lines[...i].lastIndex { $0.role == .user && isPrompt($0) }
    }

    /// Regenerate (from a reply or an error line) and Restore (from a user line) rerun the original prompt;
    /// Edit reruns `editedPrompt`. nil when there is nothing to rerun (no user turn, blank text, an edit that
    /// changes nothing).
    public static func plan(_ kind: RewindPlan.Kind, from lineId: UUID, in lines: [ChatLine], editedPrompt: String? = nil,
                            isPrompt: (ChatLine) -> Bool = { _ in true }) -> RewindPlan? {
        guard let i = userIndex(for: lineId, in: lines, isPrompt: isPrompt) else { return nil }
        if kind != .regenerate, lines[i].id != lineId { return nil }  // edit / restore name the user line itself
        let line = lines[i]
        let source = (line.prompt ?? line.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if kind == .edit {
            guard let e = editedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty, e != source else { return nil }
            text = e
        } else {
            text = source
        }
        guard !text.isEmpty else { return nil }
        let users = lines.indices.filter { lines[$0].role == .user && isPrompt(lines[$0]) }
        return RewindPlan(kind: kind, lineId: line.id, lineIndex: i, text: text, sourceText: source, rowId: line.rowId,
                          ordinal: users.firstIndex(of: i) ?? 0, laterUserTurns: users.filter { $0 > i }.count)
    }

    /// Desktop `resolveDurableRowId`: the user turn's row id by CONTENT in `session.history` (rows with a stamp,
    /// no `display_kind`). A unique match wins; several matches resolve to the last one only when the target is
    /// the latest persisted turn. Anything else is nil (the caller then resubmits without cutting).
    public static func resolveRowId(_ sourceText: String, ordinal: Int, history: [HistoryRow]) -> Int? {
        let wanted = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let users = history.filter { $0.role == "user" && $0.displayKind == nil && $0.rowId != nil }
        let matches = users.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
        if matches.count == 1 { return matches[0].rowId }
        if matches.count > 1, ordinal >= users.count - 1, let last = matches.last, users.last == last { return last.rowId }
        return nil
    }
}

/// `prompt.submit` truncation fields (Desktop `truncateSubmitParams` + `runRewindSubmit`, durable-row mode).
public enum RewindParams {
    /// With a row id: `confirm_truncate` (this submit really is a rewind), `truncate_before_row_id`,
    /// `confirm_empty_truncate` (the durable target is authoritative, so a first-turn cut is allowed) and
    /// `confirm_deep_truncate` only when the user confirmed archiving later turns. Without one: a plain
    /// resubmit that cuts nothing. `rebind_survivor_row_ids` (every durable id the client holds) rides along
    /// when non-empty so the reply maps them to their re-inserted rows.
    public static func submit(sessionId: String, text: String, rowId: Int?, confirmDeep: Bool, rebind: [Int]) -> JSONValue {
        var p: [String: JSONValue] = ["session_id": .string(sessionId), "text": .string(text)]
        if let rowId {
            p["confirm_truncate"] = true
            p["truncate_before_row_id"] = .number(Double(rowId))
            p["confirm_empty_truncate"] = true
            if confirmDeep { p["confirm_deep_truncate"] = true }
        }
        var seen = Set<Int>()
        let ids = rebind.filter { seen.insert($0).inserted }
        if !ids.isEmpty { p["rebind_survivor_row_ids"] = .array(ids.map { .number(Double($0)) }) }
        return .object(p)
    }
}

/// The `prompt.submit` reply of a rewind: the new turn's status and the survivors' new row ids.
public struct RewindReceipt: Sendable, Equatable {
    public var status: String
    /// `survivor_row_id_map {old: new|null}` (new gateways).
    public var survivorMap: [Int: Int?]?
    /// `survivor_user_row_ids` (older gateways), positional over the user turns.
    public var survivorUserIds: [Int?]?
    /// `user_row_id`: the resubmitted turn's durable row.
    public var userRowId: Int?
    /// The submit carried a truncation address (false: the turn's row could not be found, resubmitted plainly).
    public var truncated: Bool

    public init(status: String, survivorMap: [Int: Int?]? = nil, survivorUserIds: [Int?]? = nil, userRowId: Int? = nil,
                truncated: Bool) {
        self.status = status; self.survivorMap = survivorMap; self.survivorUserIds = survivorUserIds
        self.userRowId = userRowId; self.truncated = truncated
    }

    public init(_ r: JSONValue, truncated: Bool) {
        var map: [Int: Int?]?
        if let obj = r["survivor_row_id_map"]?.object {
            var m: [Int: Int?] = [:]
            for (k, v) in obj {
                guard let old = Int(k) else { continue }
                if v == .null { m[old] = .some(nil) } else if let n = v.int { m[old] = .some(n) }
            }
            map = m
        }
        let users = r["survivor_user_row_ids"]?.array.map { $0.map(\.int) }
        self.init(status: r["status"]?.string ?? "", survivorMap: map, survivorUserIds: map == nil ? users : nil,
                  userRowId: r["user_row_id"]?.int, truncated: truncated)
    }
}

public enum BranchPlanner {
    /// `session.branch`'s `count` for a branch that ends at `lineId` (Desktop `selectBranchMessages`): the target
    /// is found in the authoritative history by row id, else by role + text ordinal, and the count is the
    /// visible user/assistant rows up to it. Without a match, the transcript's own visible user/bot lines up to
    /// the target are counted. nil when the target is not a user or bot line with text.
    public static func count(through lineId: UUID, lines: [ChatLine], history: [HistoryRow]?) -> Int? {
        guard let i = lines.firstIndex(where: { $0.id == lineId }) else { return nil }
        let target = lines[i]
        guard target.role == .user || target.role == .bot, !comparable(target).isEmpty else { return nil }
        let local = lines[...i].filter { ($0.role == .user || $0.role == .bot) && !comparable($0).isEmpty }
        guard let history else { return local.count }
        let visible = history.filter(\.isBranchVisible)
        let role = target.role == .user ? "user" : "assistant"
        var index = target.rowId.flatMap { id in visible.firstIndex { $0.rowId == id } }
        if index == nil {
            let key = comparable(target)
            let wanted = local.filter { $0.role == target.role && comparable($0) == key }.count
            var seen = 0
            index = visible.firstIndex { row in
                guard row.role == role, row.text.trimmingCharacters(in: .whitespacesAndNewlines) == key else { return false }
                seen += 1
                return seen == wanted
            }
        }
        guard let index else { return local.count }
        return index + 1
    }

    /// The text a line is matched on: what was submitted for a user line, the shown text for a reply.
    static func comparable(_ line: ChatLine) -> String {
        (line.role == .user ? (line.prompt ?? line.text) : line.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension BotChatSession {
    /// `session.history {session_id}`: the stored transcript with durable row ids (read-only).
    public func historyRows() async throws -> [HistoryRow] {
        HistoryRow.decode(try await backend.client.call("session.history", ["session_id": .string(sessionId)])["messages"])
    }

    /// A rewind's `prompt.submit` (`RewindParams.submit`). `rowId` nil resubmits without cutting.
    public func rewind(text: String, rowId: Int?, confirmDeep: Bool, rebind: [Int]) async throws -> RewindReceipt {
        do {
            let r = try await backend.client.call("prompt.submit", RewindParams.submit(
                sessionId: sessionId, text: text, rowId: rowId, confirmDeep: confirmDeep, rebind: rebind))
            return RewindReceipt(r, truncated: rowId != nil)
        } catch let e as GatewayClient.RPCError where e.code == BotChatError.sessionNotOwnedCode {
            throw BotChatError.sessionNotOwned(bot: bot.title)
        }
    }

    /// `session.branch {session_id, idempotency_key, count}` → the new side session, attached (events route to
    /// its `onEvent`). Never the canonical chat: it is a separate stored session of the same profile (it shows
    /// under the bot's recent sessions), opened from the branch reply's `messages` and `info`.
    public func branch(count: Int, idempotencyKey: String) async throws -> BotChatSession {
        let r = try await backend.client.call("session.branch", [
            "session_id": .string(sessionId), "idempotency_key": .string(idempotencyKey), "count": .number(Double(count)),
        ])
        let s = try BotChatSession(backend: backend, bot: bot, result: r, method: "session.branch")
        s.title = r["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        s.attach()
        return s
    }
}

/// Gateway codes a rewind can answer with (`methods_prompt.py`).
public enum RewindError {
    /// `confirm_deep_truncate` required: the cut archives later turns the user has not confirmed.
    public static let deepCutUnconfirmed = 4033
    /// The target turn is gone (compressed away, already rewound elsewhere).
    public static let staleTarget = 4018
    public static let sessionBusy = 4009
}
