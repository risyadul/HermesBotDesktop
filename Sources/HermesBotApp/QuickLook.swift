import AppKit
import HermesGatewayKit
import QuickLookUI
import SwiftUI

// D8: Quick Look for bot `MEDIA:` files and room attachments (one panel, one policy, one hover target), and
// dragging them out to Finder. Same rule as Open
// (MediaActions.swift): every preview and every drag re-runs `MediaSafety` (`MediaResolver.resolve`, user
// initiated) at that moment; the earlier lazy check is never trusted. Formats Open only reveals in Finder
// (`MediaOpenPolicy.revealsOnly`: web pages, SVG, archives, macro-enabled documents) are not previewed either.
// Quick Look renders out of process (QLPreviewPanel), like the thumbnails.
//
// How: click an image thumbnail, press Space while the pointer is over a file or image (not while typing), or
// choose Quick Look in its context menu. Space or Escape closes the panel.

enum QuickLookPolicy {
    /// A checked file Quick Look may show.
    static func canPreview(_ resolution: MediaResolution?) -> URL? {
        guard case .available(let url, _, _)? = resolution, !MediaOpenPolicy.revealsOnly(url.path) else { return nil }
        return url
    }

    static let spaceKeyCode: UInt16 = 49

    enum KeyAction: Equatable { case none, open, close }

    /// The Space bar: closes an open panel; otherwise previews the file under the pointer unless a text field
    /// or editor has focus (Space types a space there). Any modifier leaves the key alone.
    static func keyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hovering: Bool, panelVisible: Bool,
                          editingText: Bool) -> KeyAction {
        guard keyCode == spaceKeyCode,
              modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .none }
        if panelVisible { return .close }
        return hovering && !editingText ? .open : .none
    }
}

/// The context menu of a media tile, Bot Chat file and room attachment alike: one list, so a reveal-only
/// format shows a single "Reveal in Finder" and never Quick Look or Open.
enum MediaContextMenu {
    enum Item: Equatable { case quickLook, open, reveal, copyPath }

    static func items(_ resolution: MediaResolution?) -> [Item] {
        guard case .available(let url, _, _)? = resolution else { return [.copyPath] }
        return MediaOpenPolicy.revealsOnly(url.path) ? [.reveal, .copyPath] : [.quickLook, .open, .reveal, .copyPath]
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .quickLook: return "Quick Look"
        case .open: return "Open"
        case .reveal: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }
}

/// Dragging a bot file out of the chat (to Finder, Mail, …) hands over the checked file itself.
enum MediaDrag {
    /// The file a drag carries: only one that passes the click-time check right now.
    static func url(for ref: MediaRef, resolve: (MediaRef) -> MediaResolution = { MediaResolver.resolve($0, userInitiated: true) }) -> URL? {
        guard case .available(let url, _, _) = resolve(ref) else { return nil }
        return url
    }

    static func provider(for ref: MediaRef) -> NSItemProvider {
        guard let url = url(for: ref), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// Owns what the shared Quick Look panel shows. The panel asks the responder chain for a controller; the app
/// delegate answers for this one (AppDelegate.swift), and `show` also sets it directly.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private(set) var items: [URL] = []
    /// The media tile under the pointer: what Space previews.
    private(set) var hovered: MediaRef?
    private var monitor: Any?

    func hover(_ ref: MediaRef, _ inside: Bool) {
        if inside { hovered = ref } else if hovered == ref { hovered = nil }
    }

    /// Re-checks the file, then previews it (a refused or reveal-only file shows nothing). Returns the fresh
    /// resolution so the tile can show a new failure.
    @discardableResult
    func preview(_ ref: MediaRef) async -> MediaResolution {
        let fresh = await MediaActions.check(ref)
        if let url = QuickLookPolicy.canPreview(fresh) { show([url]) }
        return fresh
    }

    /// Shows files the caller has just checked (a room attachment's click checks first, then previews).
    func show(_ urls: [URL]) {
        items = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.currentController == nil {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Space previews the hovered tile (or closes the panel). Installed once at launch.
    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (code, modifiers) = (event.keyCode, event.modifierFlags)
            let handled = MainActor.assumeIsolated { QuickLookController.shared.handle(keyCode: code, modifiers: modifiers) }
            return handled ? nil : event
        }
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let panelVisible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
        let editing = NSApp.keyWindow?.firstResponder is NSText
        switch QuickLookPolicy.keyAction(keyCode: keyCode, modifiers: modifiers, hovering: hovered != nil,
                                         panelVisible: panelVisible, editingText: editing) {
        case .none: return false
        case .close: close(); return true
        case .open:
            guard let ref = hovered else { return false }
            Task { await preview(ref) }
            return true
        }
    }

    // MARK: panel control (forwarded by the app delegate)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { items.indices.contains(index) ? items[index] : nil }
        return url.map { $0 as NSURL }
    }
}
