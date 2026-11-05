import Foundation
import HermesGatewayKit

// C2.2 Change Members. Hosted rooms have no member-update RPC (`groups.*` creates a roster once), so
// "changing members" makes a new room: `groups.create` (fresh `hba-` id, the chosen name and members), then one
// `groups.send` carrying the old room's recent `main` messages over as context, then the user decides what
// happens to the old room (keep, optionally renamed "… (old)", or disband). Nothing is sent before the
// create succeeds; a failed carry-over leaves the new room in place with a note.

/// The context message posted first in the new room. Pure, unit tested (RoomMemberChangeTests).
///
///     Continuing from the previous room "Ops" with Alpha, Beta (members changed: +Gamma −Beta).
///     Its last 3 messages are quoted below as context only; files were not carried over.
///
///     > You: can you check the build
///     > Alpha: it is green (files: report.pdf)
///     > Beta: agreed
///
///     Nothing to answer yet: reply (pass) and wait for the next message.
///
/// The message starts with plain words and every quoted message is one `> ` line, so no line opens with a
/// Hermes control frame ("[System: …"); a quoted message that was one is relabelled "Hermes note: <title>"
/// (`SystemNotice`). `@` before a handle is dropped so a quoted mention does not pick who answers
/// (`hosted_room_discussion.py` round 0 = the mentioned members). Attachments are never re-sent: only their
/// file names are mentioned.
enum RoomCarryOver {
    /// Messages of the old room's `main` thread carried over (the most recent ones).
    static let messageLimit = 12
    /// Characters of the whole message: oldest quoted messages are left out until it fits.
    static let charLimit = 4000
    /// Characters of one quoted message.
    static let quoteLimit = 400
    /// Characters of a room name or member title in the header line.
    static let nameLimit = 80
    static let opener = "Continuing from the previous room "
    static let footer = "Nothing to answer yet: reply (pass) and wait for the next message."

    /// Members added and removed, by profile (titles, in roster order).
    struct Diff: Equatable {
        let added: [String]
        let removed: [String]
    }

    static func diff(old: [RoomMember], new: [RoomMember]) -> Diff {
        let was = Set(old.map(\.profile)), now = Set(new.map(\.profile))
        return Diff(added: new.filter { !was.contains($0.profile) }.map(\.title),
                    removed: old.filter { !now.contains($0.profile) }.map(\.title))
    }

    /// The text to post and how many messages it quotes.
    static func message(previous: RoomSummary, members: [RoomMember], lines: [RoomLine]) -> (text: String, quoted: Int) {
        let header = headerLine(previous: previous, members: members)
        var quotes = Array(lines.filter(isCarried).suffix(messageLimit).map(quote))
        while true {
            let text = compose(header: header, quotes: quotes)
            if text.count <= charLimit || quotes.isEmpty { return (text, quotes.count) }
            quotes.removeFirst()
        }
    }

    static func headerLine(previous: RoomSummary, members: [RoomMember]) -> String {
        let d = diff(old: previous.members, new: members)
        let changes = d.added.map { "+" + name($0) } + d.removed.map { "\u{2212}" + name($0) }
        let with = previous.members.map { name($0.title) }.joined(separator: ", ")
        let changed = changes.isEmpty ? "" : " (members changed: \(changes.joined(separator: " ")))"
        return "\(opener)\"\(name(previous.name))\" with \(with)\(changed)."
    }

    private static func compose(header: String, quotes: [String]) -> String {
        let intro = quotes.isEmpty
            ? "It had no messages to carry over."
            : "Its last \(quotes.count == 1 ? "message is" : "\(quotes.count) messages are") quoted below as context only; files were not carried over."
        let body = quotes.isEmpty ? "" : "\n\n" + quotes.joined(separator: "\n")
        return "\(header)\n\(intro)\(body)\n\n\(footer)"
    }

    /// A user or bot message of `main` that is not itself an earlier carry-over.
    static func isCarried(_ line: RoomLine) -> Bool {
        (line.kind == .user || line.kind == .member) && line.threadId == RoomThreads.main && !line.text.hasPrefix(opener)
    }

    /// One `> Author: text (files: a.pdf)` line.
    static func quote(_ line: RoomLine) -> String {
        let parts = RoomAttachments.split(line.text)
        var body = safe(parts.text, limit: quoteLimit)
        let files = parts.paths.map { safe(URL(fileURLWithPath: $0).lastPathComponent, limit: nameLimit) }
        if !files.isEmpty { body += (body.isEmpty ? "" : " ") + "(files: \(files.joined(separator: ", ")))" }
        return "> \(name(line.author)): \(body)"
    }

    /// One line of plain text: a control frame relabelled, line breaks and control characters folded to
    /// spaces, `@` dropped before a handle, cut at `limit` characters.
    static func safe(_ raw: String, limit: Int) -> String {
        var text = SystemNotice.parse(raw).map { "Hermes note: \($0.title)" } ?? raw
        text = String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            CharacterSet.controlCharacters.contains(s) || s == "\u{2028}" || s == "\u{2029}" ? " " : s
        }))
        text = text.replacingOccurrences(of: "(?<![A-Za-z0-9._:-])@(?=[A-Za-z0-9])", with: "", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func name(_ s: String) -> String { safe(s, limit: nameLimit) }
}

