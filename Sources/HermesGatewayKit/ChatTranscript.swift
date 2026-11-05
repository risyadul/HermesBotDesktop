import Foundation

public struct ChatLine: Identifiable, Sendable, Equatable {
    /// `tool`: one tool call (`tool` carries its state); `system`: client notes such as slash output.
    public enum Role: Sendable, Equatable { case user, bot, error, tool, system }
    public let id: UUID
    public let role: Role
    public var text: String
    /// The live bubble of the running turn (deltas still arriving).
    public var streaming: Bool
    /// A sealed `message.interim` segment (commentary beside tool calls).
    public var interim: Bool
    /// Set for `.tool` lines.
    public var tool: ToolLine?

    public init(role: Role, text: String, streaming: Bool = false, interim: Bool = false, tool: ToolLine? = nil) {
        id = UUID(); self.role = role; self.text = text; self.streaming = streaming; self.interim = interim
        self.tool = tool
    }
}

/// A tool call row: created by `tool.start`, finished by `tool.complete` (keyed by `toolId`), or a
/// settled row from history. `ChatLine.text` holds the context preview (or the label).
public struct ToolLine: Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, done, failed }
    public let toolId: String
    public let name: String
    public var state: State
    public var duration: Double?
    public var summary: String?
}

/// A turn that was running when the chat was resumed: `running` / `status` and the `inflight` snapshot
/// of the resume reply (`tui_gateway/server.py` resume payload: `running`, `status`
/// `waiting|starting|working|idle`, `inflight {user, assistant, streaming, error?}`,
/// `session_auto_continue.py` `_inflight_snapshot`). nil when the chat is idle.
public struct InflightTurn: Sendable, Equatable {
    public let user: String
    public let assistant: String

    public init(user: String, assistant: String) { self.user = user; self.assistant = assistant }

    init?(resume r: JSONValue) {
        let snapshot = r["inflight"]
        let status = r["status"]?.string ?? ""
        let running = r["running"]?.bool == true || ["working", "waiting", "streaming"].contains(status)
            || (snapshot?["streaming"]?.bool == true && snapshot?["error"] == nil)
        guard running else { return nil }
        self.init(user: snapshot?["user"]?.string ?? "", assistant: snapshot?["assistant"]?.string ?? "")
    }
}

/// The 1:1 Bot Chat transcript and its turn state, kept UI-free so it can be unit tested.
///
/// Submit gate: `beginTurn` is the ONLY way a user line enters, and it refuses while a turn runs —
/// including a turn another client started on the shared chat (`message.start` / a delta while idle).
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
///   - a live bubble seeded from a resume snapshot (`resumeRunningTurn`) is replaced by a non-empty final
///     like `response_transformed`: deltas between the snapshot and our subscription may be missing.
///   - a `message.complete` while idle (its turn began before this client attached, so the history already
///     carries it) changes nothing.
/// - `error` / disconnect: the live bubble is sealed with what streamed, an error line is added, and
///   the turn ends. No retry/reconnect in M1.
/// - a turn this client did not start (remote or seeded) also ends on `.idle` (`session.info running:false`)
///   or `abandon` (Stop got no settling event), so a missed `message.complete` cannot hold the gate forever.
public struct ChatTranscript: Sendable, Equatable {
    public private(set) var lines: [ChatLine] = []
    public private(set) var busy = false
    public private(set) var deltaCount = 0
    /// `tool.generating {name}`: the model is writing a tool call. A transient status, not a row; cleared
    /// by `tool.start` and when the turn ends.
    public private(set) var draftingTool: String?
    /// Bumped whenever a turn begins (local, remote or seeded): lets a delayed check tell "same turn".
    public private(set) var turnSerial = 0
    /// The running turn was started by this client's `beginTurn` (false for remote and seeded turns).
    public private(set) var turnIsLocal = false
    private var liveIndex: Int?
    /// The live bubble came from a resume snapshot (`resumeRunningTurn`), not from deltas seen here.
    private var liveSeeded = false
    /// The user line of the latest local turn (`retractUnsent`).
    private var unsentUserId: UUID?
    private var segments: [String] = []
    private var interimBoundary = 0

    public init() {}

