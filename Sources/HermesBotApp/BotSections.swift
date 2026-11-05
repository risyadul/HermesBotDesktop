import Foundation
import HermesGatewayKit

/// A user section (folder) of the Bots list (A5).
struct BotSection: Codable, Hashable, Identifiable {
    let id: String
    var name: String
}

/// User sections, the way Hermes Desktop keeps them (`user-sections.ts`), so both apps agree:
/// - membership lives on the BOT: `sectionId` + `sectionName` in its `ui_meta["hermes-bots"]`, one profile
///   write per bot (`BotMetaModel.setSection`). Deleting a section cannot orphan anybody;
/// - the section LIST (order, empty sections) is local to this Mac (`UserDefaults`), like Desktop's plugin
///   storage; sections another app made are rebuilt from their members' `sectionId` / `sectionName`
///   (`adopted`), and members filed before the name rode along get it stamped (`backfill`);
/// - "Unassigned" is not a section: it is whatever is left, drawn last, and where members of a deleted
///   section land. With no sections the list is drawn exactly as before.
@MainActor
final class BotSectionsModel: ObservableObject {
    @Published private(set) var sections: [BotSection]
    /// Collapsed section keys (`id`, or `unassignedKey`), remembered across launches.
    @Published private(set) var collapsed: Set<String>
    /// The last delete, for the sidebar's Undo line (nil once undone, dismissed or replaced).
    @Published private(set) var lastDelete: Deletion?

    struct Deletion: Equatable {
        let section: BotSection
        let index: Int
        let members: [String]
        let token = UUID()
    }

    static let listKey = "hba.botSections"
    static let collapsedKey = "hba.botSectionsCollapsed"
    nonisolated static let unassignedKey = "section:unassigned"

    /// Files one bot (nil id = Unassigned); returns the save, or nil when nothing was sent.
    typealias Filer = (_ bot: String, _ id: String?, _ name: String?) -> Task<Void, Never>?
    var filer: Filer = { _, _, _ in nil }
    /// Section ids whose delete is still clearing its members: their not-yet-cleared members must not
    /// rebuild the section the user just deleted (Desktop `pendingSectionDeletes`).
    private var pendingDeletes: [String: UUID] = [:]
    /// Name stamps already sent (`backfill`), keyed bot + section id.
    private var stamped: Set<String> = []
    private let defaults: UserDefaults
    private let makeId: () -> String

    init(defaults: UserDefaults = .standard, makeId: @escaping () -> String = BotSectionsModel.newId) {
        self.defaults = defaults
        self.makeId = makeId
        let data = defaults.data(forKey: Self.listKey)
        sections = Self.normalized(data.flatMap { try? JSONDecoder().decode([BotSection].self, from: $0) } ?? [])
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    /// Desktop's id shape: `sec-<time base36>-<5 random>`.
    nonisolated static func newId() -> String {
        let time = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let rand = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(5))
        return "sec-\(time)-\(rand)"
    }

    /// Drops blank and duplicate entries, trims names (Desktop `normalizeBotSections`).
    nonisolated static func normalized(_ list: [BotSection]) -> [BotSection] {
        var seen = Set<String>()
        return list.compactMap { s in
            let id = s.id.trimmingCharacters(in: .whitespaces), name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty, seen.insert(id).inserted else { return nil }
            return BotSection(id: id, name: name)
        }
    }

    // MARK: editing

