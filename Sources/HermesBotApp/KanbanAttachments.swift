import AppKit
import HermesGatewayKit
import UniformTypeIdentifiers

// Card attachments (K2) on the local side: reading a picked or dropped file for upload (regular file, size cap),
// and saving a downloaded one where it can be opened. A download is written to a fresh 0700 folder under the
// app's caches (`~/Library/Caches/HermesBotApp/Kanban Attachments/<uuid>/<name>`), 0600, quarantined, with a
// name that cannot leave that folder. It is then opened only after the same click-time check Bot Chat files
// get (`MediaSafety.check`), and never executed: apps, scripts, installers and other runnable or active types
// are revealed in Finder instead (as `MediaOpenPolicy` does for its reveal-only types).

enum KanbanAttachmentFiles {
    /// Where a checked download goes.
    enum Action: Equatable {
        case open
        /// Shown in Finder, never opened (runnable or active content, or a protected name).
        case reveal
        /// Not opened at all; the reason is shown.
        case refuse(String)
    }

    /// A local file read for upload.
    struct Upload: Sendable, Equatable {
        let name: String
        let contentType: String?
        let data: Data
    }

    enum Failure: Error, RedactionSafeError, Equatable {
        case notFound(String)
        case notRegularFile(String)
        case tooLarge(String, limitMB: Int)
        case unreadable(String)
        case saveFailed

        var description: String {
            switch self {
            case .notFound(let n): return "\(n) no longer exists."
            case .notRegularFile(let n): return "\(n) is a folder or special item, not a file."
            case .tooLarge(let n, let mb): return "\(n) is larger than \(mb) MB, the Kanban attachment limit."
            case .unreadable(let n): return "\(n) could not be read."
            case .saveFailed: return "The download could not be saved."
            }
        }
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HermesBotApp/Kanban Attachments", isDirectory: true)
    }

    /// Downloads older than this are removed when the next one is saved.
    static let keepDownloads: TimeInterval = 24 * 3600
    static let maxNameLength = 120

    /// Types never opened from a card, only revealed: anything that runs code or installs something when
    /// opened, beyond what `UTType` conformance already catches (it misses some of these by extension).
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyc", "pyw",
        "rb", "pl", "php", "js", "mjs", "cjs", "jxa", "scpt", "scptd", "applescript", "workflow", "action",
        "pkg", "mpkg", "dmg", "iso", "jar", "class", "exe", "msi", "bat", "cmd", "ps1", "vbs", "wsf", "scr", "com",
        "dylib", "so", "bundle", "plugin", "kext", "prefpane", "saver", "osax", "appex", "xpc", "qlgenerator",
        "mobileconfig", "configprofile", "webloc", "inetloc", "fileloc", "url", "desktop", "lnk",
        "run", "bin", "out", "elf", "deb", "rpm", "apk", "ipa",
    ]

    /// A server-supplied name made safe to name a file in our own folder: the last path component only
    /// (`/` and `\` both split), control and format characters dropped (no hidden RTL overrides), `:` replaced,
    /// leading dots and surrounding spaces removed, capped in length with the extension kept. Empty, `.` or
    /// `..` becomes `attachment-<id>`.
    static func safeName(_ raw: String, id: Int) -> String {
        let last = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let kept = last.unicodeScalars.filter { s in
            let c = s.properties.generalCategory
            return c != .control && c != .format && c != .lineSeparator && c != .paragraphSeparator && s != "\0"
        }
        var name = String(String.UnicodeScalarView(kept)).replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "attachment-\(id)" }
        if name.count > maxNameLength {
            let ext = (name as NSString).pathExtension
            let keepExt = !ext.isEmpty && ext.count < 16
            let stem = keepExt ? String((name as NSString).deletingPathExtension.prefix(maxNameLength - ext.count - 1)) : String(name.prefix(maxNameLength))
            name = keepExt ? stem + "." + ext : stem
        }
        return name
    }

    /// Reads a user-picked file for upload: a regular file (symlinks resolved) up to `maxBytes`, refused by
    /// size before it is read.
    static func readUpload(_ url: URL, maxBytes: Int = KanbanAPI.maxAttachmentBytes, fileManager: FileManager = .default) throws -> Upload {
        let name = url.lastPathComponent
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved.path) else { throw Failure.notFound(name) }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw Failure.notRegularFile(name) }
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= maxBytes else { throw Failure.tooLarge(name, limitMB: maxBytes / (1024 * 1024)) }
        guard let data = try? Data(contentsOf: resolved, options: .mappedIfSafe) else { throw Failure.unreadable(name) }
        guard data.count <= maxBytes else { throw Failure.tooLarge(name, limitMB: maxBytes / (1024 * 1024)) }
        return Upload(name: name, contentType: UTType(filenameExtension: resolved.pathExtension)?.preferredMIMEType, data: data)
    }

    /// Writes a download into a new folder under `root` and returns the file. Older downloads are pruned.
    static func save(_ data: Data, filename: String, id: Int, root: URL = KanbanAttachmentFiles.root,
                     fileManager fm: FileManager = .default, now: Date = Date()) throws -> URL {
        prune(root: root, olderThan: now.addingTimeInterval(-keepDownloads), fileManager: fm)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw Failure.saveFailed }
        let file = dir.appendingPathComponent(safeName(filename, id: id), isDirectory: false)
        // The name is one component by construction; checked again so no future change can escape the folder.
        guard file.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
              fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.saveFailed
        }
        quarantine(file)
        return file
    }

    /// The decision for a saved download, made at click time. A file the Bot Chat check refuses for its
    /// name or place is only revealed; other check failures are not opened at all.
    static func action(for file: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Action {
        switch MediaSafety.check(MediaRef(path: file.path, kind: .file), home: home, userInitiated: true) {
        case .failure(.forbidden): return .reveal
        case .failure(let e): return .refuse(e.errorDescription ?? "This file cannot be opened.")
        case .success(let resolved):
            return opensDirectly(resolved) ? .open : .reveal
        }
    }

    /// True only for a passive document type: an extension the system declares, not runnable, not reveal-only for
    /// Bot Chat files, and whose type is not an app, bundle, package, script or executable.
    static func opensDirectly(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        guard !ext.isEmpty, !runnableExtensions.contains(ext), !MediaOpenPolicy.revealsOnly(file.path),
              let type = UTType(filenameExtension: ext), type.isDeclared else { return false }  // dyn.* = unknown
        let active: [UTType] = [.executable, .script, .shellScript, .application, .applicationBundle, .unixExecutable,
                                .package, .bundle, .framework, .pluginBundle, .systemPreferencesPane, .archive, .diskImage]
        return !active.contains { type.conforms(to: $0) }
    }

    /// Opens with the type's default app, or shows the file in Finder.
    @MainActor static func perform(_ file: URL, _ action: Action) {
        switch action {
        case .refuse: return
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([file])
        case .open:
            guard let type = UTType(filenameExtension: file.pathExtension),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
                return
            }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        }
    }

    /// Marks a download as coming from elsewhere, so Gatekeeper asks before anything in it runs (best effort).
    private static func quarantine(_ file: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload", "LSQuarantineAgentName": "Hermes Bot"]
        var url = file
        try? url.setResourceValues(values)
    }

    private static func prune(root: URL, olderThan cutoff: Date, fileManager fm: FileManager) {
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: entry) }
        }
    }
}
