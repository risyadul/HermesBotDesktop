import Foundation
import HermesGatewayKit

// D5: ⌘1…9 and the ⌘K quick switcher; D10: Search Messages (⇧⌘F) over what the app already holds. Pure and
// unit tested; the palette is CommandPaletteView.swift, the menu AppCommands.swift.

// MARK: - ⌘1…9

enum SidebarShortcuts {
    static let count = 9

    /// What ⌘1…9 select: the group chats and bots the sidebar shows, in its order (the filter applies; boards
    /// and the Desktop archive are skipped).
    static func targets(_ order: [SidebarItem]) -> [SidebarItem] {
        Array(order.filter { if case .room = $0 { return true }; if case .bot = $0 { return true }; return false }
            .prefix(count))
    }

    /// ⌘`n` (1-based); nil when the sidebar shows fewer rows.
    static func item(_ n: Int, in order: [SidebarItem]) -> SidebarItem? {
        let t = targets(order)
        return n >= 1 && n <= t.count ? t[n - 1] : nil
    }
}

// MARK: - fuzzy match

enum FuzzyMatch {
    /// How well `query` matches `candidate`: nil unless every query character appears in order (case-insensitive,
    /// whitespace and a leading `@` in the query ignored). Prefixes, word starts and runs of adjacent characters
    /// score higher; longer candidates slightly lower.
    static func score(_ query: String, _ candidate: String) -> Int? {
        var raw = query.lowercased()
        if raw.hasPrefix("@") { raw.removeFirst() }
        let q = Array(raw.filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var score = 0, qi = 0, previous = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1
            if i == previous + 1 { s += 5 }
            if i == 0 { s += 8 } else if !c[i - 1].isLetter && !c[i - 1].isNumber { s += 6 }
            score += s
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if c.starts(with: q) { score += 20 }
        return score - (c.count - q.count) / 8
    }

    /// The best score over several fields; the first field (the title) gets a small edge.
    static func best(_ query: String, fields: [String]) -> Int? {
        fields.enumerated().compactMap { i, f in score(query, f).map { $0 + (i == 0 ? 2 : 0) } }.max()
    }
}

// MARK: - ⌘K quick switcher

struct QuickSwitchCandidate: Identifiable, Equatable {
    enum Kind: Equatable { case room, bot, board }

    let item: SidebarItem
    let kind: Kind
    let title: String
    let subtitle: String
    /// The title and handle (a bot's @name, a board's slug), title first: what the ranking tiers look at.
    let fields: [String]
    /// Also searched, but ranked after every title or handle match: a room's member names, a bot's description
    /// and model.
    var extraFields: [String] = []
    var id: SidebarItem { item }
}

enum QuickSwitch {
    /// Every group chat, bot (hidden ones last) and board, in sidebar order.
    static func candidates(rooms: [RoomSummary], bots: [Bot], hidden: (String) -> Bool,
                           boards: [KanbanSidebarRow]) -> [QuickSwitchCandidate] {
        let roomRows = rooms.map { r in
            QuickSwitchCandidate(item: .room(r.roomId), kind: .room, title: r.name,
                                 subtitle: r.members.map(\.title).joined(separator: ", "),
                                 fields: [r.name], extraFields: r.members.flatMap { [$0.title, $0.handle] })
        }
        let botRows = (bots.filter { !hidden($0.name) } + bots.filter { hidden($0.name) }).map { b in
            QuickSwitchCandidate(item: .bot(b.name), kind: .bot, title: b.title,
                                 subtitle: "@\(b.name)" + (hidden(b.name) ? " · hidden" : ""),
                                 fields: [b.title, b.name], extraFields: [b.description, b.model].compactMap { $0 })
        }
        let boardRows = boards.map { b in
            QuickSwitchCandidate(item: .board(b.slug), kind: .board, title: b.name, subtitle: "Board", fields: [b.name, b.slug])
        }
        return roomRows + botRows + boardRows
    }

    static let limit = 50

    /// How a candidate matches, strongest first. A match in the title or handle always outranks one that only
    /// matches a room member's name, a description or a model (live UI test 2026-11-06, round 5: "gen" listed
    /// three group chats with a member "generalist" above the bot itself).
    enum Tier: Int, Comparable {
        case other = 0, fuzzy, substring, wordStart, titlePrefix, exactTitle
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// The query as matched: lowercased, trimmed, a leading `@` dropped, inner whitespace collapsed.
    static func normalized(_ query: String) -> String {
        var q = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if q.hasPrefix("@") { q.removeFirst() }
        return q
    }

