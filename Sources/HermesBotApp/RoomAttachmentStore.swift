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
    /// The file is checked again right before copying (it may have changed since its chip was added), and the
    /// per-file folder is always new: a name collision fails instead of reusing or removing another's folder.
    static func copy(_ file: ChatAttachments.Checked, room: String, root: URL = RoomAttachmentStore.root) throws -> URL {
        let fm = FileManager.default
        let now = try RoomAttachments.check(file.url)
        let roomDir = try folder(room: room, root: root)
        let dir = roomDir.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            for d in [root, roomDir] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.copyFailed(file.name)
        }
        do {
            let target = dir.appendingPathComponent(file.name)
            try fm.copyItem(at: now.url, to: target)
            return target
        } catch {
            try? fm.removeItem(at: dir)  // created above by this call, never someone else's
            throw Failure.copyFailed(file.name)
        }
    }

    /// True for a copy this app made for `room`: `<root>/<room>/<folder>/<name>`, nothing else.
    static func contains(_ path: String, room: String, root: URL = RoomAttachmentStore.root) -> Bool {
        guard let roomDir = try? folder(room: room, root: root) else { return false }
        let url = URL(fileURLWithPath: path)
        guard !url.pathComponents.contains("..") else { return false }
        let parts = url.standardizedFileURL.pathComponents
        return parts.count == roomDir.standardizedFileURL.pathComponents.count + 2
            && url.standardizedFileURL.path.hasPrefix(roomDir.standardizedFileURL.path + "/")
    }

    /// Removes copies made for a message that was then not sent.
    /// Only a copy's own per-file folder (`<root>/<room>/<folder>/<name>`) is ever removed.
    static func discard(_ copies: [URL], root: URL = RoomAttachmentStore.root) {
        let base = root.standardizedFileURL
        for c in copies {
            let u = c.standardizedFileURL
            guard !c.pathComponents.contains(".."), u.path.hasPrefix(base.path + "/"),
                  u.pathComponents.count == base.pathComponents.count + 3 else { continue }
            try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
        }
    }

    /// Disband: the room's whole folder goes.
    static func remove(room: String, root: URL = RoomAttachmentStore.root) {
        guard let dir = try? folder(room: room, root: root) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
