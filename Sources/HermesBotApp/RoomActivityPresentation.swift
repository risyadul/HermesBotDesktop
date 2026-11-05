import Foundation
import HermesGatewayKit

// What the Activity panel shows, derived from `bot-activity` rows (unit tested). Tool rows reuse the Bot Chat
// tool row (`ToolActivityRow` over a `.tool` `ChatLine`), reasoning reuses `ThoughtRow`; the rest are small
// panel rows. Nothing here talks to the backend.

/// One row of a member's activity list.
struct ActivityItem: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A tool call, as a `.tool` line for `ToolActivityRow`.
        case tool(ChatLine)
        /// Reasoning, as a `.thought` line for `ThoughtRow`.
        case reasoning(ChatLine)
        /// Reply text as it streams (the tail the plugin keeps).
        case message(text: String, streaming: Bool)
        /// An LLM turn starting or finishing: a subtle separator.
        case turn(title: String?, finished: Bool, duration: String?)
        case error(title: String, detail: String?)
        case approval(title: String, status: String)
        case other(title: String, status: String?)
    }

    /// The row's `key`.
    let id: String
    let kind: Kind
    let time: Double

    /// The reused transcript line (tool and reasoning rows).
    var line: ChatLine? {
        switch kind {
        case .tool(let l), .reasoning(let l): return l
        default: return nil
        }
    }

    var isError: Bool {
        switch kind {
        case .error: return true
        case .tool(let l): return l.tool?.state == .failed
        default: return false
        }
    }
}

/// Look of a panel status chip: activity phases and (fallback) turn states share it.
struct ActivityStatus: Equatable {
    enum Tone: Equatable {
        /// Muted label, no fill (idle, passed, cancelled).
        case quiet
        /// Working dots before an ink label.
        case working
        /// Muted label with a bot-colour hairline (`waiting` for a turn).
        case waiting
        /// Ink label (replied, writing, thinking).
        case done
        /// Attention fill, ring and semibold label: waiting on the user.
        case attention
        /// Danger label and ring.
        case danger
    }

    let label: String
    let symbol: String?
    let tone: Tone
}

enum ActivityPresentation {
    // MARK: rows

