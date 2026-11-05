import AppKit
import HermesGatewayKit
import QuickLookThumbnailing
import SwiftUI

// Bot -> user files (`MEDIA:<path>` tags, research topic 7). `MessageBody` strips the tags and shows one
// `MediaAttachmentView` per ref: images as an inline thumbnail, everything else as a file chip. Nothing is
// ever opened without a user click, and every Open / Reveal re-runs `MediaSafety.check` at click time
// (MediaActions.swift). On appear, a path is first triaged on its TEXT (`MediaPathPolicy`): network and
// automount paths are never touched, external volumes and privacy-protected folders wait for a click
// ("Click to check"); only ordinary paths are checked at once, off the main thread, cached per path.
// Thumbnails are made out of process by Quick Look (`QLThumbnailGenerator`), never decoded in this app,
// and only for files up to `MediaThumbnail.maxBytes`.

// MARK: - model

/// Outcome of the lazy on-disk check for one ref.
enum MediaResolution: Equatable, Sendable {
    case available(url: URL, size: Int64, modified: Date)
    case unavailable(reason: String)
    /// Not checked on purpose (external volume or a privacy-protected folder): checked when clicked.
    case deferred
}

enum MediaResolver {
    static let typeMismatch = "The file's real name does not match the attachment, so it will not be opened."
    static let remote = "This file is on a network location, so it is not opened from chat."

    /// `MediaPathPolicy` on the text first, then `MediaSafety.check` (which walks symlinks hop by hop,
    /// re-classifying each target before touching it) plus size and date. The resolved target
    /// (after symlinks) must keep the tagged extension: a `report.pdf` link to `run.command` would
    /// otherwise launch a script on Open. `userInitiated` (a click) lifts the deferral, never the refusal.
    static func resolve(
        _ ref: MediaRef,
        userInitiated: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> MediaResolution {
        switch MediaPathPolicy.classify(ref.path, home: home.path) {
        case .remote: return .unavailable(reason: remote)
        case .refused: return .unavailable(reason: MediaSafetyError.forbidden.errorDescription ?? remote)
        case .deferred where !userInitiated: return .deferred
        case .deferred, .ordinary: break
        }
        switch MediaSafety.check(ref, home: home, userInitiated: userInitiated, fileManager: fileManager) {
        case .failure(.needsClick) where !userInitiated:
            return .deferred  // a symlink leads into a protected or external place: wait for a click
        case .failure(let error):
            return .unavailable(reason: error.errorDescription ?? "This file cannot be opened.")
        case .success(let url):
            guard url.pathExtension.lowercased() == (ref.path as NSString).pathExtension.lowercased() else {
                return .unavailable(reason: typeMismatch)
            }
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date ?? .distantPast
            return .available(url: url, size: size, modified: modified)
        }
    }
}

/// Everything a chip shows for a ref in a given state; pure so it is testable without a view.
struct MediaPresentation: Equatable {
    let symbol: String
    let title: String
    let detail: String
    let help: String
    let accessibilityLabel: String
    let isEnabled: Bool

    init(ref: MediaRef, resolution: MediaResolution?) {
        let name = VisibleText.reveal(ref.fileName)
        symbol = Self.symbol(for: ref.kind)
        title = name
        accessibilityLabel = ref.kind == .image ? "Image attachment \(name)" : "File attachment \(name)"
        switch resolution {
        case nil:
            detail = "Checking…"
            help = name
            isEnabled = false
        case .deferred:
            detail = "Click to check"
            help = "\(name) is in a protected or external location; click to check it"
            isEnabled = true
        case .available(_, let size, _):
            detail = "\(Self.kindLabel(ref)) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            help = MediaOpenPolicy.revealsOnly(ref.path) ? "Reveal \(name) in Finder" : "Open \(name)"
            isEnabled = true
        case .unavailable(let reason):
            detail = reason
            help = reason
            isEnabled = false
        }
    }

    static func symbol(for kind: MediaRef.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        }
    }

