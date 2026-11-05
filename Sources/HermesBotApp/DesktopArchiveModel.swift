import Foundation
import HermesGatewayKit

/// Where the imported Desktop archive is kept.
protocol DesktopArchiveStoring {
    func load() -> [DesktopArchiveRoom]
    func save(_ rooms: [DesktopArchiveRoom]) throws
}

/// The archive as one JSON file in the app's Application Support folder (0700 folder, 0600 file). It is this
/// app's own copy: Hermes and Hermes Desktop are never written.
struct DesktopArchiveFileStore: DesktopArchiveStoring {
    var url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesBotApp/Desktop Archive/archive.json")
    }()
    /// A bigger file is not ours (64 rooms × 16 messages × 1200 characters is well under this).
    static let maxBytes = 16 * 1024 * 1024

    func load() -> [DesktopArchiveRoom] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= Self.maxBytes, let data = try? Data(contentsOf: url),
              let rooms = try? JSONDecoder().decode([DesktopArchiveRoom].self, from: data) else { return [] }
        return Array(rooms.prefix(DesktopGroupArchive.maxRooms))
    }

    func save(_ rooms: [DesktopArchiveRoom]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if rooms.isEmpty {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try JSONEncoder().encode(rooms).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// E4 / D17: the read-only Desktop archive. `list` reads Desktop's group chats from the backend (one
/// `profiles.list`, read-only) for the import sheet; `importRooms` copies the chosen ones into the local
/// archive shown in the sidebar ("Desktop archive"). Nothing here writes `ui_meta` or creates rooms.
@MainActor
final class DesktopArchiveModel: ObservableObject {
    enum Listing: Equatable {
        case idle, loading
        case loaded([DesktopArchiveRoom])
        case failed(String)
    }

    /// Imported rooms, newest activity first.
    @Published private(set) var rooms: [DesktopArchiveRoom]
    /// What the import sheet shows.
    @Published private(set) var listing: Listing = .idle
    /// The sidebar section's disclosure; session-only.
    @Published var expanded = true
    private let store: DesktopArchiveStoring
    private var listGeneration = 0

    init(store: DesktopArchiveStoring = DesktopArchiveFileStore()) {
        self.store = store
        rooms = Self.ordered(store.load())
    }

    func room(_ id: String) -> DesktopArchiveRoom? { rooms.first { $0.id == id } }
    func isImported(_ id: String) -> Bool { rooms.contains { $0.id == id } }

    /// Reads Desktop's rooms for the import sheet. `call` nil = not connected.
    func list(call: DesktopGroupArchive.Call?) async {
        listGeneration += 1
        let generation = listGeneration
        guard let call else {
            listing = .failed("Connect to Hermes first: Hermes Desktop's group chats are read from it.")
            return
        }
        listing = .loading
        let result: Listing
        do {
            result = .loaded(try await DesktopGroupArchive.load(call: call))
        } catch {
            result = .failed("Could not read Hermes Desktop's group chats: \(Redaction.describe(error))")
        }
        guard generation == listGeneration else { return }  // a newer listing (or a reset) won
        listing = result
    }

    func resetListing() {
        listGeneration += 1
        listing = .idle
    }

    /// Copies `chosen` into the archive (a room imported before is replaced by the newer copy). Returns an
    /// error text when the archive could not be saved; the rooms stay shown for this session either way.
    @discardableResult
    func importRooms(_ chosen: [DesktopArchiveRoom]) -> String? {
        guard !chosen.isEmpty else { return nil }
        let ids = Set(chosen.map(\.id))
        rooms = Self.ordered(chosen + rooms.filter { !ids.contains($0.id) })
        return persist()
    }

    /// Removes a room from this app's archive only (Hermes Desktop keeps its own).
    @discardableResult
    func remove(_ id: String) -> String? {
        guard isImported(id) else { return nil }
        rooms.removeAll { $0.id == id }
        return persist()
    }

    /// The archive rows the sidebar draws for `query`, in order (none while collapsed, unless filtering).
    func sidebarRooms(query: String) -> [DesktopArchiveRoom] {
        let filtering = SidebarFilter.isActive(query)
        guard expanded || filtering else { return [] }
        return rooms.filter { SidebarFilter.matches(fields: Self.filterFields($0), query: query) }
    }

    static func filterFields(_ room: DesktopArchiveRoom) -> [String?] {
        [room.name] + room.members.flatMap { [$0.name, $0.handle] }
    }

    private func persist() -> String? {
        do {
            try store.save(rooms)
            return nil
        } catch {
            return "The archive could not be saved: \(Redaction.describe(error))"
        }
    }

    static func ordered(_ rooms: [DesktopArchiveRoom]) -> [DesktopArchiveRoom] {
        Array(rooms.sorted { ($0.lastAt ?? .distantPast, $0.id) > ($1.lastAt ?? .distantPast, $1.id) }
            .prefix(DesktopGroupArchive.maxRooms))
    }
}

/// What the New Group Chat sheet starts with when it continues an archived room.
struct CreateRoomPrefill: Equatable {
    let name: String
    /// Bot (profile) names to tick.
    let members: [String]
    /// Put into the new room's composer after it is created; the user still sends it.
    let draft: String
}

/// Pure helpers for the archive pane and "Continue in a New Room".
enum DesktopArchivePresentation {
    static let carryOverMessages = 6
    static let carryOverMessageChars = 600

    /// The archive's members that are bots on this backend (by profile name, else @handle), as room members,
    /// and the names that are not (a deleted bot, or one Desktop seated from another Hermes).
    static func continuation(_ room: DesktopArchiveRoom, bots: [Bot]) -> (members: [RoomMember], missing: [String]) {
        var members: [RoomMember] = []
        var missing: [String] = []
        for m in room.members {
            let bot = bots.first { $0.name == m.name } ?? m.handle.flatMap { h in bots.first { $0.name == h } }
            if let bot, let member = RoomMember.forBot(bot) {
                if !members.contains(where: { $0.profile == member.profile }) { members.append(member) }
            } else {
                missing.append(m.handle ?? m.name)
            }
        }
        return (Array(members.prefix(DesktopGroupArchive.maxMembers)), missing)
    }

    /// Hosted rooms take 2 to 6 members.
    static func canContinue(_ room: DesktopArchiveRoom, bots: [Bot], connected: Bool, groupsAvailable: Bool) -> Bool {
        connected && groupsAvailable && continuation(room, bots: bots).members.count >= 2
    }

    /// The new room's name: the archived name, marked as continued, within Desktop's 64 characters.
    static func continuedName(_ room: DesktopArchiveRoom) -> String {
        let suffix = " (continued)"
        return String(room.name.prefix(DesktopGroupArchive.maxNameChars - suffix.count)) + suffix
    }

    /// The opening message: the archived room's last few messages, quoted, for the bots to pick up from.
    static func carryOver(_ room: DesktopArchiveRoom) -> String {
        let recent = room.messages.suffix(carryOverMessages).map { m -> String in
            let body = m.text.count > carryOverMessageChars ? String(m.text.prefix(carryOverMessageChars)) + "…" : m.text
            let quoted = body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            return "> **\(m.author):**\n\(quoted)"
        }
        return "Let's continue our Hermes Desktop group chat \"\(room.name)\". Where we left off:\n\n"
            + recent.joined(separator: "\n>\n")
    }

    static func prefill(_ room: DesktopArchiveRoom, bots: [Bot]) -> CreateRoomPrefill {
        CreateRoomPrefill(name: continuedName(room), members: continuation(room, bots: bots).members.map(\.profile),
                          draft: carryOver(room))
    }

    /// "16 messages · 3 bots".
    static func summary(_ room: DesktopArchiveRoom) -> String {
        let n = room.messages.count + room.omitted
        let messages = n == 1 ? "1 message" : "\(n) messages"
        let bots = room.members.count == 1 ? "1 bot" : "\(room.members.count) bots"
        return "\(messages) · \(bots)"
    }
}