    /// `row` as a panel item. `reusing` is the line built for the same key before: its id (and with it the
    /// row's disclosure state and SwiftUI identity) is kept while its content follows the newest rev.
    static func item(_ row: BotActivityRow, now: Double, reusing old: ChatLine? = nil) -> ActivityItem {
        let kind: ActivityItem.Kind
        switch row.kind {
        case "tool":
            var line = old.flatMap { $0.role == .tool ? $0 : nil } ?? ChatLine(role: .tool, text: "")
            line.text = ""
            line.tool = toolLine(row)
            kind = .tool(line)
        case "reasoning":
            var line = old.flatMap { $0.role == .thought ? $0 : nil } ?? ChatLine(role: .thought, text: "")
            line.text = row.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            line.streaming = isStreaming(row, now: now)
            kind = .reasoning(line)
        case "message":
            kind = .message(text: (row.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            streaming: isStreaming(row, now: now))
        case "turn":
            kind = .turn(title: row.title.map { ToolRowPresentation.oneLine($0, limit: 80) }, finished: row.status != "running",
                         duration: row.durationMs.map { ToolRowPresentation.format(Double($0) / 1000) })
        case "error":
            kind = .error(title: row.title ?? "Turn failed", detail: row.text)
        case "approval":
            kind = .approval(title: row.title ?? "Approval requested", status: approvalStatus(row.status))
        default:
            if row.status == "error" {
                kind = .error(title: row.title ?? row.kind, detail: row.text)
            } else {
                kind = .other(title: row.title ?? (row.kind.isEmpty ? "activity" : row.kind), status: row.status)
            }
        }
        return ActivityItem(id: row.key, kind: kind, time: row.ts)
    }

    /// The plugin row as a Bot Chat tool line: `title` is the tool name, `args`/`result` are JSON (or the raw
    /// text), `duration_ms` → seconds. `running` stays running, `error` is failed, anything else done.
    static func toolLine(_ row: BotActivityRow) -> ToolLine {
        let state: ToolLine.State
        switch row.status {
        case "running", "waiting": state = .running
        case "error": state = .failed
        default: state = .done
        }
        return ToolLine(toolId: row.key, name: row.title ?? "tool", state: state,
                        duration: row.durationMs.map { Double($0) / 1000 }, args: row.args, result: row.result)
    }

    /// A stream with no update within the plugin's quiet window is done (rooms have no end frame).
    static func isStreaming(_ row: BotActivityRow, now: Double) -> Bool {
        row.status == "streaming" && now - row.updated < BotActivityAPI.streamQuiet
    }

    static func approvalStatus(_ status: String?) -> String {
        switch status {
        case "waiting": return "waiting for approval"
        case "approved": return "approved"
        case "deny": return "denied"
        case "timeout": return "timed out"
        case nil: return "requested"
        case let s?: return s
        }
    }

    // MARK: header

    /// The member's live phase as a chip.
    static func status(_ phase: BotActivityPhase, current: BotActivityRow?) -> ActivityStatus {
        switch phase {
        case .waiting: return ActivityStatus(label: "waiting for approval", symbol: "hand.raised.fill", tone: .attention)
        case .running: return ActivityStatus(label: "working", symbol: nil, tone: .working)
        case .streaming:
            return ActivityStatus(label: current?.kind == "reasoning" ? "thinking" : "writing", symbol: nil, tone: .done)
        case .idle: return ActivityStatus(label: "idle", symbol: nil, tone: .quiet)
        }
    }

    /// The fallback chip: the ribbon's turn state (`RoomPresentation.memberStates`), drawn as `MemberChip` draws it.
    static func status(_ state: RoomPresentation.MemberState) -> ActivityStatus {
        switch state {
        case .needsApproval: return ActivityStatus(label: state.label, symbol: "hand.raised.fill", tone: .attention)
        case .deferred: return ActivityStatus(label: state.label, symbol: "arrow.clockwise", tone: .attention)
        case .failed: return ActivityStatus(label: state.label, symbol: "exclamationmark.triangle.fill", tone: .danger)
        case .replied: return ActivityStatus(label: state.label, symbol: "checkmark", tone: .done)
        case .waiting: return ActivityStatus(label: state.label, symbol: nil, tone: .waiting)
        case .idle, .passed, .cancelled: return ActivityStatus(label: state.label, symbol: nil, tone: .quiet)
        }
    }

    /// Fallback chips per member id, from the same turn states the ribbon shows (C1.3).
    static func fallbackStatuses(room: RoomSummary, timeline: RoomTimeline, driver: RoomDriverStatus?) -> [String: ActivityStatus] {
        RoomPresentation.memberStates(room: room, timeline: timeline, driver: driver).mapValues { status($0) }
    }

    /// What the member is doing now, e.g. "Ran git status" (the elapsed time is added live by the view).
    static func currentLabel(_ row: BotActivityRow) -> String {
        switch row.kind {
        case "tool": return ToolRowPresentation(ChatLine(role: .tool, text: "", tool: toolLine(row))).title
        case "reasoning": return "Thinking"
        case "message": return "Writing a reply"
        case "approval": return row.title ?? "Approval requested"
        case "turn": return "Working on a turn"
        default: return row.title ?? row.kind
        }
    }

    /// "terminal · 12s" style: the current label and the time since the row started.
    static func currentText(_ row: BotActivityRow, now: Double) -> String {
        "\(currentLabel(row)) · \(ToolRowPresentation.format(max(0, now - row.ts)))"
    }
}

/// One entry of the "This round" list shown without the plugin: what the room log (and `groups.state`) says
/// about the latest user message, newest first.
struct RoundEntry: Equatable, Identifiable {
    let id: String
    /// nil for a room-level entry (round started, bots working, settled, stopped).
    let memberId: String?
    /// The member's name, or "Round".
    let title: String
    let status: ActivityStatus
    /// `created_at` of the log event; nil for live `groups.state` facts (they sort first).
    let time: Double?
}

extension ActivityPresentation {
    static let roundLimit = 30

    /// The Turn Off confirmation: exactly what `RoomActivityModel.turnOff()` does.
    static let turnOffConfirmation = "Disables the Bot Activity plugin in every bot profile and removes it from Hermes. "
        + "The bots' copies stay on disk but inactive; Enable Tracking turns them back on. "
        + "This panel then shows only each bot's turn status."
    static let reinstallConfirmation = "Replaces the installed Bot Activity plugin with the reviewed commit "
        + "\(BotActivityPluginManager.pinnedRef.prefix(7)) from github.com/risyadul/hermes-bot-activity, "
        + "then turns it on for every bot."