    /// A new section at the end, with `bots` filed into it. Nil for a blank name.
    @discardableResult
    func create(_ name: String, filing bots: [String] = [], meta: [String: BotUIMeta] = [:]) -> BotSection? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let section = BotSection(id: makeId(), name: clean)
        persist(sections + [section])
        file(bots, into: section.id, meta: meta)
        return section
    }

    /// Renames a section and re-stamps its members, which is how the new name reaches other apps.
    func rename(_ id: String, to name: String, meta: [String: BotUIMeta]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, sections.contains(where: { $0.id == id }) else { return }
        persist(sections.map { $0.id == id ? BotSection(id: id, name: clean) : $0 })
        file(Self.members(of: id, meta: meta), into: id, meta: meta)
    }

    /// Deletes the section only: its bots fall back to Unassigned. No confirmation; `undoDelete` puts the
    /// section back in its slot and refiles the same bots.
    func delete(_ id: String, meta: [String: BotUIMeta]) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let deletion = Deletion(section: sections[index], index: index, members: Self.members(of: id, meta: meta))
        let token = UUID()
        pendingDeletes[id] = token
        persist(sections.filter { $0.id != id })
        collapsed.remove(id)
        saveCollapsed()
        lastDelete = deletion
        let saves = deletion.members.compactMap { filer($0, nil, nil) }
        Task {
            for save in saves { await save.value }
            if self.pendingDeletes[id] == token { self.pendingDeletes[id] = nil }
        }
    }

    func undoDelete(meta: [String: BotUIMeta]) {
        guard let d = lastDelete else { return }
        lastDelete = nil
        pendingDeletes[d.section.id] = nil
        var list = sections.filter { $0.id != d.section.id }
        list.insert(d.section, at: min(d.index, list.count))
        persist(list)
        file(d.members, into: d.section.id, meta: meta)
    }

    func dismissDelete() { lastDelete = nil }

    /// Moves a section up (-1) or down (+1) in the list.
    func move(_ id: String, by delta: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard sections.indices.contains(to) else { return }
        var list = sections
        list.swapAt(from, to)
        persist(list)
    }

    /// Files `bots` into section `id` (nil = Unassigned). One save per bot whose id or name changes.
    func file(_ bots: [String], into id: String?, meta: [String: BotUIMeta]) {
        let name = id.flatMap { id in sections.first { $0.id == id }?.name }
        if id != nil && name == nil { return }  // deleted meanwhile: filing would resurrect it
        for bot in bots {
            let current = meta[bot] ?? BotUIMeta()
            guard current.sectionId != id || current.sectionName != name else { continue }
            _ = filer(bot, id, name)
        }
    }

    func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }

    func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        saveCollapsed()
    }

    // MARK: following other apps

    /// Called on every roster / meta change: adopts sections another app made, takes a rename every member
    /// agrees on, and stamps the name onto members that carry only an id this Mac knows.
    func sync(meta: [String: BotUIMeta]) {
        let next = Self.adopted(local: sections, meta: meta, pending: Set(pendingDeletes.keys))
        if next != sections { persist(next) }
        // Once per bot and section per launch: a stamp that did not save is not retried on every change.
        for (bot, id) in Self.backfill(sections: sections, meta: meta) where stamped.insert(bot + "\u{0}" + id).inserted {
            _ = filer(bot, id, sections.first { $0.id == id }?.name)
        }
    }

    /// Desktop `adoptBotSectionsFromMeta`: unknown ids carried by members (with a name) are appended; a known
    /// section takes its members' name only when they all agree; order and empty sections stay local.
    nonisolated static func adopted(local: [BotSection], meta: [String: BotUIMeta], pending: Set<String>) -> [BotSection] {
        var names: [String: Set<String>] = [:]
        var order: [String] = []
        for name in meta.keys.sorted() {
            guard let m = meta[name], let id = m.sectionId, let sectionName = m.sectionName else { continue }
            if names[id] == nil { order.append(id) }
            names[id, default: []].insert(sectionName)
        }
        let known = Set(local.map(\.id))
        let renamed = local.map { s -> BotSection in
            guard let set = names[s.id], set.count == 1, let agreed = set.first else { return s }
            return BotSection(id: s.id, name: agreed)
        }
        let adopted = order.filter { !known.contains($0) && !pending.contains($0) }
            .compactMap { id in names[id]?.sorted().first.map { BotSection(id: id, name: $0) } }
        return renamed + adopted
    }

    /// Desktop `backfillBotSectionNames`: members of a section this Mac knows that carry no name yet.
    nonisolated static func backfill(sections: [BotSection], meta: [String: BotUIMeta]) -> [(String, String)] {
        let known = Set(sections.map(\.id))
        return meta.keys.sorted().compactMap { bot in
            guard let m = meta[bot], let id = m.sectionId, known.contains(id), m.sectionName == nil else { return nil }
            return (bot, id)
        }
    }

    nonisolated static func members(of id: String, meta: [String: BotUIMeta]) -> [String] {
        meta.keys.sorted().filter { meta[$0]?.sectionId == id }
    }

    private func persist(_ list: [BotSection]) {
        sections = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.listKey) }
    }

    private func saveCollapsed() { defaults.set(collapsed.sorted(), forKey: Self.collapsedKey) }
}

/// The Bots list split into section blocks (Desktop `groupRowsBySection`): one block per section in list
/// order, then Unassigned. Every bot lands exactly once: a bot whose `sectionId` names no known section is
/// Unassigned, which is what makes deleting a section safe.
struct BotSectionBlock: Equatable, Identifiable {
    /// nil for Unassigned.
    let section: BotSection?
    let bots: [Bot]
    var id: String { section?.id ?? BotSectionsModel.unassignedKey }
    var key: String { id }

    static func blocks(_ bots: [Bot], sections: [BotSection], meta: [String: BotUIMeta]) -> [BotSectionBlock] {
        let known = Set(sections.map(\.id))
        var byId: [String: [Bot]] = [:]
        var loose: [Bot] = []
        for bot in bots {
            if let id = meta[bot.name]?.sectionId, known.contains(id) { byId[id, default: []].append(bot) } else { loose.append(bot) }
        }
        return sections.map { BotSectionBlock(section: $0, bots: byId[$0.id] ?? []) } + [BotSectionBlock(section: nil, bots: loose)]
    }
}

/// Drag and drop of a bot row onto a section. The payload is the bot's @handle, so a row dropped on any
/// other text target (the composer) types a harmless mention instead of an internal key; a drop target
/// accepts it only when it names a bot of the roster.
enum BotDrag {
    static func payload(_ bot: Bot) -> String { "@" + bot.name }

    static func bot(from payload: String, roster: [Bot]) -> Bot? {
        let t = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("@") else { return nil }
        let name = String(t.dropFirst())
        return roster.first { $0.name == name }
    }
}
