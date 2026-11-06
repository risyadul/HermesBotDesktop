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

/// The Bots section's rows (A2, A4, A5), derived like Desktop's roster (`roster-pane-derivation.ts`,
/// `sortRosterBots`): pinned bots first, then the most recent activity first (the newest of the bot's
/// creation and its last message; server order breaks ties and stands in before activity is known); hidden
/// bots go to a collapsible "Hidden (n)" section at the bottom. While a filter is active the hidden rows that
/// match are shown without expanding, and the section only appears when some hidden bot matches.
///
/// With user sections (A5) the visible bots are drawn in section blocks, Unassigned last; with none the list
/// is flat as before. A collapsed block shows its header only; a filter shows every matching row and leaves
/// out blocks with no match.
struct BotRoster: Equatable {
    let visible: [Bot]
    /// Every hidden bot that matches the filter (all of them without a filter).
    let hidden: [Bot]
    /// "Hidden (n)": n counts every hidden bot, filtered or not.
    let hiddenTotal: Int
    let showHiddenSection: Bool
    let showHiddenRows: Bool
    /// The section blocks to draw (empty when there are no user sections: a flat list).
    let blocks: [BotSectionBlock]
    let filtering: Bool
    private let collapsed: Set<String>

    init(bots: [Bot], meta: [String: BotUIMeta], query: String, hiddenExpanded: Bool,
         lastActive: [String: Double] = [:], sections: [BotSection] = [], collapsed: Set<String> = []) {
        let filtering = SidebarFilter.isActive(query)
        let isHidden = { (b: Bot) in meta[b.name]?.hidden ?? false }
        let sorted = Self.sorted(bots, meta: meta, lastActive: lastActive)
        let hiddenAll = sorted.filter(isHidden)
        visible = sorted.filter { !isHidden($0) && SidebarFilter.matches($0, query: query) }
        hidden = hiddenAll.filter { SidebarFilter.matches($0, query: query) }
        hiddenTotal = hiddenAll.count
        showHiddenSection = !hiddenAll.isEmpty && (!filtering || !hidden.isEmpty)
        showHiddenRows = showHiddenSection && (hiddenExpanded || filtering)
        self.filtering = filtering
        self.collapsed = collapsed
        blocks = sections.isEmpty ? [] : BotSectionBlock.blocks(visible, sections: sections, meta: meta).filter { block in
            // An empty Unassigned is not worth a heading; an empty named section shows its drop slot,
            // except while filtering.
            block.bots.isEmpty ? (block.section != nil && !filtering) : true
        }
    }

    /// Pinned first, then newest activity first; server order breaks ties.
    static func sorted(_ bots: [Bot], meta: [String: BotUIMeta], lastActive: [String: Double]) -> [Bot] {
        let keyed = bots.enumerated().map { i, b in
            (bot: b, index: i, pinned: meta[b.name]?.pinned ?? false,
             key: BotRosterActivity.sortKey(lastActive: lastActive[b.name] ?? 0, created: meta[b.name]?.created))
        }
        return keyed.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.key != b.key { return a.key > b.key }
            return a.index < b.index
        }.map(\.bot)
    }

    /// Whether a block's rows are drawn (collapsed blocks show their header only, unless filtering).
    func showsRows(_ block: BotSectionBlock) -> Bool { filtering || !collapsed.contains(block.key) }

    /// Visible bot rows in drawing order.
    var drawnVisible: [Bot] {
        blocks.isEmpty ? visible : blocks.flatMap { showsRows($0) ? $0.bots : [] }
    }

    /// Bot rows in the order the sidebar draws them (what the arrow keys walk).
    var rows: [Bot] { drawnVisible + (showHiddenRows ? hidden : []) }
}

/// What a bot row's context menu offers (A1): Open Bot Chat, Open Recent Session (A17), Pin / Hide, Move to
/// Section (A5), Copy @handle, then Edit, Duplicate and Delete (A8, A11, A12).
enum BotRowMenu {
    enum Item: Equatable {
        case open, openRecent, pin, unpin, hide, unhide, moveToSection, copyHandle
        /// A8/A9, A11, A12.
        case edit, duplicate, delete
    }

    static func items(_ meta: BotUIMeta) -> [Item] {
        [.open, .openRecent, meta.pinned ? .unpin : .pin, meta.hidden ? .unhide : .hide, .moveToSection, .copyHandle]
    }

    /// Move to Section's entries: every section (the current one disabled), then Unassigned when the bot is
    /// filed somewhere, then New Section….
    enum SectionChoice: Hashable {
        case section(BotSection, current: Bool)
        case unassigned
        case newSection
    }

    static func sectionChoices(_ meta: BotUIMeta, sections: [BotSection]) -> [SectionChoice] {
        let known = sections.contains { $0.id == meta.sectionId }
        return sections.map { .section($0, current: $0.id == meta.sectionId) } + (known ? [.unassigned] : []) + [.newSection]
    }

    /// Edit…, Duplicate and Delete… (never for the default profile).
    static func manageItems(_ bot: Bot) -> [Item] {
        BotDeleteModel.canDelete(bot) ? [.edit, .duplicate, .delete] : [.edit, .duplicate]
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .open: return "Open Bot Chat"
        case .openRecent: return "Open Recent Session"
        case .moveToSection: return "Move to Section"
        case .pin: return "Pin to Top"
        case .unpin: return "Unpin"
        case .hide: return "Hide Bot"
        case .unhide: return "Unhide Bot"
        case .copyHandle: return "Copy @handle"
        case .edit: return "Edit…"
        case .duplicate: return "Duplicate"
        case .delete: return "Delete…"
        }
    }

    /// The bot's @handle is its profile name (the handle rooms use, `RoomMember.from`).
    static func handle(_ bot: Bot) -> String { "@" + bot.name }
}
