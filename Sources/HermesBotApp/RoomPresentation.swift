import HermesGatewayKit
import SwiftUI

// Presentation of a Group Chat for the views: timeline rows (passes folded, round ends as dividers) and
// the turn ribbon's per-member states. Pure functions over the same `RoomTimeline` / `RoomDriverStatus`
// the approved `RoomModel` publishes; nothing here talks to the backend or changes room state.

struct RoomRow: Identifiable, Equatable {
    struct Pass: Equatable, Identifiable {
        let seq: Int
        let memberId: String?
        let author: String
        var id: Int { seq }
    }

    enum Kind: Equatable {
        case user(text: String)
        case member(memberId: String?, author: String, text: String)
        /// Consecutive `turn.settled {passed: true}` lines folded into one thin row.
        case passes([Pass])
        /// `room.activity` (discussion settled/ended), `room.stop_requested`, `room.renamed`.
        case divider(text: String)
        case status(memberId: String?, author: String, text: String)
        case failure(memberId: String?, author: String, text: String)
    }

    /// The seq of the first event in the row (stable while a pass row grows).
    let id: Int
    let kind: Kind
    let time: Double
    /// The thread of the row's event (`main` for the room composer's messages).
    var threadId: String = RoomThreads.main

    /// A user or member message: the rows that carry per-message actions and a thread label.
    var isMessage: Bool {
        switch kind {
        case .user, .member: return true
        default: return false
        }
    }
}

