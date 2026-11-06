import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Live UI test 2026-11-06 (round 5): the room toolbar's Summarize button did not open its sheet, the same
/// fault as Routines in round 2. A `motionSheet` (or any sheet, popover, alert or dialog) anchored inside
/// ToolbarItem content is not in the window's view hierarchy and never presents. The button now only sets
/// `RoomModel.catchUp` and `RoomView` presents the sheet from the pane.
///
/// The audit is a source check: every toolbar block in the app, and every app view a toolbar block builds
/// (followed through the views those build), carries no presentation modifier. A toolbar is not rendered
/// headless; the window test (opt-in, `WindowTestGate`) proves the pane really attaches the Summarize sheet.
@MainActor
final class ToolbarPresentationTests: XCTestCase {
    static let presenters = [".sheet(", ".motionSheet(", ".popover(", ".alert(", ".confirmationDialog(",
                             ".fileImporter(", ".fileExporter("]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HermesBotApp")
    }

    private static func sources() throws -> [(name: String, text: String)] {
        let files = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The text between the brace at or after `start` and its match.
    private static func block(_ text: String, from start: String.Index) -> Substring? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 } else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return text[open...i] }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Every `.toolbar { … }` and `@ToolbarContentBuilder` body, by file.
    private static func toolbarBlocks(_ files: [(name: String, text: String)]) -> [(String, Substring)] {
        files.flatMap { file in
            [".toolbar {", "@ToolbarContentBuilder"].flatMap { marker in
                file.text.ranges(of: marker).compactMap { r in block(file.text, from: r.lowerBound).map { (file.name, $0) } }
            }
        }
    }

    func testNoToolbarItemPresentsASheetPopoverOrAlertFromInside() throws {
        let files = try Self.sources()
        // App views by name: `struct Name: View {…}` (and `ViewModifier`), so a toolbar block's components are
        // followed into their bodies.
        var views: [String: Substring] = [:]
        for file in files {
            for match in file.text.matches(of: /struct (\w+)(?:<[^>]*>)?: View \{/) {
                if let body = Self.block(file.text, from: match.range.lowerBound) { views[String(match.output.1)] = body }
            }
        }
        let blocks = Self.toolbarBlocks(files)
        XCTAssertGreaterThanOrEqual(blocks.count, 3, "the Room, Bot Chat and board toolbars")
        for (file, block) in blocks {
            var queue = [("toolbar in \(file)", block)], seen = Set<String>()
            while let (what, text) = queue.popLast() {
                for marker in Self.presenters {
                    XCTAssertFalse(text.contains(marker), "\(what) attaches \(marker)…): present it from the pane instead")
                }
                for match in text.matches(of: /\b([A-Z]\w+)\(/) {
                    let name = String(match.output.1)
                    if let body = views[name], seen.insert(name).inserted { queue.append(("\(name) (in \(what))", body)) }
                }
            }
        }
    }

    func testTheSummarizeButtonOpensTheSheetFromTheRoomModel() {
        let f = QuickSendFixture()
        let model = RoomModel(room: RoomFixtures.room(), api: f.rooms)
        defer { model.shutdown() }
        XCTAssertNil(model.catchUp, "closed until the button is pressed")
        model.showCatchUp(after: 0, sender: { f.sender })
        XCTAssertNotNil(model.catchUp, "the button sets the state the pane presents from")
        model.catchUp = nil  // the sheet's Close (`onClose`)
        XCTAssertNil(model.catchUp)
    }

    func testTheRoomPaneAttachesTheSummarizeSheetToItsWindow() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let f = QuickSendFixture()
        let model = RoomModel(room: RoomFixtures.room(), api: f.rooms)
        let size = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RoomView(model: model).environment(\.motionEnabled, false))
        window.orderFrontRegardless()
        defer {
            model.catchUp = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.contentViewController = nil
            window.orderOut(nil)
            model.shutdown()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(window.attachedSheet)

        model.showCatchUp(after: 0, sender: { f.sender })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let sheet = try XCTUnwrap(window.attachedSheet, "the Summarize sheet is attached to the room's window")
        XCTAssertEqual(sheet.frame.width, DS.Size.sheetWidth, accuracy: 1)

        model.catchUp = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(window.attachedSheet, "Close closes it")
    }
}