    static func kindLabel(_ ref: MediaRef) -> String {
        switch ref.kind {
        case .image: return "Image"
        case .audio: return ref.asVoice ? "Voice note" : "Audio"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .file:
            let ext = (ref.path as NSString).pathExtension
            return ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

/// A decoded, downsampled thumbnail and the point size to draw it at.
final class MediaThumbnail: @unchecked Sendable {
    let image: CGImage
    let size: CGSize

    init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }

    /// Fits `pixels` (treated as points) into the thumbnail bounds, scaling down only.
    static func displaySize(for pixels: CGSize, bounds: CGSize = DS.Size.mediaThumb) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = min(1, bounds.width / pixels.width, bounds.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }

    /// Larger files get no thumbnail (the chip shows instead): bounds Quick Look's work on a file the
    /// model picked.
    static let maxBytes: Int64 = 20 * 1024 * 1024

    /// Quick Look thumbnail, generated OUT OF PROCESS (`QLThumbnailGenerator`), so a hostile image is
    /// never decoded in this app; nil when Quick Look has no thumbnail (the chip shows instead).
    static func load(url: URL, bounds: CGSize = DS.Size.mediaThumb,
                     scale: CGFloat = DS.Size.mediaDecodePixels / DS.Size.mediaThumb.width) async -> MediaThumbnail? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: bounds, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.cgImage
        let size = displaySize(for: CGSize(width: image.width, height: image.height))
        return size == .zero ? nil : MediaThumbnail(image: image, size: size)
    }
}

/// Process-wide caches. Only successful resolutions are kept, so a missing file is re-checked the next
/// time its row appears; a click that finds the file gone evicts it.
final class MediaCache: @unchecked Sendable {
    static let shared = MediaCache()

    private final class Box: @unchecked Sendable {
        let value: MediaResolution
        init(_ value: MediaResolution) { self.value = value }
    }

    private let resolutions = NSCache<NSString, Box>()
    private let thumbnails = NSCache<NSString, MediaThumbnail>()

    init() {
        resolutions.countLimit = 512
        thumbnails.countLimit = 64
    }

    func resolution(for path: String) -> MediaResolution? { resolutions.object(forKey: path as NSString)?.value }

    func store(_ resolution: MediaResolution, for path: String) {
        guard case .available = resolution else { return evict(path) }
        resolutions.setObject(Box(resolution), forKey: path as NSString)
    }

    func evict(_ path: String) { resolutions.removeObject(forKey: path as NSString) }

    func thumbnail(for key: String) -> MediaThumbnail? { thumbnails.object(forKey: key as NSString) }

    func store(_ thumbnail: MediaThumbnail, for key: String) { thumbnails.setObject(thumbnail, forKey: key as NSString) }

    /// Thumbnails are keyed by path and modification date, so an overwritten file decodes again.
    static func thumbnailKey(path: String, modified: Date) -> String { "\(path)|\(modified.timeIntervalSinceReferenceDate)" }
}

// MARK: - views

/// The attachments area under a message's text.
struct MediaAttachmentList: View {
    let refs: [MediaRef]
    /// Refs checked (and thumbnailed) on appear; the others wait for a click like a protected folder. Group
    /// Chat user messages auto-load only the app's own copies: room history is shared, so another client could
    /// name any path there.
    var autoResolve: (MediaRef) -> Bool = { _ in true }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(refs, id: \.self) { MediaAttachmentView(ref: $0, autoResolve: autoResolve($0)) }
        }
    }
}

/// One `MEDIA:` ref: an image thumbnail once it is checked and decoded, otherwise a file chip (also the
/// disabled state for a missing or refused path, with the reason as help text and no open action).
struct MediaAttachmentView: View {
    let ref: MediaRef
    var autoResolve = true
    @State private var resolution: MediaResolution?
    @State private var thumbnail: MediaThumbnail?
    @Environment(\.motionEnabled) private var motion

    init(ref: MediaRef, autoResolve: Bool = true) {
        self.ref = ref
        self.autoResolve = autoResolve
        // Seed from the caches so a lazily re-created row does not flash through "Checking…".
        let cached = MediaCache.shared.resolution(for: ref.path)
        _resolution = State(initialValue: cached)
        if ref.kind == .image, case .available(_, _, let modified) = cached {
            let key = MediaCache.thumbnailKey(path: ref.path, modified: modified)
            _thumbnail = State(initialValue: MediaCache.shared.thumbnail(for: key))
        }
    }