    /// The candidate's tier for `query`, nil when nothing matches.
    static func tier(_ query: String, _ c: QuickSwitchCandidate) -> Tier? {
        let q = normalized(query)
        guard !q.isEmpty else { return .other }
        let title = c.title.lowercased(), fields = c.fields.map { $0.lowercased() }
        if title == q { return .exactTitle }
        if title.hasPrefix(q) { return .titlePrefix }
        if fields.contains(where: { startsAWord(q, in: $0) }) { return .wordStart }
        if fields.contains(where: { $0.contains(q) }) { return .substring }
        if FuzzyMatch.best(query, fields: c.fields) != nil { return .fuzzy }
        if FuzzyMatch.best(query, fields: c.extraFields) != nil { return .other }
        return nil
    }

    /// Whether `q` appears in `field` at the start of a word (the start, or after a non-alphanumeric).
    static func startsAWord(_ q: String, in field: String) -> Bool {
        var rest = field[...]
        while let r = rest.range(of: q) {
            if r.lowerBound == field.startIndex { return true }
            let before = field[field.index(before: r.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            rest = field[field.index(after: r.lowerBound)...]
        }
        return false
    }

    /// Empty query: every candidate in order. Otherwise the matches by `Tier`, then fuzzy score, then sidebar
    /// order.
    static func results(_ query: String, _ candidates: [QuickSwitchCandidate], limit: Int = limit) -> [QuickSwitchCandidate] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(candidates.prefix(limit)) }
        let scored = candidates.enumerated().compactMap { i, c -> (QuickSwitchCandidate, Tier, Int, Int)? in
            guard let tier = tier(query, c) else { return nil }
            let score = FuzzyMatch.best(query, fields: tier == .other ? c.extraFields : c.fields) ?? 0
            return (c, tier, score, i)
        }
        return Array(scored.sorted { ($0.1.rawValue, $0.2, -$0.3) > ($1.1.rawValue, $1.2, -$1.3) }.prefix(limit).map(\.0))
    }
}

// MARK: - D10 message search

/// Where a found message is in its pane: a Bot Chat transcript row or a room log event.
enum MessageAnchor: Hashable {
    case chatLine(UUID)
    case roomSeq(Int)
}

enum MessageSearch {
    struct Message: Equatable {
        let anchor: MessageAnchor
        let author: String
        let text: String
    }

    /// One Bot Chat or room and the messages the app holds for it.
    struct Source: Equatable {
        let item: SidebarItem
        let title: String
        let messages: [Message]
    }

    struct Hit: Identifiable, Equatable {
        let item: SidebarItem
        let sourceTitle: String
        let anchor: MessageAnchor
        let author: String
        let snippet: String
        var id: String { "\(item.token)#\(anchor)" }
    }

    /// Queries shorter than this (after trimming) search nothing.
    static let minQuery = 2
    static let perSource = 20
    static let limit = 100
    static let snippetRadius = 60

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Messages containing every term (case- and diacritic-insensitive), newest first within each source,
    /// sources in the order given.
    static func search(_ query: String, in sources: [Source], perSource: Int = perSource, limit: Int = limit) -> [Hit] {
        let terms = terms(query)
        guard terms.joined().count >= minQuery else { return [] }
        var hits: [Hit] = []
        for source in sources {
            let found = source.messages.reversed().filter { m in terms.allSatisfy { contains(m.text, $0) } }.prefix(perSource)
            hits += found.map { m in
                Hit(item: source.item, sourceTitle: source.title, anchor: m.anchor, author: m.author,
                    snippet: snippet(m.text, around: terms[0]))
            }
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// One line around the first match of `term`, whitespace collapsed, `…` where it was cut.
    static func snippet(_ text: String, around term: String, radius: Int = snippetRadius) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let r = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return flat.count > radius * 2 ? String(flat.prefix(radius * 2)) + "…" : flat
        }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    /// A Bot Chat's searchable rows: the user's and the bot's messages.
    static func source(bot: Bot, lines: [ChatLine]) -> Source {
        Source(item: .bot(bot.name), title: bot.title, messages: lines.compactMap { l in
            switch l.role {
            case .user, .bot:
                guard !l.text.isEmpty else { return nil }
                return Message(anchor: .chatLine(l.id), author: l.role == .user ? "You" : bot.title, text: l.text)
            default: return nil
            }
        })
    }

    /// A room's searchable rows (user and member messages; attachment lists and thread quotes left out).
    static func source(room: RoomSummary, events: [RoomEvent]) -> Source {
        var timeline = RoomTimeline()
        timeline.apply(RoomLogPage(events: events, cursor: 0, latestSeq: 0, hasMore: false))
        return Source(item: .room(room.roomId), title: room.name, messages: timeline.lines(room: room).compactMap { l in
            guard l.kind == .user || l.kind == .member else { return nil }
            let text = RoomThreads.body(of: RoomAttachments.split(l.text).text)
            guard !text.isEmpty else { return nil }
            return Message(anchor: .roomSeq(l.id), author: l.kind == .user ? "You" : l.author, text: text)
        })
    }
}