enum RoomPresentation {
    /// Rows from the kit's `RoomTimeline.lines` (texts unchanged), enriched with the member id and time
    /// of the event each line came from.
    static func rows(lines: [RoomLine], events: [RoomEvent]) -> [RoomRow] {
        let bySeq = Dictionary(events.map { ($0.seq, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [RoomRow] = []
        for line in lines {
            let e = bySeq[line.id]
            let time = e?.createdAt ?? 0
            switch line.kind {
            case .user:
                out.append(RoomRow(id: line.id, kind: .user(text: line.text), time: time, threadId: line.threadId))
            case .member:
                out.append(RoomRow(id: line.id, kind: .member(memberId: e?.memberId, author: line.author, text: line.text), time: time,
                                   threadId: line.threadId))
            case .error:
                out.append(RoomRow(id: line.id, kind: .failure(memberId: e?.memberId, author: line.author, text: line.text), time: time))
            case .status:
                if e?.kind == "turn.settled" {
                    let pass = RoomRow.Pass(seq: line.id, memberId: e?.memberId, author: line.author)
                    if let last = out.last, case .passes(let ps) = last.kind {
                        out[out.count - 1] = RoomRow(id: last.id, kind: .passes(ps + [pass]), time: last.time)
                    } else {
                        out.append(RoomRow(id: line.id, kind: .passes([pass]), time: time))
                    }
                } else if let e, ["room.activity", "room.stop_requested", "room.renamed"].contains(e.kind) {
                    out.append(RoomRow(id: line.id, kind: .divider(text: dividerText(e, fallback: line.text)), time: time))
                } else {
                    out.append(RoomRow(id: line.id, kind: .status(memberId: e?.memberId, author: line.author, text: line.text), time: time))
                }
            }
        }
        return out
    }

    /// Divider label in plain words. The kit line keeps the backend's `reason_code` (for logs and tests);
    /// the timeline shows what it means: `silent_round` is the normal end (every bot passed), the
    /// `max_*` codes are limits (`gateway/hosted_room_discussion.py` decide()).
    static func dividerText(_ e: RoomEvent, fallback: String) -> String {
        switch e.kind {
        case "room.activity":
            let status = e.payload["status"]?.string, reason = e.payload["reason_code"]?.string
            if status == "settled" { return "Discussion settled" }
            if status == "bounded" {
                // A bounded discussion is a per-message budget, not an account quota or a full room:
                // the next user message opens a fresh one. (pass) replies do not count toward it.
                switch reason {
                case "max_rounds": return "Round limit reached for this discussion. Send a new message to continue."
                case "max_messages": return "Reply limit reached for this discussion. Send a new message to continue."
                default: return "Limit reached for this discussion. Send a new message to continue."
                }
            }
            return capitalizedFirst(fallback)
        case "room.stop_requested": return "Stopped"
        case "room.renamed": return "Renamed to \(e.payload["name"]?.string ?? "?")"
        default: return capitalizedFirst(fallback)
        }
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// What Copy puts on the pasteboard for a message row: the text as written. A user message's files are
    /// listed after its text, one path per line (the attachments block itself is wire format). Nil for rows
    /// that are not messages.
    static func copyText(_ row: RoomRow) -> String? {
        switch row.kind {
        case .member(_, _, let text): return text
        case .user(let text):
            // The quote an anchored thread's first message opens with is not the user's text.
            let parts = RoomAttachments.split(text)
            let body = row.threadId == RoomThreads.main ? parts.text : RoomThreads.body(of: parts.text)
            return ([body] + parts.paths).filter { !$0.isEmpty }.joined(separator: "\n")
        default: return nil
        }
    }

    /// The label of a thread: its first message, on one line, cut short; "Thread" when that is empty.
    static func threadTitle(_ thread: RoomThreadSummary?) -> String {
        let text = RoomDigest.previewText(thread?.title ?? "")
        let short = text.count > threadTitleLimit ? String(text.prefix(threadTitleLimit - 1)) + "…" : text
        return short.isEmpty ? "Thread" : short
    }

    static let threadTitleLimit = 48

    /// "1 reply" / "3 replies" under a message a thread hangs off.
    static func replyCount(_ n: Int) -> String { n == 1 ? "1 reply" : "\(n) replies" }

    static func passText(_ passes: [RoomRow.Pass]) -> String {
        let names = passes.map(\.author)
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) passed"
        default: return names.dropLast().joined(separator: ", ") + " and \(names.last!) passed"
        }
    }

    // MARK: turn ribbon

    /// What the ribbon shows for one member. Every state comes from the log or `groups.state`:
    /// `groups.state` reports working counts for the room, not which member is generating, so there is
    /// no per-member "typing" state.
    enum MemberState: String, Equatable {
        case idle, waiting, replied, passed, cancelled, failed, deferred, needsApproval

        /// Waiting on the user: drawn with the `attention` role, the most urgent chip in the ribbon.
        var needsUser: Bool { self == .needsApproval || self == .deferred }

        var label: String {
            switch self {
            case .idle: return "idle"
            case .waiting: return "waiting"
            case .replied: return "replied"
            case .passed: return "passed"
            case .cancelled: return "cancelled"
            case .failed: return "failed"
            case .deferred: return "needs retry"
            case .needsApproval: return "needs approval"
            }
        }
    }

    /// Member states for the latest user message: a pending approval naming the member wins; else the
    /// member's latest `turn.*` for that discussion; else `waiting` while the discussion is pending, `idle`
    /// otherwise (or before any message).
    static func memberStates(room: RoomSummary, timeline: RoomTimeline, driver: RoomDriverStatus?) -> [String: MemberState] {
        let approvals = Set((driver?.pendingActions ?? []).compactMap { a -> String? in
            if case .approval(let x) = a { return x.memberId }
            return nil
        })
        let latest = timeline.userMessages.last
        let terminals = latest.map { timeline.terminals(of: $0) } ?? []
        let pending = latest.map { timeline.phase(of: $0) == .pending } ?? false
        var out: [String: MemberState] = [:]
        for m in room.members {
            if approvals.contains(m.memberId) { out[m.memberId] = .needsApproval; continue }
            let t = terminals.last(where: { $0.memberId == m.memberId })
            out[m.memberId] = t.flatMap(turnState) ?? (pending ? .waiting : .idle)
        }
        return out
    }

    /// The state a `turn.*` event leaves its member in; nil for any other kind. Shared by the ribbon and the
    /// Activity panel's "This round" list, so both say the same thing.
    static func turnState(_ e: RoomEvent) -> MemberState? {
        switch e.kind {
        case "turn.settled": return e.payload["passed"]?.bool == true ? .passed : .replied
        case "turn.cancelled": return .cancelled
        case "turn.failed": return .failed
        case "turn.deferred": return .deferred
        default: return nil
        }
    }

    /// The room-level chip that leads the ribbon (same rules as the M2 status pill).
    struct RoomStatus: Equatable {
        enum Tone: Equatable { case quiet, working, blocked }
        let text: String
        let tone: Tone
    }

    @MainActor static func roomStatus(_ model: RoomModel) -> RoomStatus {
        if model.disbanded { return RoomStatus(text: "Disbanded", tone: .quiet) }
        if model.composer.availability == .closing { return RoomStatus(text: "Disbanding…", tone: .quiet) }
        guard let d = model.driver else {
            return RoomStatus(text: model.lastSync == nil ? "Loading…" : "No worker", tone: .quiet)
        }
        // Plain counts ("1 running, 2 queued"), in the order a turn moves through them.
        let order = ["running", "queued", "stopping", "indeterminate", "deferred"]
        let counts = order.compactMap { k in d.counts[k].flatMap { $0 > 0 ? "\($0) \(k)" : nil } }.joined(separator: ", ")
        if d.blocked { return RoomStatus(text: "Blocked" + (counts.isEmpty ? "" : " · \(counts)"), tone: .blocked) }
        if d.working { return RoomStatus(text: counts.isEmpty ? "Working" : "Working · \(counts)", tone: .working) }
        if model.timeline.awaitingDiscussion { return RoomStatus(text: "Waiting for bots", tone: .working) }
        return RoomStatus(text: "Idle" + (counts.isEmpty ? "" : " · \(counts)"), tone: .quiet)
    }
}

/// A `RoomModel` note in plain words. Notes are the model's log lines (`groups.approve once → resolved`,
/// `stop failed: …`); the model and its log keep them verbatim, only the note bar rewrites them.
struct RoomNote: Equatable {
    let text: String
    let failed: Bool

    init(_ raw: String) {
        let lower = raw.lowercased()
        failed = lower.contains("failed") || lower.contains("not posted")
        text = Self.humanize(raw)
    }

    static func humanize(_ raw: String) -> String {
        if raw.hasPrefix("groups.approve ") {
            return raw.contains("approve deny") ? "Denied. The bot was told not to run it." : "Approved once. The bot continues."
        }
        if raw.hasPrefix("groups.stop → cancelled "),
           let n = Int(raw.dropFirst("groups.stop → cancelled ".count).prefix(while: \.isNumber)) {
            return n == 0 ? "Stopped. No turn was running." : "Stopped \(n) running turn\(n == 1 ? "" : "s")."
        }
        if raw.hasPrefix("groups.retry → ") { return "Retry sent (\(raw.dropFirst("groups.retry → ".count)))." }
        if raw.hasPrefix("groups.rename → ") { return "Renamed to \(raw.dropFirst("groups.rename → ".count))." }
        if raw == "disbanded" { return "Room disbanded." }
        if raw.hasPrefix("send failed, message not posted: ") {
            return "Message not sent: " + raw.dropFirst("send failed, message not posted: ".count)
        }
        if let r = raw.range(of: " failed: ") {
            let key = raw[..<r.lowerBound], rest = raw[r.upperBound...]
            let what: String
            switch true {
            case key.hasPrefix("approval:"): what = "Approval"
            case key.hasPrefix("retry:"): what = "Retry"
            case key == "stop": what = "Stop"
            case key == "sync": what = "Sync"
            case key == "disband": what = "Disband"
            default: what = RoomPresentation.capitalizedFirst(String(key))
            }
            return "\(what) failed: \(rest)"
        }
        return RoomPresentation.capitalizedFirst(raw)
    }
}

/// One-shot motion bookkeeping per room, kept outside the views so it survives reopening a room
/// (DESIGN.md "Motion": keyed to the event that caused it, never replayed by a reopen, an identical
/// poll, or toggling motion).
@MainActor
final class RoomMotionMemory: ObservableObject {
    private static var rooms: [String: RoomMotionMemory] = [:]
    static func of(_ roomId: String) -> RoomMotionMemory {
        if let m = rooms[roomId] { return m }
        let m = RoomMotionMemory(); rooms[roomId] = m; return m
    }

    /// The log cursor when this room was first shown with data: only rows after it animate in.
    private(set) var baseline: Int?
    /// Approval request ids whose ring already played.
    private var ringed: Set<String> = []
    /// Bumped when a member's ribbon state changes after the baseline; drives the chip bounce.
    @Published private(set) var bumps: [String: Int] = [:]
    private var lastStates: [String: RoomPresentation.MemberState] = [:]

    func setBaselineIfNeeded(_ cursor: Int) { if baseline == nil { baseline = cursor } }

    func isNew(_ seq: Int) -> Bool { baseline.map { seq > $0 } ?? false }

    func shouldRing(_ requestId: String) -> Bool { ringed.insert(requestId).inserted }

    func observe(_ states: [String: RoomPresentation.MemberState]) {
        defer { lastStates = states }
        guard baseline != nil else { return }
        for (member, s) in states where lastStates[member] != nil && lastStates[member] != s {
            bumps[member, default: 0] += 1
        }
    }
}