    /// The live chips of a member: its activity phase, plus its turn state from the timeline, so a live idle or
    /// working never hides "needs approval", "needs retry" or "failed". Attention/danger turn states lead; an
    /// idle turn state, or a "waiting" one while the live phase says more, adds nothing; an approval both
    /// sources report shows once.
    static func chips(phase: BotActivityPhase, current: BotActivityRow?, turn: RoomPresentation.MemberState?) -> [ActivityStatus] {
        let live = status(phase, current: current)
        guard let turn, turn != .idle, !(turn == .waiting && phase != .idle),
              !(turn == .needsApproval && phase == .waiting) else { return [live] }
        let t = status(turn)
        return t.tone == .attention || t.tone == .danger ? [t, live] : [live, t]
    }

    /// "This round" (C1.3, no plugin): the latest user message's round as the room log tells it, built from the
    /// same events and turn-state mapping as the ribbon (`RoomPresentation.turnState`): queued when the message
    /// arrived, each member's `turn.*` (replied / passed / failed / timed out / cancelled / needs retry), the
    /// round settling or stopping; on top, pending approvals and "working" while the round is still open.
    /// Newest first, at most `limit`.
    static func roundFeed(room: RoomSummary, timeline: RoomTimeline, driver: RoomDriverStatus?,
                          limit: Int = roundLimit) -> [RoundEntry] {
        guard let user = timeline.userMessages.last else { return [] }
        func name(_ id: String?) -> String { room.member(id)?.title ?? id ?? "bot" }
        let phase = timeline.phase(of: user)
        var log: [RoundEntry] = [RoundEntry(id: "queued:\(user.seq)", memberId: nil, title: "Round",
                                            status: ActivityStatus(label: "queued", symbol: nil, tone: .waiting), time: user.createdAt)]
        for e in timeline.events where e.seq > user.seq {
            if e.kind.hasPrefix("turn."), e.discussionEventId == user.eventId, let state = RoomPresentation.turnState(e) {
                log.append(RoundEntry(id: "turn:\(e.seq)", memberId: e.memberId, title: name(e.memberId),
                                      status: timedOut(e) ? timedOutStatus : status(state), time: e.createdAt))
            } else if e.kind == "room.activity", e.discussionEventId == user.eventId {
                let bounded = e.payload["status"]?.string == "bounded"
                log.append(RoundEntry(id: "round:\(e.seq)", memberId: nil, title: "Round",
                                      status: ActivityStatus(label: bounded ? "ended (limit)" : "settled", symbol: nil, tone: .quiet),
                                      time: e.createdAt))
            } else if e.kind == "room.stop_requested", phase == .stopped {
                log.append(RoundEntry(id: "stop:\(e.seq)", memberId: nil, title: "Round",
                                      status: ActivityStatus(label: "stopped", symbol: nil, tone: .quiet), time: e.createdAt))
            }
        }
        var live: [RoundEntry] = []
        for case .approval(let a) in driver?.pendingActions ?? [] {
            live.append(RoundEntry(id: "approval:\(a.taskId):\(a.requestId)", memberId: a.memberId, title: name(a.memberId),
                                   status: status(RoomPresentation.MemberState.needsApproval), time: nil))
        }
        if phase == .pending, driver?.working == true {
            live.append(RoundEntry(id: "working:\(user.seq)", memberId: nil, title: "Round",
                                   status: ActivityStatus(label: "working", symbol: nil, tone: .working), time: nil))
        }
        return Array((live + log.reversed()).prefix(max(0, limit)))
    }

    static let timedOutStatus = ActivityStatus(label: "timed out", symbol: "clock.badge.exclamationmark", tone: .danger)

    /// A failed/cancelled turn whose reason or error says it ran out of time.
    static func timedOut(_ e: RoomEvent) -> Bool {
        guard e.kind == "turn.failed" || e.kind == "turn.cancelled" else { return false }
        let text = [e.payload["reason"]?.string, e.payload["error"]?.string].compactMap { $0?.lowercased() }.joined(separator: " ")
        return text.contains("timeout") || text.contains("timed out") || text.contains("timed_out")
    }
}
