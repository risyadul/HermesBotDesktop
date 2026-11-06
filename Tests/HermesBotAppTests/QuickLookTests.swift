import AppKit
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D8: what Quick Look may preview, the Space bar rule, and what a drag out of the chat carries. The panel itself
/// is never opened here; files are temp files under a fake home.
final class QuickLookTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) throws -> URL {
        let url = home.appendingPathComponent("out").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func resolve(_ ref: MediaRef) -> MediaResolution {
        MediaResolver.resolve(ref, userInitiated: true, home: home)
    }

    func testOnlyCheckedFilesThatOpenArePreviewed() {
        let pdf = URL(fileURLWithPath: "/x/report.pdf"), page = URL(fileURLWithPath: "/x/page.html")
        XCTAssertEqual(QuickLookPolicy.canPreview(.available(url: pdf, size: 1, modified: .distantPast)), pdf)
        XCTAssertNil(QuickLookPolicy.canPreview(.available(url: page, size: 1, modified: .distantPast)),
                     "reveal-only formats are not previewed either")
        XCTAssertNil(QuickLookPolicy.canPreview(.deferred), "not checked yet")
        XCTAssertNil(QuickLookPolicy.canPreview(.unavailable(reason: "gone")))
        XCTAssertNil(QuickLookPolicy.canPreview(nil))
    }

    /// One menu for Bot Chat files and room attachments; a reveal-only file offered "Reveal in Finder" twice.
    func testContextMenuIsOneListWithoutDuplicates() {
        let pdf = URL(fileURLWithPath: "/tmp/r.pdf"), page = URL(fileURLWithPath: "/tmp/p.html")
        XCTAssertEqual(MediaContextMenu.items(.available(url: pdf, size: 1, modified: .distantPast)),
                       [.quickLook, .open, .reveal, .copyPath])
        XCTAssertEqual(MediaContextMenu.items(.available(url: page, size: 1, modified: .distantPast)), [.reveal, .copyPath],
                       "reveal-only: one Reveal in Finder, no Quick Look or Open")
        for other: MediaResolution? in [.deferred, .unavailable(reason: "gone"), nil] {
            XCTAssertEqual(MediaContextMenu.items(other), [.copyPath])
        }
        for resolution: MediaResolution in [.available(url: pdf, size: 1, modified: .distantPast),
                                            .available(url: page, size: 1, modified: .distantPast)] {
            let titles = MediaContextMenu.items(resolution).map(MediaContextMenu.title)
            XCTAssertEqual(Set(titles).count, titles.count, "no duplicate entries: \(titles)")
        }
    }

    /// Room attachments use the shared panel (hover + Space), not SwiftUI's own `.quickLookPreview`.
    func testRoomAttachmentsUseTheSharedQuickLookController() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/HermesBotApp/RoomAttachmentViews.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".quickLookPreview("))
        XCTAssertTrue(source.contains("QuickLookController.shared.hover("))
        XCTAssertTrue(source.contains("QuickLookController.shared.show("))
    }

    func testSpaceBarRule() {
        let space = QuickLookPolicy.spaceKeyCode
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: [], hovering: true, panelVisible: false, editingText: false), .open)
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: [], hovering: true, panelVisible: false, editingText: true), .none,
                       "typing a space in the composer never previews")
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: [], hovering: false, panelVisible: false, editingText: false), .none)
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: [], hovering: false, panelVisible: true, editingText: true), .close)
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: .command, hovering: true, panelVisible: false, editingText: false), .none)
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: 0, modifiers: [], hovering: true, panelVisible: false, editingText: false), .none)
        XCTAssertEqual(QuickLookPolicy.keyAction(keyCode: space, modifiers: .capsLock, hovering: true, panelVisible: false, editingText: false), .open,
                       "Caps Lock is not a modifier for this")
    }

    func testDragCarriesOnlyAFileThatPassesTheCheckNow() throws {
        let url = try file("data.csv")
        let ref = MediaRef(path: url.path, kind: .file)
        XCTAssertEqual(MediaDrag.url(for: ref, resolve: resolve)?.standardizedFileURL.path,
                       url.resolvingSymlinksInPath().standardizedFileURL.path)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(MediaDrag.url(for: ref, resolve: resolve), "re-checked at drag time: a deleted file drags nothing")
        XCTAssertNil(MediaDrag.url(for: MediaRef(path: "/Volumes/share/a.csv", kind: .file), resolve: resolve),
                     "network and refused paths never drag")
        XCTAssertNil(MediaDrag.url(for: ref, resolve: { _ in .deferred }))
    }

    func testDragProviderCarriesTheFileURL() async throws {
        let url = try file("notes.txt")
        let ref = MediaRef(path: url.path, kind: .file)
        guard let checked = MediaDrag.url(for: ref, resolve: resolve), let provider = NSItemProvider(contentsOf: checked) else {
            return XCTFail("a checked file makes a provider")
        }
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
    }
}