/// The Change Members flow for one room: the sheet's state and the calls it makes, in order
/// `groups.create` → `groups.send` (carry-over) → the old room's rename or disband. Headless over
/// `RoomActions` (the old room's own), unit tested with `FakeRoomActions`.
@MainActor
final class RoomMemberChange: ObservableObject {
    enum Phase: Equatable {
        /// The form (name + members).
        case editing
        /// `groups.create` and the carry-over in flight.
        case creating
        /// The new room exists: keep or disband the old one.
        case deciding
        /// The old room's disband in flight.
        case finishing
        case done
    }

    enum OldRoom: Equatable { case keep, disband }

    @Published private(set) var phase = Phase.editing
    /// The room `groups.create` made.
    @Published private(set) var created: RoomSummary?
    /// Messages the carry-over quoted (when it was posted).
    @Published private(set) var quoted = 0
    /// Why the carry-over message was not posted (the new room stays).
    @Published private(set) var carryOverError: String?
    /// Why the old room could not be disbanded (the sheet stays on the choice).
    @Published private(set) var finishError: String?
    @Published var choice = OldRoom.keep
    /// Keep: also rename the old room to `oldName` (off by default).
    @Published var renameOld = false

    let old: RoomModel
    private let mintId: @MainActor () -> String
    /// The new room was created: the app lists it (not selected yet).
    var onCreated: ((RoomSummary) -> Void)?
    /// Done: the app selects the new room; the text is a note for its note bar (carry-over failed).
    var onFinished: ((RoomSummary, String?) -> Void)?

    init(old: RoomModel, mintId: @escaping @MainActor () -> String = { AppModel.mintRoomId() }) {
        self.old = old; self.mintId = mintId
    }

    /// The old room's name with " (old)", cut so it stays within the server's name limit.
    nonisolated static func oldName(_ name: String) -> String {
        let suffix = " (old)"
        let room = RoomSummary.maxNameChars - suffix.unicodeScalars.count
        let base = String(String.UnicodeScalarView(name.unicodeScalars.prefix(room))).trimmingCharacters(in: .whitespaces)
        return base + suffix
    }

    var oldName: String { Self.oldName(old.room.name) }

    /// Step 1. Creates the room and posts the carry-over. Returns an error text when the create failed (nothing
    /// changed, the form stays) or was refused (wrong member count, unchanged roster, blank name); nil when the
    /// room exists (the carry-over may still have failed: `carryOverError`).
    func create(name raw: String, members: [RoomMember]) async -> String? {
        guard phase == .editing else { return "Already creating the new room." }
        guard let name = RoomSummary.normalizedName(raw) else { return "Give the room a name of at most \(RoomSummary.maxNameChars) characters." }
        guard (2...6).contains(members.count) else { return "Pick 2 to 6 bots." }
        guard Set(members.map(\.profile)) != Set(old.room.members.map(\.profile)) else { return "Pick a different set of bots." }
        phase = .creating
        let api = old.api
        let room: RoomSummary
        do {
            room = try await api.createRoom(roomId: mintId(), name: name, members: members)
        } catch {
            phase = .editing
            AppModel.shared.log("change members: groups.create failed: \(Redaction.describe(error))")
            return Redaction.describe(error)
        }
        created = room
        AppModel.shared.log("change members: \(old.room.roomId) → \(room.roomId) members=\(room.members.map(\.handle))")
        onCreated?(room)
        let carry = RoomCarryOver.message(previous: old.room, members: room.members, lines: old.lines)
        do {
            _ = try await api.sendMessage(roomId: room.roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())",
                                          text: carry.text, threadId: RoomThreads.main)
            quoted = carry.quoted
        } catch {
            carryOverError = Redaction.describe(error)
            AppModel.shared.log("change members: carry-over to \(room.roomId) failed: \(carryOverError ?? "")")
        }
        phase = .deciding
        return nil
    }

    /// Step 2: keep (optionally renamed) or disband the old room, then hand over to the new one. False while a
    /// disband failed (the old room stays, `finishError` says why) or outside the choice step.
    @discardableResult
    func finish() async -> Bool {
        guard phase == .deciding, let created else { return false }
        finishError = nil
        switch choice {
        case .keep:
            if renameOld { old.rename(oldName) }
        case .disband:
            phase = .finishing
            guard await old.disband() else {
                finishError = old.notes.last.map { RoomNote($0).text } ?? "Disband failed."
                phase = .deciding
                return false
            }
        }
        phase = .done
        let note = carryOverError.map {
            "context message failed: \($0). The previous room's messages were not posted here; this room starts empty."
        }
        onFinished?(created, note)
        return true
    }
}
