import Foundation

/// Triage of a model-chosen `MEDIA:` path BEFORE any filesystem call on it: a stat on an automount or
/// network path can mount a share or send credentials to a remote host, and one on a TCC-protected folder
/// raises a privacy prompt the user did not ask for.
///
/// Comparison runs on `key`: the lexically normalized path, NFD, case- and width-folded (APFS folds `ſ` to
/// `s`, which `lowercased()` does not), with the `/System/Volumes/Data` firmlink alias mapped to `/`.
/// Paths whose first component starts with `.` (`/.nofollow`, `/.resolve`, `/.vol`: kernel path-lookup
/// prefixes) are refused outright. Symlinks are never resolved here; `walk` resolves them one hop at a time
/// and classifies every hop BEFORE touching it.
public enum MediaPathPolicy {
    public enum Verdict: Equatable, Sendable {
        /// Ordinary location: resolve on appear.
        case ordinary
        /// Network or automount location: never touched (no click either).
        case remote
        /// External volume or a privacy-protected folder: resolved only when the user clicks.
        case deferred
        /// A special path form (`/.nofollow/…`, `/.vol/…`): never touched.
        case refused
    }

    /// Why `walk` stopped.
    public enum Stop: Error, Equatable, Sendable {
        case remote, deferred, refused, forbidden, notFound, tooManyLinks
    }

    /// Network shares and automount roots (`/etc/auto_master`: `/net`, `/home`; `/Network` server mounts).
    static let remoteRoots = ["/net", "/network", "/automount", "/home", "/private/var/automount"]
    /// Mounted volumes (external disks, mounted shares): stat only on a click.
    static let deferredRoots = ["/volumes"]
    /// TCC-protected home folders and file-provider / iCloud trees.
    static let protectedHomeSubpaths = [
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
        "Library/Mobile Documents", "Library/CloudStorage",
    ]
    /// The data volume's firmlink root: `/System/Volumes/Data/X` is `/X`.
    static let dataVolumeAlias = "/system/volumes/data"
    /// `MAXSYMLINKS` on macOS.
    public static let maxLinks = 32

    public static func classify(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Verdict {
        let p = key(path)
        if p.split(separator: "/").first?.hasPrefix(".") == true { return .refused }
        if remoteRoots.contains(where: { isWithin(p, $0) }) { return .remote }
        if deferredRoots.contains(where: { isWithin(p, $0) }) { return .deferred }
        let h = key(home)
        if protectedHomeSubpaths.contains(where: { isWithin(p, h + "/" + key($0).dropFirst()) }) { return .deferred }
        return .ordinary
    }

    /// The folded comparison form of `path` (see the type comment). Text only.
    public static func key(_ path: String) -> String {
        let p = lexical(path).decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        guard isWithin(p, dataVolumeAlias) else { return p }
        let rest = String(p.dropFirst(dataVolumeAlias.count))
        return rest.isEmpty ? "/" : rest
    }

    /// `.` and `..` folded, repeated slashes dropped; purely textual (no `stat`, unlike `standardizingPath`).
    public static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Resolves `path` like the kernel does (component by component, `..` applied to the RESOLVED parent,
    /// at most `maxLinks` symlinks), replacing `realpath(3)`. Every hop is classified, and the path it
    /// leads to checked against `forbidden`, before it is `lstat`ed; a `deferred` hop stops the walk unless
    /// `userInitiated`.
    public static func walk(_ path: String, home: String, userInitiated: Bool,
                            forbidden: (String) -> Bool = { _ in false }) -> Result<String, Stop> {
        var resolved = ""  // "" = the root
        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var links = 0
        while let comp = pending.popLast() {
            if comp.isEmpty || comp == "." { continue }
            if comp == ".." {
                if let i = resolved.lastIndex(of: "/") { resolved = String(resolved[..<i]) }
                continue
            }
            let candidate = resolved + "/" + comp
            switch classify(candidate, home: home) {
            case .refused: return .failure(.refused)
            case .remote: return .failure(.remote)
            case .deferred where !userInitiated: return .failure(.deferred)
            case .deferred, .ordinary: break
            }
            // The denylist sees the whole path as currently understood (this hop plus what is left), so an
            // allowed subtree of a denied root (`/usr/local` under `/usr`) is not refused half-way.
            if forbidden(lexical(([candidate] + pending.reversed()).joined(separator: "/"))) { return .failure(.forbidden) }
            var st = stat()
            guard lstat(candidate, &st) == 0 else { return .failure(.notFound) }
            guard (st.st_mode & S_IFMT) == S_IFLNK else { resolved = candidate; continue }
            links += 1
            guard links <= maxLinks, let target = readLink(candidate) else {
                return .failure(links > maxLinks ? .tooManyLinks : .notFound)
            }
            if target.hasPrefix("/") { resolved = "" }
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return .success(resolved.isEmpty ? "/" : resolved)
    }

    private static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buf, Int(PATH_MAX))
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