    var body: some View {
        let presentation = MediaPresentation(ref: ref, resolution: resolution)
        let previewable = QuickLookPolicy.canPreview(resolution) != nil
        Group {
            if let thumbnail, presentation.isEnabled {
                // D8: a thumbnail click previews in Quick Look (Open stays in the menu).
                MediaThumbnailButton(thumbnail: thumbnail, presentation: presentation,
                                     action: previewable ? quickLook : click)
                    .transition(.opacity)
            } else {
                MediaChip(presentation: presentation, action: click)
            }
        }
        .contextMenu {
            if case .available = resolution {
                if previewable { Button("Quick Look", action: quickLook) }
                Button(MediaOpenPolicy.revealsOnly(ref.path) ? "Reveal in Finder" : "Open", action: click)
                Button("Reveal in Finder") { Task { apply(await MediaActions.reveal(ref)) } }
            }
            Button("Copy Path") { MediaActions.copyPath(ref) }
        }
        // D8: Space over the tile previews it; a checked file drags out to Finder (re-checked at drag time).
        .onHover { QuickLookController.shared.hover(ref, $0 && previewable) }
        .onDisappear { QuickLookController.shared.hover(ref, false) }
        .modifier(MediaDragSource(ref: ref, enabled: presentation.isEnabled && resolution != .deferred))
        .task(id: ref) { await load() }
    }

    private func quickLook() {
        Task { apply(await QuickLookController.shared.preview(ref)) }
    }

    /// A deferred chip is only checked by its first click; afterwards a click opens (or reveals).
    private func click() {
        let deferred = resolution == .deferred
        Task {
            if deferred {
                apply(await MediaActions.check(ref))
                await loadThumbnail()
            } else {
                apply(await MediaActions.open(ref))
            }
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
        if let cached = MediaCache.shared.resolution(for: ref.path) {
            resolved = cached
        } else if !autoResolve {
            resolved = .deferred  // not cached: nothing touches the path before a click
        } else {
            resolved = await Task.detached(priority: .utility) { MediaResolver.resolve(ref) }.value
            MediaCache.shared.store(resolved, for: ref.path)
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

/// `media-chip`: kind symbol, file name, kind and size (or the reason it cannot open).
struct MediaChip: View {
    let presentation: MediaPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DS.Space.s2) {
                Image(systemName: presentation.symbol)
                    .font(DS.Typeface.icon)
                    .foregroundStyle(DS.Palette.muted)
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text(presentation.title)
                        .font(DS.Typeface.bodyMedium)
                        .foregroundStyle(presentation.isEnabled ? DS.Palette.ink : DS.Palette.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Text(presentation.detail)
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, DS.Space.s3).padding(.trailing, DS.Space.gutter).padding(.vertical, DS.Space.s2)
            .frame(maxWidth: DS.Size.mediaChipMax, alignment: .leading)
        }
        .buttonStyle(MediaTileStyle(radius: DS.Radius.chip, filled: true))
        .disabled(!presentation.isEnabled)
        .help(presentation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.detail)
        .accessibilityAddTraits(.isButton)
    }
}

struct MediaThumbnailButton: View {
    let thumbnail: MediaThumbnail
    let presentation: MediaPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(thumbnail.size, contentMode: .fit)
                .frame(maxWidth: thumbnail.size.width, maxHeight: thumbnail.size.height)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(MediaTileStyle(radius: DS.Radius.card, filled: false))
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.help)
    }
}

/// Hairline frame, hover tint, pressed scale 0.96 behind the motion gate; disabled reads as a quiet
/// surface rather than a fade.
struct MediaTileStyle: ButtonStyle {
    let radius: CGFloat
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motionEnabled) private var motion

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .background(filled ? (hovering && isEnabled ? DS.Palette.selected : DS.Palette.surface) : .clear, in: shape)
                .overlay {
                    shape.fill(!filled && hovering ? DS.Palette.hover : .clear)
                    shape.strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline)
                }
                .scaleEffect(configuration.isPressed && isEnabled && motion ? DS.Motion.pressedScale : 1)
                .animation(motion ? DS.Motion.press : nil, value: configuration.isPressed)
                .contentShape(shape)
        }
    }
}

/// D8: drag a checked bot file out of the chat (QuickLook.swift, `MediaDrag`).
struct MediaDragSource: ViewModifier {
    let ref: MediaRef
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { MediaDrag.provider(for: ref) }
        } else {
            content
        }
    }
}
