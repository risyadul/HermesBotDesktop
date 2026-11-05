import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Bot Chat opened on a new chat (no messages yet) left the sidebar and the inspector blank and the
/// composer unreachable. The empty-chat description used `.fixedSize(horizontal: false, vertical: true)`
/// outside any scroll view: when the split view measured the pane at a near-zero width, that text
/// reported its height at one glyph per line (≈5,900 pt for a profile description), the split view
/// items took that height while the window stayed 720 pt, and AppKit centred the overflow: the sidebar
/// rows and the inspector sat ~2,400 pt above the window and the composer ~2,600 pt below it.
///
/// These tests host the real `BotChatView` in a native split view on a real window (as `RootView` does)
/// and assert that the split columns fit the window and the composer field is on screen.
@MainActor
final class BotChatLayoutTests: XCTestCase {
    private static let longDescription = String(repeating: "Explorer and tester across platforms; runtime checks, bug repro and edge-case probes. ", count: 4)

    private struct Host: View {
        let chat: ChatModel
        var body: some View {
            NavigationSplitView {
                List { Text("hba-layout sidebar row") }
                    .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarWidth, max: DS.Size.sidebarMax)
            } detail: {
                BotChatView(chat: chat, backend: nil)
                    .frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: DS.Size.windowMinWidth, minHeight: DS.Size.windowMinHeight)
        }
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    private func check(size: NSSize, description: String?, inspector: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let key = "hba.botInspector"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(inspector, forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }

        var json: [String: JSONValue] = ["name": "hba-layout", "model": "test-model"]
        if let description { json["description"] = .string(description) }
        let bot = try XCTUnwrap(Bot(.object(json)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(chat: ChatModel(bot: bot)))
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.8)

        let content = try XCTUnwrap(window.contentView)
        let height = content.bounds.height
        let views = all(content)
        let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first, "no NSSplitView in the window", file: file, line: line)
        for (i, column) in split.arrangedSubviews.enumerated() where !column.isHidden {
            XCTAssertLessThanOrEqual(column.frame.height, height + 1,
                                     "split column \(i) is \(column.frame.height) pt tall in a \(height) pt window (\(size), inspector \(inspector))",
                                     file: file, line: line)
        }
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable },
                                  "no editable composer field", file: file, line: line)
        let frame = field.convert(field.bounds, to: nil)
        XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                      "composer field \(frame) is outside the window content \(content.bounds) (\(size), inspector \(inspector))",
                      file: file, line: line)
    }

    func testNewChatWithDescriptionFitsDefaultWindow() throws {
        try check(size: DS.Size.windowDefault, description: Self.longDescription, inspector: true)
    }

    func testNewChatWithDescriptionFitsMinimumWindowInspectorShown() throws {
        try check(size: NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight),
                  description: Self.longDescription, inspector: true)
    }

    func testNewChatWithDescriptionFitsMinimumWindowInspectorHidden() throws {
        try check(size: NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight),
                  description: Self.longDescription, inspector: false)
    }

    func testNewChatWithoutDescriptionFitsDefaultWindow() throws {
        try check(size: DS.Size.windowDefault, description: nil, inspector: true)
    }
}
