import Foundation

/// What a room's sidebar row shows without opening the room: the last message (preview + age) and
/// whether a bot is waiting on the user. Built from the newest events of the room's log (a tail is
/// enough: everything here looks at the latest messages only). UI-free and unit tested.
public struct RoomDigest: Sendable, Equatable {
    public struct Preview: Sendable, Equatable {
        /// "You" or the member's name.
        public let author: String
        /// One line: attachments block removed, whitespace folded, cut at `RoomDigest.previewLimit`.
        public let text: String
        public let time: Double
        public let seq: Int
        public let fromUser: Bool
    }

    /// The newest `message.user` / `message.member`.
    public let preview: Preview?
    /// Highest seq seen.
    public let latestSeq: Int
    /// Newest user message (0 when none in the tail).
    public let lastUserSeq: Int
    /// Newest member message that addresses the user (`@user`), 0 when none.
    public let lastAddressSeq: Int
    /// The latest user message of some thread still has bots to hear from: a bot may be waiting on an
    /// approval, so the sidebar also asks `groups.state` about this room.
    public let awaiting: Bool

    public static let empty = RoomDigest(preview: nil, latestSeq: 0, lastUserSeq: 0, lastAddressSeq: 0, awaiting: false)
    public static let previewLimit = 120

    public init(preview: Preview?, latestSeq: Int, lastUserSeq: Int, lastAddressSeq: Int, awaiting: Bool) {
        self.preview = preview; self.latestSeq = latestSeq; self.lastUserSeq = lastUserSeq
        self.lastAddressSeq = lastAddressSeq; self.awaiting = awaiting
    }

    /// The digest of `events` (any order, duplicates allowed). Member names come from the roster.
    public static func make(events: [RoomEvent], room: RoomSummary?) -> RoomDigest {
        let sorted = Dictionary(events.map { ($0.seq, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.seq < $1.seq }
        var timeline = RoomTimeline()
        timeline.apply(RoomLogPage(events: sorted, cursor: sorted.last?.seq ?? 0, latestSeq: sorted.last?.seq ?? 0, hasMore: false))
        let messages = sorted.filter { $0.kind == "message.user" || $0.kind == "message.member" }
        let lastUser = messages.last { $0.kind == "message.user" }?.seq ?? 0
        let lastAddress = messages.last { $0.kind == "message.member" && addressesUser($0.text ?? "", room: room) }?.seq ?? 0
        let preview = messages.last.map { e -> Preview in
            let fromUser = e.kind == "message.user"
            let author = fromUser ? "You" : (e.actor["display_name"]?.string ?? room?.member(e.memberId)?.title ?? e.memberId ?? "bot")
            // A thread's first message carries a quote of what it answers: the preview shows the user's words.
            let quoted = fromUser && RoomThreads.id(of: e) != RoomThreads.main
            let text = quoted ? RoomThreads.body(of: e.text ?? "") : (e.text ?? "")
            return Preview(author: author, text: previewText(text), time: e.createdAt, seq: e.seq, fromUser: fromUser)
        }
        return RoomDigest(preview: preview, latestSeq: sorted.last?.seq ?? 0, lastUserSeq: lastUser,
                          lastAddressSeq: lastAddress, awaiting: timeline.awaitingDiscussion)
    }

    /// A bot wrote `@user` after the user's last message and after what the user has seen in the room.
    /// Sending (a newer user message) or opening the room (`seenThrough` moves up) clears it.
    public func needsYou(seenThrough: Int) -> Bool {
        lastAddressSeq > max(lastUserSeq, seenThrough)
    }

    /// `@user` as its own word, the way Hermes Desktop flags a member that needs the user
    /// (`group-chat.ts`, `/@user\b/i`), but not inside an e-mail address or a longer handle
    /// (`@user.name`, `@users`). A room member whose handle is `user` makes it a bot mention instead.
    public static func addressesUser(_ text: String, room: RoomSummary?) -> Bool {
        if room?.members.contains(where: { $0.handle.lowercased() == "user" }) == true { return false }
        return text.range(of: #"(?<![A-Za-z0-9._%+-])@user(?![A-Za-z0-9_-]|\.[A-Za-z0-9])"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// One line for the sidebar: the attachments block is dropped (a files-only message reads "N files"),
    /// whitespace and newlines fold to single spaces, and long text is cut with an ellipsis.
    public static func previewText(_ raw: String) -> String {
        let parts = RoomAttachments.split(raw)
        let flat = parts.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if flat.isEmpty {
            let n = parts.paths.count
            return n == 0 ? "" : "\(n) file\(n == 1 ? "" : "s")"
        }
        return flat.count > previewLimit ? String(flat.prefix(previewLimit - 1)) + "…" : flat
    }

    /// Compact age for a sidebar row: "now", "5m", "3h", "2d", then a short date ("Nov 3").
    public static func age(of time: Double, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard time > 0 else { return "" }
        let seconds = max(0, now.timeIntervalSince1970 - time)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate("MMMd")
            return f.string(from: Date(timeIntervalSince1970: time))
        }
    }
}
