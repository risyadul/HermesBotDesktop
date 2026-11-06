import Foundation
import HermesGatewayKit

/// Labels and order of approval buttons. Once is the primary action; Deny is `button-danger` with the
/// same weight (DESIGN.md: a destructive choice is never smaller than its alternative).
enum ApprovalButtons {
    static func title(_ c: ApprovalPrompt.Choice) -> String {
        switch c {
        case .once: return "Allow once"
        case .session: return "This session"
        case .always: return "Always"
        case .deny: return "Deny"
        }
    }

    static func kind(_ c: ApprovalPrompt.Choice) -> DSButtonKind {
        switch c {
        case .once: return .primary
        case .session, .always: return .secondary
        case .deny: return .danger
        }
    }

    /// Offered choices in a fixed order (once, session, always, deny), whatever order the wire used.
    static func ordered(_ choices: [ApprovalPrompt.Choice]) -> [ApprovalPrompt.Choice] {
        ApprovalPrompt.Choice.allCases.filter(choices.contains)
    }
}

/// Staged answers of a clarify card. Mirrors Desktop `clarify/pending.tsx` `stagedAnswer`: single-select
/// sends the picked choice (else the typed text); multi-select sends a JSON array of the picked choices
/// plus the typed text; a skipped or empty question sends null.
struct ClarifyDraft: Equatable {
    struct Entry: Equatable {
        var picked: [String] = []
        var text = ""
        var skipped = false
    }

    private(set) var entries: [String: Entry] = [:]

    init(_ prompt: ClarifyPrompt) {
        for q in prompt.questions {
            guard let replay = prompt.replayAnswers[q.qid] else { continue }
            guard let answer = replay else { entries[q.qid] = Entry(skipped: true); continue }
            if q.choices.contains(answer) { entries[q.qid] = Entry(picked: [answer]) } else { entries[q.qid] = Entry(text: answer) }
        }
    }

    func entry(_ qid: String) -> Entry { entries[qid] ?? Entry() }

    mutating func toggle(_ choice: String, in q: ClarifyPrompt.Question) {
        var e = entry(q.qid)
        e.skipped = false
        if q.multiSelect {
            if let i = e.picked.firstIndex(of: choice) { e.picked.remove(at: i) } else { e.picked.append(choice) }
        } else {
            e.picked = e.picked == [choice] ? [] : [choice]
            if !e.picked.isEmpty { e.text = "" }
        }
        entries[q.qid] = e
    }

    mutating func setText(_ text: String, for q: ClarifyPrompt.Question) {
        var e = entry(q.qid)
        e.text = text
        if !text.isEmpty { e.skipped = false; if !q.multiSelect { e.picked = [] } }
        entries[q.qid] = e
    }

    mutating func skip(_ q: ClarifyPrompt.Question) { entries[q.qid] = Entry(skipped: true) }

    func answer(for q: ClarifyPrompt.Question) -> String? {
        let e = entry(q.qid)
        guard !e.skipped else { return nil }
        let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.multiSelect {
            let combined = e.picked + (text.isEmpty ? [] : [text])
            guard !combined.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: combined, options: [.withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return e.picked.first ?? (text.isEmpty ? nil : text)
    }

    /// `{qid: answer|null}` for every question.
    func answers(_ prompt: ClarifyPrompt) -> [String: String?] {
        var out: [String: String?] = [:]
        for q in prompt.questions { out[q.qid] = .some(answer(for: q)) }
        return out
    }

    /// Desktop enables Confirm once at least one question has an answer.
    func canSubmit(_ prompt: ClarifyPrompt) -> Bool {
        prompt.questions.contains { answer(for: $0) != nil }
    }
}

/// Copy for a sudo / secret prompt.
enum ValuePromptCopy {
    static func title(_ v: ValuePrompt) -> String {
        switch v.kind {
        case .sudo: return "Password needed to run a command"
        case .secret: return v.envVar.map { "A value is needed for \(VisibleText.reveal($0))" } ?? "A value is needed"
        }
    }

    static func fieldLabel(_ v: ValuePrompt) -> String {
        v.kind == .sudo ? "Your password" : (v.prompt.isEmpty ? "Value" : VisibleText.reveal(v.prompt))
    }
}
