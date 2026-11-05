import AppKit
import HermesGatewayKit
import SwiftUI
import UniformTypeIdentifiers

// C1.8: a local room picture and the room's availability. Hosted rooms have no picture field (`groups.*` rows
// carry name and members only), so the picture lives on this Mac: the chosen image is read like a bot avatar
// (`ProfileAvatar`: PNG or JPEG by its bytes, at most 15 MB, centred square, 256 px PNG) and saved as
// `Application Support/HermesBotApp/Room Pictures/<room id>.png` (folder 0700, file 0600). It replaces the stacked
// member avatars in the room's toolbar and sidebar row; Remove Picture deletes the file; disbanding the room
// deletes it too.

@MainActor
final class RoomPictureStore: ObservableObject {
    static let shared = RoomPictureStore()

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesBotApp/Room Pictures", isDirectory: true)
    }

    let root: URL
    /// Decoded pictures, and rooms known to have none (nil), so a redraw never touches the disk.
    private var cache: [String: NSImage?] = [:]

    init(root: URL = RoomPictureStore.defaultRoot) { self.root = root }

    /// Room ids are server-issued identifiers; anything else never becomes a file name.
    func file(room: String) -> URL? {
        guard (try? RoomAttachmentStore.folder(room: room, root: root)) != nil else { return nil }
        return root.appendingPathComponent(room + ".png")
    }

    func hasPicture(room: String) -> Bool { image(room: room) != nil }

    func image(room: String) -> NSImage? {
        if let cached = cache[room] { return cached }
        let image = file(room: room).flatMap { NSImage(contentsOf: $0) }
        cache[room] = .some(image)
        return image
    }

    /// Reads, squares and saves the picked image. Throws `ProfileAvatar.Failure` (or a write error) and keeps
    /// the previous picture then.
    func setPicture(room: String, from url: URL) throws {
        guard let target = file(room: room) else { throw RoomAttachmentStore.Failure.badRoom }
        let png = try ProfileAvatar.normalize(try ProfileAvatar.read(url))
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try png.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        objectWillChange.send()
        cache[room] = .some(NSImage(data: png))
    }

    func removePicture(room: String) {
        guard let target = file(room: room) else { return }
        try? FileManager.default.removeItem(at: target)
        guard cache[room] != .some(nil) else { return }
        objectWillChange.send()
        cache[room] = .some(nil)
    }
}

/// The room's picture, else its members' stacked avatars (`RoomAvatarStack`).
struct RoomAvatar: View {
    let roomId: String
    let identities: [BotIdentity]
    @ObservedObject var pictures: RoomPictureStore = .shared

    var body: some View {
        if let image = pictures.image(room: roomId) {
            Image(nsImage: image)
                .resizable().interpolation(.high)
                .frame(width: DS.Size.avatarRow, height: DS.Size.avatarRow)
                .clipShape(RoundedRectangle(cornerRadius: AvatarView.radius(for: DS.Size.avatarRow), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AvatarView.radius(for: DS.Size.avatarRow), style: .continuous)
                    .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                .accessibilityHidden(true)
        } else {
            RoomAvatarStack(identities: identities)
        }
    }
}

/// Room menu → Choose Picture…: PNG or JPEG, as for a bot avatar.
@MainActor
func pickRoomPicture(for model: RoomModel, store: RoomPictureStore = .shared) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose a picture for \(model.room.name). It is kept on this Mac only."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try store.setPicture(room: model.room.roomId, from: url)
    } catch {
        model.note("picture failed: \(Redaction.describe(error))")
    }
}

// MARK: - availability

/// "N of M available" in the room header: a member counts unless its bot is gone (no profile of that name
/// among the bots Hermes lists) or its latest turn failed or waits on a retry (the log's `turn.*` and
/// `groups.state`, `RoomPresentation.memberStates`). Before the bot list has loaded, profiles are not judged.
struct RoomAvailability: Equatable {
    enum Reason: Equatable { case botMissing, failing }

    let total: Int
    /// Unavailable members, in room order.
    let unavailable: [(member: RoomMember, reason: Reason)]

    var available: Int { total - unavailable.count }

    var summary: String { "\(available) of \(total) available" }

    /// The members that are out, one per line, for the header's help text and VoiceOver.
    var detail: String {
        guard !unavailable.isEmpty else { return "Every bot in this room is available." }
        return unavailable.map { u in
            switch u.reason {
            case .botMissing: return "\(u.member.title) (@\(u.member.handle)): its bot no longer exists on this Mac."
            case .failing: return "\(u.member.title) (@\(u.member.handle)): its last turn failed or needs a retry."
            }
        }.joined(separator: "\n")
    }

    init(room: RoomSummary, bots: Set<String>?, states: [String: RoomPresentation.MemberState]) {
        total = room.members.count
        unavailable = room.members.compactMap { m in
            if let bots, !bots.isEmpty, !bots.contains(m.profile) { return (m, .botMissing) }
            switch states[m.memberId] {
            case .failed?, .deferred?: return (m, .failing)
            default: return nil
            }
        }
    }

    static func == (a: RoomAvailability, b: RoomAvailability) -> Bool {
        a.total == b.total && a.unavailable.map(\.member) == b.unavailable.map(\.member)
            && a.unavailable.map(\.reason) == b.unavailable.map(\.reason)
    }
}
