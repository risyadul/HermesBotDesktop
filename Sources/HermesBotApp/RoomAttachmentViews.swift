import AppKit
import HermesGatewayKit
import QuickLook
import SwiftUI

// C2.1: files sent with a Group Chat message (`RoomAttachments`: copies in the app's own folder, named by path
// in the message). Images show as an inline thumbnail, other files as a chip with kind and size. A click opens
// Quick Look; the context menu has Quick Look, Open, Reveal in Finder and Copy Path. When the app's copy was
// deleted the chip says so in plain words (the bots cannot open it either).
// MediaSafety rules are the Bot Chat ones (MediaViews.swift / MediaActions.swift): only the app's own copies
// are checked on appear (room history is shared, another client could name any path), thumbnails come from
// Quick Look out of process, every click re-checks the path first, and formats that can run code
// (`MediaOpenPolicy.revealOnlyExtensions`) are only revealed in Finder, never previewed or opened.

enum RoomAttachmentPresentation {
    static let deletedCopy = "This copy was deleted, so the bots can no longer open it either."

    /// The chip for one attachment: Bot Chat's presentation, with the app's own deleted copy in plain words
    /// and a click that previews.
    static func presentation(ref: MediaRef, resolution: MediaResolution?, ownCopy: Bool) -> MediaPresentation {
        let base = MediaPresentation(ref: ref, resolution: resolution)
        if ownCopy, isMissing(resolution) {
            return MediaPresentation(base, detail: deletedCopy, help: deletedCopy)
        }
        if case .available = resolution {
            let name = VisibleText.reveal(ref.fileName)
            let help = MediaOpenPolicy.revealsOnly(ref.path) ? "Reveal \(name) in Finder" : "Quick Look \(name)"
            return MediaPresentation(base, detail: base.detail, help: help)
        }
        return base
    }

    /// The check found nothing at the path (`MediaSafetyError.notFound`).
    static func isMissing(_ resolution: MediaResolution?) -> Bool {
        guard case .unavailable(let reason) = resolution else { return false }
        return reason == MediaSafetyError.notFound.errorDescription
    }

    enum Click: Equatable {
        /// A protected or external path: the first click only checks it.
        case check
        case quickLook(URL)
        case reveal(URL)
        case none
    }

    /// What a click does with a freshly checked attachment.
    static func click(ref: MediaRef, fresh: MediaResolution) -> Click {
        switch fresh {
        case .available(let url, _, _): return MediaOpenPolicy.revealsOnly(url.path) ? .reveal(url) : .quickLook(url)
        case .deferred: return .check
        case .unavailable: return .none
        }
    }
}

extension MediaPresentation {
    /// A copy with another detail line and help text.
    init(_ base: MediaPresentation, detail: String, help: String) {
        symbol = base.symbol; title = base.title; accessibilityLabel = base.accessibilityLabel
        isEnabled = base.isEnabled
        self.detail = detail
        self.help = help
    }
}

/// The attachments under a user message in a room.
struct RoomAttachmentList: View {
    let refs: [MediaRef]
    let roomId: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(refs, id: \.self) { ref in
                RoomAttachmentView(ref: ref, ownCopy: RoomAttachmentStore.contains(ref.path, room: roomId))
            }
        }
    }
}

struct RoomAttachmentView: View {
    let ref: MediaRef
    /// The app's own copy for this room: checked (and thumbnailed) on appear; any other path waits for a click.
    let ownCopy: Bool
    @State private var resolution: MediaResolution?
    @State private var thumbnail: MediaThumbnail?
    @State private var preview: URL?
    @Environment(\.motionEnabled) private var motion

    init(ref: MediaRef, ownCopy: Bool) {
        self.ref = ref
        self.ownCopy = ownCopy
        // Seed from the caches so a lazily re-created row does not flash through "Checking…".
        let cached = MediaCache.shared.resolution(for: ref.path)
        _resolution = State(initialValue: cached)
        if ref.kind == .image, case .available(_, _, let modified) = cached {
            _thumbnail = State(initialValue: MediaCache.shared.thumbnail(for: MediaCache.thumbnailKey(path: ref.path, modified: modified)))
        }
    }

    var body: some View {
        let presentation = RoomAttachmentPresentation.presentation(ref: ref, resolution: resolution, ownCopy: ownCopy)
        Group {
            if let thumbnail, presentation.isEnabled {
                MediaThumbnailButton(thumbnail: thumbnail, presentation: presentation, action: click)
                    .transition(.opacity)
            } else {
                MediaChip(presentation: presentation, action: click)
            }
        }
        .contextMenu {
            if case .available(let url, _, _) = resolution {
                if !MediaOpenPolicy.revealsOnly(url.path) {
                    Button("Quick Look", action: click)
                    Button("Open") { Task { apply(await MediaActions.open(ref)) } }
                }
                Button("Reveal in Finder") { Task { apply(await MediaActions.reveal(ref)) } }
            }
            Button("Copy Path") { MediaActions.copyPath(ref) }
        }
        .quickLookPreview($preview)
        .task(id: ref) { await load() }
    }

    /// Re-checks the path, then previews (or reveals a reveal-only type). A deferred chip's first click only
    /// checks it.
    private func click() {
        Task {
            let fresh = await MediaActions.check(ref)
            apply(fresh)
            switch RoomAttachmentPresentation.click(ref: ref, fresh: fresh) {
            case .quickLook(let url): preview = url
            case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
            case .check, .none: break
            }
            await loadThumbnail()
        }
    }

    private func apply(_ fresh: MediaResolution) {
        guard fresh != resolution else { return }
        withDSAnimation(motion, DS.Motion.ease) {
            resolution = fresh
            if case .unavailable = fresh { thumbnail = nil }
        }
    }

    private func load() async {
        let ref = ref
        let resolved: MediaResolution
        if ownCopy {
            // Always re-checked (a local file in the app's folder): a copy deleted since it was cached says so.
            resolved = await Task.detached(priority: .utility) { MediaResolver.resolve(ref) }.value
            MediaCache.shared.store(resolved, for: ref.path)
        } else if let cached = MediaCache.shared.resolution(for: ref.path) {
            resolved = cached
        } else {
            resolved = .deferred  // not the app's copy: nothing touches the path before a click
        }
        guard !Task.isCancelled else { return }
        if resolved != resolution { resolution = resolved }
        await loadThumbnail()
    }

    private func loadThumbnail() async {
        guard ref.kind == .image, thumbnail == nil, case .available(let url, let size, let modified) = resolution,
              size <= MediaThumbnail.maxBytes else { return }
        let key = MediaCache.thumbnailKey(path: ref.path, modified: modified)
        let made: MediaThumbnail?
        if let cached = MediaCache.shared.thumbnail(for: key) {
            made = cached
        } else {
            made = await MediaThumbnail.load(url: url)
            if let made { MediaCache.shared.store(made, for: key) }
        }
        guard !Task.isCancelled, let made else { return }
        withDSAnimation(motion, DS.Motion.ease) { thumbnail = made }
    }
}
