import AppKit
import HermesGatewayKit
import QuickLookThumbnailing
import SwiftUI

/// B11: click an image in a Bot Chat message to zoom and pan it in a sheet (Desktop `zoomable-image.tsx`).
/// The large rendition comes from Quick Look out of process, like every thumbnail here: a bot-named image is
/// never decoded in this app. Pinch or the buttons zoom (1×–8×), drag pans, double-click resets.
struct ImageZoomSheet: View {
    let ref: MediaRef
    let url: URL
    let onClose: () -> Void
    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoom = ImageZoomState()
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    static let size = CGSize(width: 760, height: 560)
    /// Pixels asked of Quick Look for the zoomed rendition.
    static let renditionPixels: CGFloat = 2048

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Text(VisibleText.reveal(ref.fileName)).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                IconButton(symbol: "minus.magnifyingglass", label: "Zoom out") { zoom.step(-1) }.disabled(zoom.scale <= ImageZoomState.minScale)
                Text("\(Int((zoom.scale * 100).rounded()))%").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).monospacedDigit()
                IconButton(symbol: "plus.magnifyingglass", label: "Zoom in") { zoom.step(1) }.disabled(zoom.scale >= ImageZoomState.maxScale)
                IconButton(symbol: "arrow.counterclockwise", label: "Reset zoom") { zoom.reset() }
                Button("Open") { Task { _ = await MediaActions.open(ref) } }.buttonStyle(DSButtonStyle(kind: .secondary))
                Button("Close", action: onClose).buttonStyle(DSButtonStyle(kind: .primary)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s2)
            Hairline()
            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .scaleEffect(ImageZoomState.clamp(zoom.scale * pinch))
                            .offset(x: zoom.offset.width + drag.width, y: zoom.offset.height + drag.height)
                            .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                                .onEnded { v in zoom.scale = ImageZoomState.clamp(zoom.scale * v.magnification) })
                            .simultaneousGesture(DragGesture().updating($drag) { v, s, _ in s = v.translation }
                                .onEnded { v in zoom.pan(by: v.translation) })
                            .onTapGesture(count: 2) { zoom.reset() }
                            .accessibilityLabel("Image \(ref.fileName), \(Int((zoom.scale * 100).rounded())) percent")
                    } else if failed {
                        Text("Quick Look can't show this image.").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .background(DS.Palette.surface)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DS.Palette.window)
        .task { await load() }
    }

    private func load() async {
        if let rendition = await Self.rendition(of: url, side: Self.renditionPixels) {
            image = rendition
        } else {
            failed = true
        }
    }

    /// Nonisolated, so the non-Sendable `QLThumbnailRepresentation` never crosses to the main actor (Swift 6.1
    /// rejects that); only its `CGImage` does.
    private nonisolated static func rendition(of url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 1,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// Zoom and pan state of the zoom sheet (unit tested).
struct ImageZoomState: Equatable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 8
    static let stepFactor: CGFloat = 1.5
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static func clamp(_ s: CGFloat) -> CGFloat { min(maxScale, max(minScale, s)) }

    mutating func step(_ direction: Int) {
        scale = Self.clamp(direction > 0 ? scale * Self.stepFactor : scale / Self.stepFactor)
        if scale == Self.minScale { offset = .zero }
    }

    /// Panning only means something while zoomed in; at 1× the image stays centred.
    mutating func pan(by t: CGSize) {
        guard scale > Self.minScale else { offset = .zero; return }
        offset = CGSize(width: offset.width + t.width, height: offset.height + t.height)
    }

    mutating func reset() { scale = Self.minScale; offset = .zero }
}

/// B11: what a click on an image attachment does when a chat offers zoom (nil: the image opens as before).
struct ImageZoomAction {
    let present: @MainActor (MediaRef, URL) -> Void
}

private struct ImageZoomKey: EnvironmentKey { static let defaultValue: ImageZoomAction? = nil }

extension EnvironmentValues {
    var imageZoom: ImageZoomAction? {
        get { self[ImageZoomKey.self] }
        set { self[ImageZoomKey.self] = newValue }
    }
}
