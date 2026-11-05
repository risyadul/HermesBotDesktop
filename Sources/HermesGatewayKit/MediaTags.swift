import Foundation

// Bot -> user files. The gateway passes model text through unchanged, so `MEDIA:<path>` tags arrive raw in
// message text (research topic 7). Extraction is the client's job; this is a pure port of the Hermes behaviour:
//   - gateway/platforms/base.py:1289-1301  MEDIA_DELIVERY_EXTS (extension list)
//   - gateway/platforms/base.py:1328-1333  MEDIA_TAG_CLEANUP_RE (the tag grammar)
//   - gateway/platforms/base.py:1400-1404  _normalize_media_tag_path
//   - gateway/platforms/base.py:1481-1482  _FENCED_CODE_RE / _INLINE_CODE_RE; 3276-3293 _mask_protected_spans
//   - gateway/platforms/base.py:1498-1512  _delete_spans; 1516-1526 _strip_media_tag_directives
//   - gateway/platforms/base.py:3319-3350  extract_media (directives, dedupe on expanded path, voice flag)
//   - gateway/platforms/base.py:3352-3360  strip_media_directives_for_display (collapse 3+ newlines, rstrip);
//     gateway/stream_consumer.py:966-973 uses it for streamed display text
//   - apps/desktop/src/lib/chat-messages/parts.ts:117-193 mirrors the same extension list/anchored path grammar.
//
// Deliberate differences from the Python (documented, not bugs):
//   - Tags with an unknown extension or none (Caddyfile, .py) are NOT extracted and stay visible: Python only
//     delivers those after on-disk validation (MEDIA_EXTENSIONLESS_TAG_RE, base.py:1335+), which a pure
//     function cannot do.
//   - A whole `MEDIA:` tag inside inline code (`MEDIA:/x.csv`) stays masked; Python keeps it only when the file
//     exists on disk (base.py:3285-3291).
//   - JSON-string-value masking (`_mask_json_string_media`) and the `<|eos|>` sentinel are not ported.

public struct MediaRef: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case image, audio, video, pdf, file
    }

    /// Path with a leading `~/` already expanded; otherwise exactly as the tag wrote it.
    public let path: String
    public let kind: Kind
    /// `[[audio_as_voice]]` was present and this is an audio file (base.py:3337, "is_voice only for audio").
    public let asVoice: Bool
    /// `[[as_document]]` was present (message-global directive, base.py:3322-3326).
    public let asDocument: Bool

    public init(path: String, kind: Kind, asVoice: Bool = false, asDocument: Bool = false) {
        self.path = path
        self.kind = kind
        self.asVoice = asVoice
        self.asDocument = asDocument
    }

    public var fileName: String {
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
        return last.map(String.init) ?? path
    }
}