    /// Accepts a user message when idle: appends it, marks the turn busy and returns the trimmed
    /// text to send. Returns nil (nothing changes) when busy or blank.
    public mutating func beginTurn(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return nil }
        busy = true
        turnSerial += 1; turnIsLocal = true
        liveIndex = nil; liveSeeded = false; segments = []; interimBoundary = 0
        let line = ChatLine(role: .user, text: text)
        unsentUserId = line.id
        lines.append(line)
        return text
    }

    /// The submit of the turn `beginTurn` just accepted failed before reaching the backend: its user line
    /// is removed (the caller restores the draft, so a resend does not show it twice) and the turn fails.
    public mutating func retractUnsent(_ message: String) {
        if let id = unsentUserId { lines.removeAll { $0.id == id } }
        unsentUserId = nil
        fail(message)
    }

    /// Ends a running turn this client gave up waiting on (Stop sent, no settling event arrived) with a
    /// neutral note instead of an error.
    public mutating func abandon(_ note: String) {
        guard busy else { return }
        sealLive()
        settleTools(.failed)
        busy = false
        appendSystem(note)
    }

    /// Replaces the transcript with a resumed session's history (idle only; returns false while busy).
    /// User / assistant rows become bubbles, tool rows settled tool lines, system rows system lines.
    @discardableResult
    public mutating func seed(history: [ChatHistoryMessage]) -> Bool {
        guard !busy else { return false }
        liveIndex = nil; liveSeeded = false; segments = []; interimBoundary = 0; draftingTool = nil
        lines = history.map { m in
            switch m.role {
            case .user: return ChatLine(role: .user, text: m.text)
            case .assistant: return ChatLine(role: .bot, text: m.text)
            case .system: return ChatLine(role: .system, text: m.text)
            case .tool:
                let name = m.toolName ?? "tool"
                return ChatLine(role: .tool, text: m.toolContext ?? "",
                                tool: ToolLine(toolId: "", name: name, state: .done))
            }
        }
        return true
    }

    /// Joins a turn that was already running when the chat was resumed (Hermes Desktop or an earlier
    /// launch started it): the gate closes (busy), the turn's user line is shown unless the history already
    /// ends with it, and what streamed so far becomes the live bubble the next deltas grow.
    public mutating func resumeRunningTurn(_ t: InflightTurn) {
        busy = true
        turnSerial += 1; turnIsLocal = false
        segments = []; interimBoundary = 0; draftingTool = nil
        let user = t.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, lines.last.map({ $0.role == .user && $0.text == user }) != true {
            lines.append(ChatLine(role: .user, text: user))
        }
        lines.append(ChatLine(role: .bot, text: t.assistant, streaming: true))
        liveIndex = lines.count - 1
        liveSeeded = true
    }

    /// Adds a client-side note (slash command output, notices). Turn state is untouched.
    public mutating func appendSystem(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = liveIndex {
            // Keep the live bubble last so the turn's deltas keep growing it.
            lines.insert(ChatLine(role: .system, text: t), at: i)
            liveIndex = i + 1
        } else {
            lines.append(ChatLine(role: .system, text: t))
        }
    }

    /// Ends the turn with an error (send failed, `error` event, socket gone).
    public mutating func fail(_ message: String) {
        sealLive()
        settleTools(.failed)
        lines.append(ChatLine(role: .error, text: message))
        busy = false
    }

    public mutating func apply(_ e: ChatEvent) {
        switch e {
        case .started:
            beginRemoteTurnIfIdle()
            _ = live()
        case .delta(let d):
            guard !d.isEmpty else { return }
            beginRemoteTurnIfIdle()
            let i = live()
            lines[i].text += d
            deltaCount += 1
        case .interim(let text, _):
            let t = Self.trimLeading(text)
            guard !t.isEmpty else { return }
            if let i = liveIndex {
                lines[i].text = t; lines[i].streaming = false; lines[i].interim = true
                liveIndex = nil; liveSeeded = false
            } else {
                lines.append(ChatLine(role: .bot, text: t, interim: true))
            }
            segments.append(t)
            interimBoundary = segments.count
        case .completed(let c):
            guard busy || liveIndex != nil else { return }
            complete(c)
        case .idle:
            if busy && !turnIsLocal { abandon("The reply ended elsewhere.") }
        case .error(let m):
            fail(m)
        case .disconnected(let reason):
            // Only a running turn is affected; an idle chat just cannot send any more.
            if busy || liveIndex != nil { fail("disconnected: \(reason)") }
        case .toolGenerating(let name):
            draftingTool = name.isEmpty ? nil : name
        case .toolStarted(let t):
            draftingTool = nil
            startTool(t)
        case .toolCompleted(let c):
            completeTool(c)
        case .reasoning, .status, .other, .request, .requestCancelled, .approvalsCancelled, .resumed:
            break
        }
    }

    /// Flushes what streamed so far before the row (ordering), sealing it as a segment the final text
    /// may repeat (deduplicated by `finalTail` like a kept streamed bubble), then adds a running row.
    private mutating func startTool(_ t: ToolStart) {
        if let i = liveIndex {
            let tail = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.isEmpty { lines.remove(at: i) } else { lines[i].streaming = false; segments.append(tail) }
            liveIndex = nil; liveSeeded = false
        }
        if !t.toolId.isEmpty, let i = toolIndex(t.toolId) {
            lines[i].tool?.state = .running
            return
        }
        lines.append(ChatLine(role: .tool, text: t.context ?? t.label ?? "",
                              tool: ToolLine(toolId: t.toolId, name: t.name, state: .running)))
    }

    private mutating func completeTool(_ c: ToolCompletion) {
        let state: ToolLine.State = c.failed ? .failed : .done
        if !c.toolId.isEmpty, let i = toolIndex(c.toolId) {
            lines[i].tool?.state = state
            lines[i].tool?.duration = c.duration
            lines[i].tool?.summary = c.summary
            return
        }
        // No start seen (joined mid-turn): upsert a settled row, before the live bubble if any.
        let line = ChatLine(role: .tool, text: "", tool: ToolLine(toolId: c.toolId, name: c.name, state: state,
                                                                  duration: c.duration, summary: c.summary))
        if let i = liveIndex { lines.insert(line, at: i); liveIndex = i + 1 } else { lines.append(line) }
    }

    private func toolIndex(_ toolId: String) -> Int? {
        lines.lastIndex { $0.role == .tool && $0.tool?.toolId == toolId }
    }

    /// Rows still running when the turn ends cannot finish any more.
    private mutating func settleTools(_ state: ToolLine.State) {
        draftingTool = nil
        for i in lines.indices where lines[i].tool?.state == .running { lines[i].tool?.state = state }
    }

    private mutating func complete(_ c: ChatCompletion) {
        let streamed = liveIndex.map { lines[$0].text } ?? ""
        let tail = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        var final = c.text.map(Self.trimLeading) ?? ""
        // A rewritten final, or one for a bubble seeded from a snapshot (deltas may be missing), replaces it.
        let authoritative = (c.responseTransformed || liveSeeded) && !final.isEmpty
        liveSeeded = false
        if c.text == nil {
            // No final text on the wire: what streamed is the answer.
            final = Self.trimLeading(streamed)
        } else if !tail.isEmpty, let i = liveIndex, !authoritative, !final.contains(tail) {
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
        settleTools(c.status == nil || c.status == "complete" ? .done : .failed)
        if let status = c.status, status != "complete" {
            lines.append(ChatLine(role: .error, text: "turn \(status)" + (c.error.map { ": \($0)" } ?? "")))
        }
        busy = false
    }

    /// The bot text of the latest turn's last bubble (evidence logging).
    public var lastBotText: String { lines.last(where: { $0.role == .bot })?.text ?? "" }

    // MARK: - internals

    /// A turn this client did not start (another client such as Hermes Desktop prompted the shared Bot
    /// Chat): it streams as bot bubbles with no local user line, and holds the submit gate like a local
    /// turn until it completes, fails or the socket drops.
    private mutating func beginRemoteTurnIfIdle() {
        guard !busy, liveIndex == nil else { return }
        busy = true
        turnSerial += 1; turnIsLocal = false
        segments = []; interimBoundary = 0
    }

    private mutating func live() -> Int {
        if let i = liveIndex { return i }
        lines.append(ChatLine(role: .bot, text: "", streaming: true))
        liveIndex = lines.count - 1
        return liveIndex!
    }

    private mutating func sealLive() {
        guard let i = liveIndex else { return }
        if lines[i].text.isEmpty { lines.remove(at: i) } else { lines[i].streaming = false }
        liveIndex = nil; liveSeeded = false
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
