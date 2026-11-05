import AppKit
import Foundation
import HermesGatewayKit

/// B12: shell-style prompt history for the Bot Chat composer. As in Hermes Desktop
/// (`store/composer-input-history.ts`), the ring is derived from the chat's own user messages on every
/// key press (newest first), so it is per bot, survives launches (Hermes keeps the chat) and includes
/// prompts sent from Desktop; only the browse position and the draft from before browsing are kept here.
struct PromptHistory: Equatable {
    /// Index into the ring (0 = newest) while browsing; nil when not browsing.
    private(set) var cursor: Int?
    /// The composer text when browsing began, restored by ↓ past the newest entry.
    private(set) var stash = ""
    /// The text the last recall put in the composer: an edit since then ends browsing.
    private(set) var recalled: String?

    /// The user's sent messages, newest first: Hermes notices, blank rows and repeats of the next newer
    /// entry left out; the "Attached: …" line the transcript adds for files is not part of what was typed.
    static func ring(_ lines: [ChatLine]) -> [String] {
        var out: [String] = []
        for line in lines.reversed() where line.role == .user && SystemNotice.parse(line.text) == nil {
            let text = typed(line.text)
            guard !text.isEmpty, out.last != text else { continue }
            out.append(text)
        }
        return out
    }

    /// A user line's text without the attachment list `ChatModel.displayText` appends.
    static func typed(_ text: String) -> String {
        var t = text
        if t.hasPrefix("Attached: ") && !t.contains("\n") { return "" }
        if let r = t.range(of: "\n\nAttached: ", options: .backwards), !t[r.upperBound...].contains("\n") {
            t = String(t[..<r.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether ↑ (or ↓) recalls rather than moving the caret: the caret is at the very start (end) of the
    /// text with nothing selected, like a shell. `caret` and `length` are in UTF-16 units (NSTextView).
    static func caretAllows(up: Bool, caret: NSRange, length: Int) -> Bool {
        guard caret.length == 0 else { return false }
        return up ? caret.location == 0 : caret.location >= length
    }

    var isBrowsing: Bool { cursor != nil }

    /// ↑: the next older entry (the draft is kept to come back to), nil at the oldest or with no history.
    mutating func older(draft: String, ring: [String]) -> String? {
        if cursor != nil, draft != recalled { reset() }
        guard !ring.isEmpty else { return nil }
        let next: Int
        if let c = cursor {
            guard c + 1 < ring.count else { return nil }
            next = c + 1
        } else {
            stash = draft
            next = 0
        }
        cursor = next
        recalled = ring[next]
        return ring[next]
    }

    /// ↓ while browsing: the next newer entry, or the stashed draft past the newest. nil when not browsing.
    mutating func newer(draft: String, ring: [String]) -> String? {
        guard let c = cursor, draft == recalled else { reset(); return nil }
        if c > 0, c - 1 < ring.count {
            cursor = c - 1
            recalled = ring[c - 1]
            return ring[c - 1]
        }
        let back = stash
        reset()
        return back
    }

    mutating func reset() { cursor = nil; stash = ""; recalled = nil }
}

/// B12: per-bot composer drafts kept across launches in UserDefaults (`hba.botChatDrafts`), size-capped:
/// a draft over `maxChars` is not kept (a cut-off draft could be sent by mistake), and only the
/// `maxBots` most recently edited drafts are. Blank drafts are removed, and so is a draft that holds
/// something token-shaped (`Redaction.scrub` would change it): a pasted bearer token or gateway URL with
/// `?token=` never lands in UserDefaults.
struct ChatDraftStore {
    static let key = "hba.botChatDrafts"
    static let maxChars = 20_000
    static let maxBots = 64
    let defaults: UserDefaults

    /// The app's store (standard defaults); nil under XCTest, so tests never write a real draft.
    static var app: ChatDraftStore? {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] == nil, env["XCTestBundlePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return nil }
        return ChatDraftStore(defaults: .standard)
    }

    private var all: [String: [String: Any]] { defaults.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:] }

    func draft(for bot: String) -> String { all[bot]?["text"] as? String ?? "" }

    func save(_ text: String, for bot: String, now: Date = Date()) {
        var drafts = all
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > Self.maxChars
            || Redaction.scrub(text) != text {
            guard drafts[bot] != nil else { return }
            drafts[bot] = nil
        } else {
            drafts[bot] = ["text": text, "at": now.timeIntervalSince1970]
            let oldestFirst = drafts.sorted { ($0.value["at"] as? Double ?? 0) < ($1.value["at"] as? Double ?? 0) }
            for (name, _) in oldestFirst.prefix(max(0, drafts.count - Self.maxBots)) { drafts[name] = nil }
        }
        defaults.set(drafts, forKey: Self.key)
    }
}

/// B1 and B12 on the chat model: prompt history browsing and the @mention roster.
extension ChatModel {
    // MARK: prompt history (B12)

    /// ↑ with the caret at the start: recall the next older message. False when there is none (the key
    /// then does what it normally does).
    @discardableResult
    func recallOlder() -> Bool {
        guard editingQueueId == nil, let text = history.older(draft: draft, ring: PromptHistory.ring(lines)) else { return false }
        draft = text
        return true
    }

    /// ↓ with the caret at the end while browsing: the next newer message, then the draft from before.
    @discardableResult
    func recallNewer() -> Bool {
        guard editingQueueId == nil, let text = history.newer(draft: draft, ring: PromptHistory.ring(lines)) else { return false }
        draft = text
        return true
    }

    // MARK: @mentions (B1)

    /// The bots this chat can tag: the roster without the bot itself.
    var mentionCandidates: [Bot] { BotMentions.candidates(roster(), excluding: bot.name) }

    /// Forms that highlight as @mentions in this chat's user messages.
    var mentionHandles: Set<String> {
        Set(mentionCandidates.flatMap { [BotMentions.tag($0), BotMentions.handle($0), $0.name] })
    }

    /// What the model receives for a typed prompt: the prompt plus the mention note when it tags bots.
    func modelText(_ text: String) -> String { BotMentions.annotate(text, roster: roster(), selfName: bot.name) }
}

/// B1: autocomplete for `@` in the Bot Chat composer (Desktop's `mention-completions`): roster bots whose
/// tag, handle, profile name or title starts with what follows the `@` at the end of the draft, at most 8.
enum BotMentionCompletion {
    static let limit = 8

    /// What follows the trailing `@`, or nil when the draft does not end in an @word.
    static func query(_ draft: String) -> String? {
        guard let r = draft.range(of: "(?:^|\\s)@([A-Za-z0-9_-]*)$", options: .regularExpression) else { return nil }
        return String(draft[r].drop(while: { $0 != "@" }).dropFirst()).lowercased()
    }

    static func matches(_ draft: String, candidates: [Bot]) -> [Bot] {
        guard let q = query(draft) else { return [] }
        let hits = candidates.filter { b in
            q.isEmpty || [BotMentions.tag(b), BotMentions.handle(b), b.name, b.title].contains { $0.lowercased().hasPrefix(q) }
        }
        return Array(hits.prefix(limit))
    }

    /// The tag to insert: the bot's tag, or its handle when another candidate shares the tag (a shared tag
    /// would resolve to neither).
    static func insertion(_ bot: Bot, candidates: [Bot]) -> String {
        let tag = BotMentions.tag(bot)
        let shared = candidates.contains { $0.name != bot.name && BotMentions.forms($0).contains(tag.lowercased()) }
        return shared ? BotMentions.handle(bot) : tag
    }

    /// Replaces the trailing `@query` with `@tag `.
    static func insert(_ bot: Bot, candidates: [Bot], into draft: inout String) {
        guard let r = draft.range(of: "@[A-Za-z0-9_-]*$", options: .regularExpression) else { return }
        draft.replaceSubrange(r, with: "@\(insertion(bot, candidates: candidates)) ")
    }
}