public enum MediaTags {
    // base.py:1289-1301 (MEDIA_DELIVERY_EXTS), without dots.
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg"]
    private static let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "3gp"]
    private static let audioExts: Set<String> = ["mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac"]
    private static let otherExts: [String] = [
        "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub",
        "xlsx", "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml",
        "kmz", "kml", "geojson", "gpx",
        "pptx", "ppt", "odp", "key",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa",
        "html", "htm",
    ]

    // base.py:1326 CJK full-width terminators (#88038).
    private static let cjkTerminators = "（）〈〉《》：，。；！？、\u{201C}\u{201D}\u{2018}\u{2019}【】"

    // base.py:1328-1333 MEDIA_TAG_CLEANUP_RE, longest extension first so `tar` never shadows `tar.gz`'s `gz` etc.
    private static let tagRegex: NSRegularExpression? = {
        let all = Array(imageExts) + Array(videoExts) + Array(audioExts) + otherExts
        let alternation = all.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.joined(separator: "|")
        let pattern = #"[`"'*_]{0,3}MEDIA:\s*"#
            + #"(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|"#
            + #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + alternation + #"))"#
            + #"(?=[\s`"'*_,;:)\]}\["# + cjkTerminators + #"]|MEDIA:|\.(?:\s|$)|$)[`"'*_]{0,3}\.?"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let fencedRegex = try? NSRegularExpression(pattern: #"```[^\n]*\n.*?```"#, options: [.dotMatchesLineSeparators])
    private static let inlineRegex = try? NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let quoteRegex = try? NSRegularExpression(pattern: #"^>.*$"#, options: [.anchorsMatchLines])
    private static let mediaPrefixRegex = try? NSRegularExpression(pattern: #"MEDIA:\s*$"#)
    private static let blankLinesRegex = try? NSRegularExpression(pattern: #"\n{3,}"#)

    /// Removes deliverable MEDIA tags and the two directives from display text and returns the refs in order,
    /// de-duplicated. Never throws; text without any directive is returned unchanged.
    public static func split(
        _ text: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (text: String, media: [MediaRef]) {
        // base.py:1419-1420 _has_media_directives (case-sensitive substring checks)
        guard text.contains("MEDIA:") || text.contains("[[audio_as_voice]]") || text.contains("[[as_document]]") else {
            return (text, [])
        }
        let hasVoice = text.contains("[[audio_as_voice]]")
        let hasDocument = text.contains("[[as_document]]")
        let cleaned = text.replacingOccurrences(of: "[[audio_as_voice]]", with: "")
            .replacingOccurrences(of: "[[as_document]]", with: "")

        let ns = cleaned as NSString
        var spans: [NSRange] = []
        var media: [MediaRef] = []
        var seen = Set<String>()

        if let regex = tagRegex, cleaned.contains("MEDIA:") || cleaned.range(of: "media:", options: .caseInsensitive) != nil {
            let masked = maskProtected(cleaned) as NSString
            for match in regex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
                spans.append(match.range)
                let rawPath = ns.substring(with: match.range(at: 1))
                let path = expandHome(normalize(rawPath), home: home)
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
                let kind = kind(forPath: path)
                media.append(MediaRef(path: path, kind: kind, asVoice: hasVoice && kind == .audio, asDocument: hasDocument))
            }
        }

        var result = delete(spans, from: cleaned)
        if let blank = blankLinesRegex {
            result = blank.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "\n\n")
        }
        // base.py:3358-3360: rstrip only
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return (result, media)
    }

    // base.py:1400-1404
    private static func normalize(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["`", "\"", "'"]
        if path.count >= 2, let first = path.first, first == path.last, quotes.contains(first) {
            path = String(path.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let first = path.first, quotes.contains(first) { path.removeFirst() }
        let trailing: Set<Character> = ["`", "\"", "'", ",", ".", ";", ":", ")", "}", "]"]
        while let last = path.last, trailing.contains(last) { path.removeLast() }
        return path
    }

    private static func expandHome(_ path: String, home: URL) -> String {
        guard path.hasPrefix("~/") else { return path }
        return home.path + String(path.dropFirst(1))
    }

    private static func kind(forPath path: String) -> MediaRef.Kind {
        guard let dot = path.lastIndex(of: ".") else { return .file }
        let ext = path[path.index(after: dot)...].lowercased()
        if imageExts.contains(ext) { return .image }
        if audioExts.contains(ext) { return .audio }
        if videoExts.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        return .file
    }

    // base.py:3276-3293 _mask_protected_spans: blank fenced code, inline code and blockquotes, preserving offsets
    // (UTF-16 units become spaces, newlines kept). A backtick path directly after `MEDIA:` is a quoted path, not code.
    private static func maskProtected(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [NSRange] = fencedRegex?.matches(in: text, range: full).map(\.range) ?? []
        for match in inlineRegex?.matches(in: text, range: full) ?? [] {
            let start = match.range.location
            let lookStart = max(0, start - 20)
            let before = ns.substring(with: NSRange(location: lookStart, length: start - lookStart))
            if let prefix = mediaPrefixRegex,
               prefix.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil {
                continue
            }
            spans.append(match.range)
        }
        spans += quoteRegex?.matches(in: text, range: full).map(\.range) ?? []
        var units = Array(text.utf16)
        for span in spans {
            for index in span.location..<(span.location + span.length) where units[index] != 0x0A {
                units[index] = 0x20
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // base.py:1498-1512 _delete_spans: merge overlapping spans, delete back to front.
    private static func delete(_ spans: [NSRange], from text: String) -> String {
        guard !spans.isEmpty else { return text }
        var merged: [NSRange] = []
        for span in spans.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, span.location <= last.location + last.length {
                let end = max(last.location + last.length, span.location + span.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(span)
            }
        }
        var units = Array(text.utf16)
        for span in merged.reversed() {
            units.removeSubrange(span.location..<(span.location + span.length))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

public enum MediaSafetyError: Error, Equatable, Sendable, LocalizedError {
    case notAbsolute
    case notFound
    case notRegularFile
    case forbidden
    /// A symlink on the way leads to a network / automount location (never touched).
    case remoteLocation
    /// A symlink on the way leads to an external volume or a privacy-protected folder: needs a click.
    case needsClick

    public var errorDescription: String? {
        switch self {
        case .remoteLocation: return "This file is on a network location, so it is not opened from chat."
        case .needsClick: return "This file is in a protected or external location; click to check it."
        case .notAbsolute: return "This file reference is not an absolute path, so it was not opened."
        case .notFound: return "The file no longer exists at that location."
        case .notRegularFile: return "That path is a folder or special item, not a regular file."
        case .forbidden: return "This file is in a protected location (credentials or system files), so it will not be opened."
        }
    }
}

/// Port of `validate_media_delivery_path` (base.py:1168-1204): absolute, existing regular file after symlink
/// resolution, not under the credential/system denylist (`_MEDIA_DELIVERY_DENIED_PREFIXES`,
/// `_MEDIA_DELIVERY_DENIED_HOME_SUBPATHS`, `_ROOT_CREDENTIAL_PATHS`, base.py:829-854), plus filename rules.
/// `/usr` is refused except `/usr/local` (user-installed data); `/Applications` and `/Library` are not blocked
/// except `/Library/Keychains`.
public enum MediaSafety {
    private static let deniedSystemPrefixes = [
        "/etc", "/private/etc", "/System", "/bin", "/sbin", "/usr", "/dev", "/proc", "/sys", "/root", "/boot",
        "/var/log", "/var/lib", "/var/run", "/private/var/log", "/private/var/db", "/private/var/run",
        "/private/var/root", "/Library/Keychains",
    ]
    private static let allowedSystemExceptions = ["/usr/local"]
    private static let deniedHomeSubpaths = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config", ".azure", ".gcloud", "Library/Keychains",
    ]
    // Whole trees under ~/.hermes (base.py:846-854).
    private static let deniedHermesSubpaths = ["pairing", "mcp-tokens", "sessions", "browser-profile", "auth", "credentials"]
    private static let secretNameHints = ["token", "secret", "auth", "credential", "password", "oauth", "apikey", "api_key"]
    private static let keyPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    private static let keySuffixes = [".pem", ".key", ".p12", ".pfx"]

    /// `userInitiated` (a click) lets the symlink walk enter deferred locations; remote ones never.
    public static func check(
        _ ref: MediaRef,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userInitiated: Bool = false,
        fileManager: FileManager = .default
    ) -> Result<URL, MediaSafetyError> {
        guard ref.path.hasPrefix("/"), !ref.path.contains("\0") else { return .failure(.notAbsolute) }
        // Refuse a protected place on the text alone, before touching the filesystem.
        if MediaPathPolicy.classify(ref.path, home: home.path) == .refused || isForbidden(ref.path, home: home.path) {
            return .failure(.forbidden)
        }
        // Resolve hop by hop (never `realpath`): each symlink target is classified and denylist-checked
        // before it is touched.
        let resolved: String
        switch MediaPathPolicy.walk(ref.path, home: home.path, userInitiated: userInitiated,
                                    forbidden: { isForbidden($0, home: home.path) }) {
        case .success(let p): resolved = p
        case .failure(.remote): return .failure(.remoteLocation)
        case .failure(.deferred): return .failure(.needsClick)
        case .failure(.refused), .failure(.forbidden): return .failure(.forbidden)
        case .failure(.notFound), .failure(.tooManyLinks): return .failure(.notFound)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else { return .failure(.notFound) }
        guard !isDirectory.boolValue else { return .failure(.notRegularFile) }
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return .failure(.notRegularFile) }

        let homePath = realPath(home.path) ?? home.path
        // Check the resolved target and the lexical path: either one in a protected place is refused.
        for candidate in [resolved, MediaPathPolicy.lexical(ref.path)] where isForbidden(candidate, home: homePath) {
            return .failure(.forbidden)
        }
        return .success(URL(fileURLWithPath: resolved))
    }

    /// Compared on `MediaPathPolicy.key` (folded, firmlink alias mapped), so `/system/…`, `/.nofollow/…` or
    /// `/ſystem/…` spellings cannot slip past a prefix.
    static func isForbidden(_ raw: String, home rawHome: String) -> Bool {
        let path = MediaPathPolicy.key(raw), home = MediaPathPolicy.key(rawHome)
        if path.split(separator: "/").first?.hasPrefix(".") == true { return true }
        let name = (path as NSString).lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        if keySuffixes.contains(where: name.hasSuffix) || keyPrefixes.contains(where: name.hasPrefix) { return true }
        if allowedSystemExceptions.contains(where: { isWithin(path, MediaPathPolicy.key($0)) }) == false,
           deniedSystemPrefixes.contains(where: { isWithin(path, MediaPathPolicy.key($0)) }) { return true }
        if deniedHomeSubpaths.contains(where: { isWithin(path, home + "/" + $0.lowercased()) }) { return true }
        let hermes = home + "/.hermes"
        if isWithin(path, hermes) {
            if deniedHermesSubpaths.contains(where: { isWithin(path, hermes + "/" + $0) }) { return true }
            if name.hasPrefix("state.db") || name.hasPrefix("kanban.db") || name == "config.yaml" { return true }
            if secretNameHints.contains(where: name.contains) { return true }
        }
        return false
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // realpath(3), not URL.resolvingSymlinksInPath (which rewrites /private/var to /var).
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
