import Foundation
import HermesGatewayKit

/// Where Group Chat attachments live (`RoomAttachments`): copies under the app's Application Support folder,
/// one 0700 folder per room and a random folder per file (two files with one name never collide), so a file
/// the bots were pointed at stays put even if the original is moved or was a pasted image. Removed with the
/// room when it is disbanded.
enum RoomAttachmentStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesBotApp/Room Attachments", isDirectory: true)
    }

    enum Failure: Error, RedactionSafeError, Equatable {
        case badRoom
        case copyFailed(String)
        var description: String {
            switch self {
            case .badRoom: return "This room cannot store attachments."
            case .copyFailed(let n): return "\(n) could not be copied for the room."
            }
        }
    }

    /// Room ids are server-issued identifiers; anything else never becomes a path component.
    static func folder(room: String, root: URL = RoomAttachmentStore.root) throws -> URL {
        guard !room.isEmpty, room.count <= 128,
              room.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              room != ".", room != ".." else { throw Failure.badRoom }
        return root.appendingPathComponent(room, isDirectory: true)
    }

    /// Copies a checked file into the room's folder (APFS clones it, so even a large file is instant on the
    /// same volume) and returns the copy.
    static func copy(_ file: ChatAttachments.Checked, room: String, root: URL = RoomAttachmentStore.root) throws -> URL {
        let fm = FileManager.default
        let dir = try folder(room: room, root: root).appendingPathComponent(String(UUID().uuidString.lowercased().prefix(8)), isDirectory: true)
        do {
            for d in [root, dir.deletingLastPathComponent(), dir] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
            }
            let target = dir.appendingPathComponent(file.name)
            try fm.copyItem(at: file.url, to: target)
            return target
        } catch {
            try? fm.removeItem(at: dir)
            throw Failure.copyFailed(file.name)
        }
    }

    /// Removes copies made for a message that was then not sent.
    static func discard(_ copies: [URL], root: URL = RoomAttachmentStore.root) {
        let base = root.standardizedFileURL.path + "/"
        for c in copies where c.standardizedFileURL.path.hasPrefix(base) {
            try? FileManager.default.removeItem(at: c.deletingLastPathComponent())
        }
    }

    /// Disband: the room's whole folder goes.
    static func remove(room: String, root: URL = RoomAttachmentStore.root) {
        guard let dir = try? folder(room: room, root: root) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
