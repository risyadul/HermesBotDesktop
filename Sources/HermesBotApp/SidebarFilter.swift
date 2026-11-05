import HermesGatewayKit

/// The sidebar's filter field (A3): one query narrows rooms, bots (visible and hidden) and boards at once.
/// Case-insensitive substring match, a leading `@` ignored (like Hermes Desktop's `filterBots`), and every
/// whitespace-separated term must match one of the row's fields.
enum SidebarFilter {
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).compactMap { raw in
            let term = raw.hasPrefix("@") ? raw.dropFirst() : raw[...]
            return term.isEmpty ? nil : String(term)
        }
    }

    static func isActive(_ query: String) -> Bool { !terms(query).isEmpty }

    static func matches(fields: [String?], query: String) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        let haystack = fields.compactMap { $0?.lowercased() }
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// Title, profile name (= @handle), description and model.
    static func matches(_ bot: Bot, query: String) -> Bool {
        matches(fields: [bot.title, bot.name, bot.description, bot.model], query: query)
    }

    /// Room name and every member's title and @handle.
    static func matches(_ room: RoomSummary, query: String) -> Bool {
        matches(fields: [room.name] + room.members.flatMap { [$0.title, $0.handle] }, query: query)
    }

    static func matches(_ board: KanbanSidebarRow, query: String) -> Bool {
        matches(fields: [board.name, board.slug], query: query)
    }
}

/// The Bots section's rows (A2), derived like Desktop's roster (`roster-pane-derivation.ts`): pinned bots
/// first, otherwise server order; hidden bots go to a collapsible "Hidden (n)" section at the bottom. While
/// a filter is active the hidden rows that match are shown without expanding, and the section only appears
/// when some hidden bot matches.
struct BotRoster: Equatable {
    let visible: [Bot]
    /// Every hidden bot that matches the filter (all of them without a filter).
    let hidden: [Bot]
    /// "Hidden (n)": n counts every hidden bot, filtered or not.
    let hiddenTotal: Int
    let showHiddenSection: Bool
    let showHiddenRows: Bool

    init(bots: [Bot], meta: [String: BotUIMeta], query: String, hiddenExpanded: Bool) {
        let filtering = SidebarFilter.isActive(query)
        let isHidden = { (b: Bot) in meta[b.name]?.hidden ?? false }
        let isPinned = { (b: Bot) in meta[b.name]?.pinned ?? false }
        let shown = bots.filter { !isHidden($0) }
        let pinnedFirst = shown.filter(isPinned) + shown.filter { !isPinned($0) }
        let hiddenAll = bots.filter(isHidden)
        visible = pinnedFirst.filter { SidebarFilter.matches($0, query: query) }
        hidden = hiddenAll.filter { SidebarFilter.matches($0, query: query) }
        hiddenTotal = hiddenAll.count
        showHiddenSection = !hiddenAll.isEmpty && (!filtering || !hidden.isEmpty)
        showHiddenRows = showHiddenSection && (hiddenExpanded || filtering)
    }

    /// Bot rows in the order the sidebar draws them (what the arrow keys walk).
    var rows: [Bot] { visible + (showHiddenRows ? hidden : []) }
}

/// What a bot row's context menu offers (A1). Edit, Duplicate, Delete and Manage groups appear once they
/// are implemented (A8, A11, A12, A5).
enum BotRowMenu {
    enum Item: Equatable {
        case open, pin, unpin, hide, unhide, copyHandle
    }

    static func items(_ meta: BotUIMeta) -> [Item] {
        [.open, meta.pinned ? .unpin : .pin, meta.hidden ? .unhide : .hide, .copyHandle]
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .open: return "Open Bot Chat"
        case .pin: return "Pin to Top"
        case .unpin: return "Unpin"
        case .hide: return "Hide Bot"
        case .unhide: return "Unhide Bot"
        case .copyHandle: return "Copy @handle"
        }
    }

    /// The bot's @handle is its profile name (the handle rooms use, `RoomMember.from`).
    static func handle(_ bot: Bot) -> String { "@" + bot.name }
}
