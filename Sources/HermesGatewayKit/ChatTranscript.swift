import Foundation

public struct ChatLine: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, bot, error }
    public let id: UUID
    public let role: Role
    public var text: String
    /// The live bubble of the running turn (deltas still arriving).
    public var streaming: Bool
    /// A sealed `message.interim` segment (commentary beside tool calls).
    public var interim: Bool

    public init(role: Role, text: String, streaming: Bool = false, interim: Bool = false) {
        id = UUID(); self.role = role; self.text = text; self.streaming = streaming; self.interim = interim
    }
}

/// The 1:1 Bot Chat transcript and its turn state, kept UI-free so it can be unit tested.
///
/// Submit gate: `beginTurn` is the ONLY way a user line enters, and it refuses while a turn runs.
/// Callers clear their input only when it returns non-nil, synchronously on the same actor, so two
/// submits before the network task starts cannot both pass.
///
/// Turn settling follows the TUI's `recordInterimMessage` / `recordMessageComplete`
/// (`ui-tui/src/app/turnController.ts:629-760`, `772-796`), reduced to bubbles:
/// - `message.delta` grows the live bubble.
/// - `message.interim {text}` seals the live bubble as its own segment, with the interim text as the
///   authoritative content (or appends one when nothing streamed), and moves the interim boundary.
/// - `message.complete` settles the turn with the final text as authoritative:
///   - text nil (no string text/rendered): the streamed bubble is the answer.
///   - `response_transformed` and non-empty text: the final REPLACES the streamed bubble.
///   - otherwise, if what streamed is not contained in the final text (e.g. an empty final from the
///     Bot Chat silence guard, `prompt_turn.py:31-42`), the streamed bubble is kept as a segment.
///   - the final text minus any leading segments it repeats (segments after the interim boundary;
///     all segments when `response_previewed` or `response_reused`) is shown in the live bubble's
///     place, so nothing is shown twice.
/// - `error` / disconnect: the live bubble is sealed with what streamed, an error line is added, and
///   the turn ends. No retry/reconnect in M1.
public struct ChatTranscript: Sendable, Equatable {
    public private(set) var lines: [ChatLine] = []
    public private(set) var busy = false
    public private(set) var deltaCount = 0
    private var liveIndex: Int?
    private var segments: [String] = []
    private var interimBoundary = 0

    public init() {}

    /// Accepts a user message when idle: appends it, marks the turn busy and returns the trimmed
    /// text to send. Returns nil (nothing changes) when busy or blank.
    public mutating func beginTurn(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return nil }
        busy = true
        liveIndex = nil; segments = []; interimBoundary = 0
        lines.append(ChatLine(role: .user, text: text))
        return text
    }

    /// Ends the turn with an error (send failed, `error` event, socket gone).
    public mutating func fail(_ message: String) {
        sealLive()
        lines.append(ChatLine(role: .error, text: message))
        busy = false
    }

    public mutating func apply(_ e: ChatEvent) {
        switch e {
        case .started:
            _ = live()
        case .delta(let d):
            guard !d.isEmpty else { return }
            let i = live()
            lines[i].text += d
            deltaCount += 1
        case .interim(let text, _):
            let t = Self.trimLeading(text)
            guard !t.isEmpty else { return }
            if let i = liveIndex {
                lines[i].text = t; lines[i].streaming = false; lines[i].interim = true
                liveIndex = nil
            } else {
                lines.append(ChatLine(role: .bot, text: t, interim: true))
            }
            segments.append(t)
            interimBoundary = segments.count
        case .completed(let c):
            complete(c)
        case .error(let m):
            fail(m)
        case .disconnected(let reason):
            // Only a running turn is affected; an idle chat just cannot send any more.
            if busy || liveIndex != nil { fail("disconnected: \(reason)") }
        case .reasoning, .status, .other:
            break
        }
    }

    private mutating func complete(_ c: ChatCompletion) {
        let streamed = liveIndex.map { lines[$0].text } ?? ""
        let tail = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        var final = c.text.map(Self.trimLeading) ?? ""
        if c.text == nil {
            // No final text on the wire: what streamed is the answer.
            final = Self.trimLeading(streamed)
        } else if !tail.isEmpty, let i = liveIndex,
                  !(c.responseTransformed && !final.isEmpty), !final.contains(tail) {
            // Streamed text the final does not carry (e.g. an empty final): keep it as a segment.
            lines[i].streaming = false
            segments.append(tail)
            liveIndex = nil
        }
        let start = (c.responsePreviewed || c.responseReused) ? 0 : min(interimBoundary, segments.count)
        let shown = Self.finalTail(final, Array(segments[start...]))
        if let i = liveIndex {
            if shown.isEmpty {
                lines.remove(at: i)
            } else {
                lines[i].text = shown; lines[i].streaming = false
            }
            liveIndex = nil
        } else if !shown.isEmpty {
            lines.append(ChatLine(role: .bot, text: shown))
        }
        if let status = c.status, status != "complete" {
            lines.append(ChatLine(role: .error, text: "turn \(status)" + (c.error.map { ": \($0)" } ?? "")))
        }
        busy = false
    }

    /// The bot text of the latest turn's last bubble (evidence logging).
    public var lastBotText: String { lines.last(where: { $0.role == .bot })?.text ?? "" }

    // MARK: - internals

    private mutating func live() -> Int {
        if let i = liveIndex { return i }
        lines.append(ChatLine(role: .bot, text: "", streaming: true))
        liveIndex = lines.count - 1
        return liveIndex!
    }

    private mutating func sealLive() {
        guard let i = liveIndex else { return }
        if lines[i].text.isEmpty { lines.remove(at: i) } else { lines[i].streaming = false }
        liveIndex = nil
    }

    /// `finalTail` in `turnController.ts:112-124`: drop leading segments the final text repeats.
    static func finalTail(_ finalText: String, _ segments: [String]) -> String {
        var tail = finalText
        for s in segments {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && tail.hasPrefix(t) { tail = trimLeading(String(tail.dropFirst(t.count))) }
        }
        return tail
    }

    static func trimLeading(_ s: String) -> String {
        String(s.drop(while: { $0.isWhitespace || $0.isNewline }))
    }
}
