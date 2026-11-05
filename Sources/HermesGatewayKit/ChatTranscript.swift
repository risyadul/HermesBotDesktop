import Foundation

public struct ChatLine: Identifiable, Sendable, Equatable {
    /// `tool`: one tool call (`tool` carries its state); `system`: client notes such as slash output;
    /// `thought`: the bot's reasoning for one step (`reasoning.delta`, history `reasoning`), shown collapsed.
    public enum Role: Sendable, Equatable { case user, bot, error, tool, system, thought }
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
    /// Connector label (`App · action`) from `labels`, shown instead of the tool name.
    public var label: String?
    public var args: JSONValue?
    /// Live calls only: history does not carry results.
    public var result: JSONValue?
    public var inlineDiff: String?

    public init(toolId: String, name: String, state: State, duration: Double? = nil, summary: String? = nil,
                label: String? = nil, args: JSONValue? = nil, result: JSONValue? = nil, inlineDiff: String? = nil) {
        self.toolId = toolId; self.name = name; self.state = state; self.duration = duration; self.summary = summary
        self.label = label; self.args = args; self.result = result; self.inlineDiff = inlineDiff
    }
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
    /// The Thought line still receiving `reasoning.delta` (sealed by text, a tool or the end of the turn).
    private var thoughtIndex: Int?
    /// Index of the first line of the running turn (`reasoning.available` looks for text after it).
    private var turnStart = 0
    /// The live bubble came from a resume snapshot (`resumeRunningTurn`), not from deltas seen here.
    private var liveSeeded = false
    /// The user line of the latest local turn (`retractUnsent`).
    private var unsentUserId: UUID?
    private var segments: [String] = []
    private var interimBoundary = 0
    /// The latest `redirect`: its user line and the live bubble it sealed (reopened by `retract`).
    private var redirectUser: UUID?
    private var redirectSealed: UUID?

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
        thoughtIndex = nil; turnStart = lines.count
        return text
    }

    /// The submit of the turn `beginTurn` just accepted failed before reaching the backend: its user line
    /// is removed (the caller restores the draft, so a resend does not show it twice) and the turn fails.
    public mutating func retractUnsent(_ message: String) {
        if let id = unsentUserId, let i = lines.firstIndex(where: { $0.id == id }) {
            removeLine(at: i)
            if turnStart > i { turnStart -= 1 }
        }
        unsentUserId = nil
        fail(message)
    }

    /// A correction for the running turn (`session.redirect`), recorded before the RPC goes out because the
    /// redirect aborts the model request and its events can race the reply (Desktop `use-prompt-actions`):
    /// what streamed so far is sealed as its own segment, the user's line goes below it, and the turn's next
    /// output lands below that. The turn stays busy. Returns the line's id (`retract` takes it back when the
    /// backend refused), nil when no turn runs or the text is blank.
    public mutating func redirect(_ raw: String) -> UUID? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard busy, !text.isEmpty else { return nil }
        sealThought()
        let sealed = liveIndex.map { lines[$0].id }
        flushLiveAsSegment()
        draftingTool = nil
        let line = ChatLine(role: .user, text: text)
        redirectUser = line.id
        redirectSealed = sealed.flatMap { id in lines.contains { $0.id == id } ? id : nil }
        lines.append(line)
        turnStart = lines.count
        return line.id
    }

    /// Removes a line added by `redirect` whose correction never reached the turn. When nothing arrived
    /// after it, the bubble the redirect sealed becomes live again, so the reply keeps growing in one piece.
    public mutating func retract(_ id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        let sealedBot = redirectUser == id ? redirectSealed : nil
        if redirectUser == id { redirectUser = nil; redirectSealed = nil }
        let wasLast = i == lines.count - 1
        removeLine(at: i)
        if turnStart > i { turnStart -= 1 }
        guard busy, wasLast, liveIndex == nil, thoughtIndex == nil, let bot = sealedBot, let b = lines.indices.last,
              lines[b].id == bot, segments.last == lines[b].text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        segments.removeLast()
        interimBoundary = min(interimBoundary, segments.count)
        lines[b].streaming = true
        liveIndex = b
    }

    /// Ends a running turn this client gave up waiting on (Stop sent, no settling event arrived) with a
    /// neutral note instead of an error.
    public mutating func abandon(_ note: String) {
        guard busy else { return }
        sealLive()
        sealThought()
        settleTools(.failed)
        busy = false
        appendSystem(note)
    }

    /// Replaces the transcript with a resumed session's history (idle only; returns false while busy).
    /// User / assistant rows become bubbles, tool rows settled tool lines, system rows system lines.
    @discardableResult
    public mutating func seed(history: [ChatHistoryMessage]) -> Bool {
        guard !busy else { return false }
        liveIndex = nil; liveSeeded = false; segments = []; interimBoundary = 0; draftingTool = nil; thoughtIndex = nil
        lines = history.flatMap { m -> [ChatLine] in
            switch m.role {
            case .user: return [ChatLine(role: .user, text: m.text)]
            case .assistant:
                // A step's reasoning comes before its text, as Desktop rebuilds it (`hydration.ts:478-513`).
                let thought = m.reasoning.map { ChatLine(role: .thought, text: $0) }
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ChatLine(role: .bot, text: m.text)
                return [thought, text].compactMap { $0 }
            case .system: return [ChatLine(role: .system, text: m.text)]
            case .tool:
                let name = m.toolName ?? "tool"
                return [ChatLine(role: .tool, text: m.toolContext ?? "",
                                 tool: ToolLine(toolId: "", name: name, state: .done, label: m.toolLabel, args: m.toolArgs))]
            }
        }
        turnStart = lines.count
        return true
    }

    /// Joins a turn that was already running when the chat was resumed (Hermes Desktop or an earlier
    /// launch started it): the gate closes (busy), the turn's user line is shown unless the history already
    /// ends with it, and what streamed so far becomes the live bubble the next deltas grow.
    public mutating func resumeRunningTurn(_ t: InflightTurn) {
        busy = true
        turnSerial += 1; turnIsLocal = false
        segments = []; interimBoundary = 0; draftingTool = nil; thoughtIndex = nil
        let user = t.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty, lines.last.map({ $0.role == .user && $0.text == user }) != true {
            lines.append(ChatLine(role: .user, text: user))
        }
        turnStart = lines.count
        lines.append(ChatLine(role: .bot, text: t.assistant, streaming: true))
        liveIndex = lines.count - 1
        liveSeeded = true
    }

    /// Adds a client-side note (slash command output, notices). Turn state is untouched.
    public mutating func appendSystem(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = [liveIndex, thoughtIndex].compactMap({ $0 }).min() {
            // Keep the live bubble and Thought last so the turn's deltas keep growing them.
            lines.insert(ChatLine(role: .system, text: t), at: i)
            liveIndex = liveIndex.map { $0 + 1 }; thoughtIndex = thoughtIndex.map { $0 + 1 }
        } else {
            lines.append(ChatLine(role: .system, text: t))
        }
    }

    /// Ends the turn with an error (send failed, `error` event, socket gone).
    public mutating func fail(_ message: String) {
        sealLive()
        sealThought()
        settleTools(.failed)
        lines.append(ChatLine(role: .error, text: message))
        busy = false
    }

    public mutating func apply(_ e: ChatEvent) {
        switch e {
        case .started:
            beginRemoteTurnIfIdle()
            sealThought()
            _ = live()
        case .delta(let d):
            guard !d.isEmpty else { return }
            beginRemoteTurnIfIdle()
            sealThought()
            let i = live()
            lines[i].text += d
            deltaCount += 1
        case .interim(let text, _):
            let t = Self.trimLeading(text)
            guard !t.isEmpty else { return }
            sealThought()
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
        case .reasoning(let d):
            guard !d.isEmpty else { return }
            beginRemoteTurnIfIdle()
            appendReasoning(d)
        case .reasoningAvailable(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, busy || liveIndex != nil else { return }
            replaceReasoning(text)
        case .status, .other, .request, .requestCancelled, .approvalsCancelled, .resumed, .info, .usage:
            break
        }
    }

    /// Flushes what streamed so far before the row (ordering), sealing it as a segment the final text
    /// may repeat (deduplicated by `finalTail` like a kept streamed bubble), then adds a running row.
    private mutating func startTool(_ t: ToolStart) {
        sealThought()
        flushLiveAsSegment()
        if !t.toolId.isEmpty, let i = toolIndex(t.toolId) {
            lines[i].tool?.state = .running
            return
        }
        lines.append(ChatLine(role: .tool, text: t.context ?? t.label ?? "",
                              tool: ToolLine(toolId: t.toolId, name: t.name, state: .running, label: t.label, args: t.args)))
    }

    /// `reasoning.delta`: grows the open Thought, or opens one. Text streaming in the live bubble is a step
    /// that ended (new reasoning starts the next step), so it is sealed as a segment first, as `startTool` does.
    private mutating func appendReasoning(_ d: String) {
        if let i = thoughtIndex { lines[i].text += d; return }
        // Whitespace before any reasoning opens nothing: an empty "Thinking" row would only flicker.
        let first = Self.trimLeading(d)
        guard !first.isEmpty else { return }
        flushLiveAsSegment()
        lines.append(ChatLine(role: .thought, text: first, streaming: true))
        thoughtIndex = lines.count - 1
    }

    /// `reasoning.available`: the step's think-tag content, stripped and cut to 500 characters by the backend
    /// (`agent/turn_response_intake.py:103-117`), for providers that do not stream reasoning. As in Desktop
    /// (`use-message-stream/index.ts:515-545`) it is used only while the turn shows no reply text yet. A
    /// Thought already streaming for this step is kept (the event would only truncate it); otherwise the
    /// step gets its own Thought at the end, after any earlier step's Thought and tools.
    private mutating func replaceReasoning(_ text: String) {
        guard thoughtIndex == nil else { return }
        let turn = min(turnStart, lines.count)..<lines.count
        guard !lines[turn].contains(where: { $0.role == .bot && !$0.text.isEmpty }) else { return }
        // An empty bubble from `message.start` goes, so the reply text that follows lands below the Thought.
        flushLiveAsSegment()
        lines.append(ChatLine(role: .thought, text: text.trimmingCharacters(in: .whitespacesAndNewlines), streaming: true))
        thoughtIndex = lines.count - 1
    }

    private mutating func sealThought() {
        guard let i = thoughtIndex else { return }
        thoughtIndex = nil
        if lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { removeLine(at: i) } else { lines[i].streaming = false }
    }

    /// Seals what streamed so far as a segment the final text may repeat (deduplicated by `finalTail`).
    private mutating func flushLiveAsSegment() {
        guard let i = liveIndex else { return }
        let tail = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveIndex = nil; liveSeeded = false
        if tail.isEmpty { removeLine(at: i) } else { lines[i].streaming = false; segments.append(tail) }
    }

    private mutating func completeTool(_ c: ToolCompletion) {
        let state: ToolLine.State = c.failed ? .failed : .done
        if !c.toolId.isEmpty, let i = toolIndex(c.toolId) {
            lines[i].tool?.state = state
            lines[i].tool?.duration = c.duration
            lines[i].tool?.summary = c.summary
            lines[i].tool?.result = c.result
            lines[i].tool?.inlineDiff = c.inlineDiff
            if lines[i].tool?.args == nil { lines[i].tool?.args = c.args }
            if lines[i].tool?.label == nil { lines[i].tool?.label = c.label }
            return
        }
        // No start seen (joined mid-turn): upsert a settled row, before the live bubble or Thought if any.
        let line = ChatLine(role: .tool, text: "", tool: ToolLine(toolId: c.toolId, name: c.name, state: state,
                                                                  duration: c.duration, summary: c.summary, label: c.label,
                                                                  args: c.args, result: c.result, inlineDiff: c.inlineDiff))
        if let i = [liveIndex, thoughtIndex].compactMap({ $0 }).min() {
            lines.insert(line, at: i)
            liveIndex = liveIndex.map { $0 + 1 }; thoughtIndex = thoughtIndex.map { $0 + 1 }
        } else { lines.append(line) }
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
        sealThought()
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
            liveIndex = nil
            if shown.isEmpty {
                removeLine(at: i)
            } else {
                lines[i].text = shown; lines[i].streaming = false
            }
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
        thoughtIndex = nil; turnStart = lines.count
    }

    private mutating func live() -> Int {
        if let i = liveIndex { return i }
        lines.append(ChatLine(role: .bot, text: "", streaming: true))
        liveIndex = lines.count - 1
        return liveIndex!
    }

    private mutating func sealLive() {
        guard let i = liveIndex else { return }
        liveIndex = nil; liveSeeded = false
        if lines[i].text.isEmpty { removeLine(at: i) } else { lines[i].streaming = false }
    }

    /// Every removal of a transcript line goes through here so the held indices (live bubble, open
    /// Thought) keep pointing at their lines.
    private mutating func removeLine(at i: Int) {
        lines.remove(at: i)
        if let l = liveIndex { liveIndex = l > i ? l - 1 : (l == i ? nil : l) }
        if let t = thoughtIndex { thoughtIndex = t > i ? t - 1 : (t == i ? nil : t) }
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
