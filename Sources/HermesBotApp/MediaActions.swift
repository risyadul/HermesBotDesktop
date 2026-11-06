import AppKit
import HermesGatewayKit
import UniformTypeIdentifiers

/// What a click does with a bot-sent file. Formats that can run code or scripts when opened (web pages,
/// SVG, XML, legacy and macro-enabled Office and OpenDocument files, archives, KML/KMZ map files and
/// app packages) are only revealed in
/// Finder; everything else opens in the app registered for its TYPE (`urlForApplication(toOpen: UTType)`),
/// so a per-file "Open With" override planted on the file is ignored.
enum MediaOpenPolicy {
    static let revealOnlyExtensions: Set<String> = [
        "html", "htm", "xhtml", "svg", "xml",
        "doc", "xls", "ppt", "docm", "xlsm", "pptm",
        "zip", "apk", "ipa", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "odt", "ods", "odp", "kml", "kmz",
    ]

    static func revealsOnly(_ path: String) -> Bool {
        revealOnlyExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// User-initiated only. Each action re-checks the path at click time (off the main thread) and acts on the
/// main actor; the result of the earlier lazy check is never trusted for opening.
@MainActor enum MediaActions {
    /// The click-time check (also lifts a `deferred` chip). Cached like the lazy check.
    static func check(_ ref: MediaRef) async -> MediaResolution {
        let fresh = await Task.detached(priority: .userInitiated) { MediaResolver.resolve(ref, userInitiated: true) }.value
        MediaCache.shared.store(fresh, for: ref.path)
        return fresh
    }

    /// Opens with the type's default app, or reveals a reveal-only type. Returns the fresh resolution so
    /// the view can show a new failure.
    static func open(_ ref: MediaRef) async -> MediaResolution {
        let fresh = await check(ref)
        guard case .available(let url, _, _) = fresh else { return fresh }
        if MediaOpenPolicy.revealsOnly(url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]); return fresh }
        guard let type = UTType(filenameExtension: url.pathExtension),
              let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return fresh
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
        return fresh
    }

    static func reveal(_ ref: MediaRef) async -> MediaResolution {
        let fresh = await check(ref)
        if case .available(let url, _, _) = fresh { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return fresh
    }

    static func copyPath(_ ref: MediaRef) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ref.path, forType: .string)
    }
}
