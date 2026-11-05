import Foundation

/// Files in Group Chat. A hosted room carries text only: `groups.send` accepts exactly `{text, thread_id}`
/// (`gateway/hosted_room_discussion.py` `validate_user_payload`) and the room catalog advertises
/// `attachments=False` (`tui_gateway/methods_groups.py` `_local_catalog`). So a file goes as a reference: the
/// app copies it to a folder of its own and appends a block naming the copies' absolute paths, which the
/// room's bots (local profiles on this Mac) open with their file tools. This app shows the block as
/// attachments again (`split`); other clients show the text as written.
///
///     <your text>
///
///     [Attached files: local copies on this Mac, open them with your file tools]
///     - /Users/me/Library/Application Support/HermesBotApp/Room Attachments/hba-…/3f2a91c0/report.pdf
public enum RoomAttachments {
    public static let header = "[Attached files: local copies on this Mac, open them with your file tools]"
    /// Files per message: keeps the message well under the room's 64 KiB text limit.
    public static let maxFiles = 10
    public static let maxBytes = 50 * 1024 * 1024

    public enum Failure: Error, RedactionSafeError, Equatable {
        case badName(String)

        public var description: String {
            switch self {
            case .badName(let n):
                return "\(n) has a line break, a control character or an edge space in its name; rename it to attach it."
            }
        }
    }

    /// Client-side checks: a regular file of at most `maxBytes` whose name fits on one line (the block is one
    /// path per line). No page limit: bots read PDFs with their own tools.
    public static func check(_ url: URL, fileManager: FileManager = .default) throws -> ChatAttachments.Checked {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }),
              name == name.trimmingCharacters(in: .whitespaces)
        else { throw Failure.badName(VisibleText.reveal(name)) }
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved.path) else {
            throw ChatAttachments.Failure.notFound(name)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw ChatAttachments.Failure.notRegularFile(name) }
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= maxBytes else { throw ChatAttachments.Failure.tooLarge(name, limitMB: maxBytes >> 20) }
        return ChatAttachments.Checked(url: resolved, name: name, kind: ChatAttachments.kind(of: resolved), bytes: bytes)
    }

    /// The text to send: the user's text, a blank line, then the block. Text alone without paths.
    public static func compose(text: String, paths: [String]) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else { return t }
        let block = ([header] + paths.map { "- " + $0 }).joined(separator: "\n")
        return t.isEmpty ? block : t + "\n\n" + block
    }

    /// A sent message split back into its text and attached paths. A message without a well-formed block
    /// (header, then only `- /absolute/path` lines to the end) is returned unchanged with no paths.
    public static func split(_ message: String) -> (text: String, paths: [String]) {
        let start: String.Index
        if message.hasPrefix(header) {
            start = message.startIndex
        } else if let r = message.range(of: "\n\n" + header, options: .backwards) {
            start = message.index(r.lowerBound, offsetBy: 2)
        } else {
            return (message, [])
        }
        let lines = message[start...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var paths: [String] = []
        for line in lines where !line.isEmpty {
            guard line.hasPrefix("- /") else { return (message, []) }
            paths.append(String(line.dropFirst(2)))
        }
        guard !paths.isEmpty else { return (message, []) }
        let text = message[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, paths)
    }

    /// Display refs for attached paths (images inline, other files as chips; opened only on click).
    public static func mediaRefs(_ paths: [String]) -> [MediaRef] {
        paths.map { path in
            switch ChatAttachments.kind(of: URL(fileURLWithPath: path)) {
            case .image: return MediaRef(path: path, kind: .image)
            case .pdf: return MediaRef(path: path, kind: .pdf)
            case .file: return MediaRef(path: path, kind: .file)
            }
        }
    }
}
