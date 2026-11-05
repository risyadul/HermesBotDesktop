import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// The bot sheets on a real window: the Edit sheet with Advanced open (long skill, toolset and model names),
/// the Delete confirmation with a long profile path and the inspector's action row at its minimum width stay
/// inside the sheet width and the 520 pt window minimum. Opt-in (`WindowTestGate`); a fake service, no backend.
@MainActor
final class BotEditorLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host<V: View>(_ view: V) -> NSSize {
        let controller = NSHostingController(rootView: view.environment(\.motionEnabled, false))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.orderFrontRegardless()
        windows.append(window)
        spin(0.6)
        return controller.view.fittingSize
    }

    private func bot(_ name: String, path: String? = nil) -> Bot {
        var row: [String: JSONValue] = ["name": .string(name), "description": "Researches"]
        if let path { row["path"] = .string(path) }
        return Bot(.object(row))!
    }

    func testEditSheetWithAdvancedOpenFitsTheMinimumWindow() async throws {
        let s = BotManagementTests.FakeService()
        let long = String(repeating: "very-long-skill-name-", count: 4)
        s.snapshot = .init(soul: String(repeating: "A long SOUL line that wraps. ", count: 40), provider: "openrouter", model: "a/b",
                           skills: (0..<40).map { .init(name: "\(long)\($0)", enabled: $0 % 2 == 0) },
                           toolsets: (0..<12).map { .init(name: "toolset\($0)", enabled: true, label: "Toolset with a long label \($0)", toolCount: 12) },
                           mcpServers: [.init(name: "a-very-long-mcp-server-name-for-layout", enabled: true, detail: "http")])
        s.providers = [.init(slug: "openrouter", name: "OpenRouter with a long display name", models: ["a/b", String(repeating: "m", count: 80)])]
        let m = BotEditorModel(bot: bot("hba-layout"), service: s, hadAvatar: false)
        m.toggleAdvanced()
        let end = Date().addingTimeInterval(5)
        while (m.advancedPhase != .loaded || m.loadingModels) && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(m.advancedPhase, .loaded)
        let identity = BotIdentity(profile: "hba-layout", title: "hba-layout", slot: 0)
        let size = host(BotEditorView(model: m, identity: identity))
        XCTAssertLessThanOrEqual(size.width, DS.Size.sheetWidth + 0.5, "sheet width \(size)")
        XCTAssertLessThanOrEqual(size.height, DS.Size.windowMinHeight, "the Edit sheet must fit the 520 pt minimum window: \(size)")

        let closed = BotEditorModel(bot: bot("hba-layout"), service: s, hadAvatar: false)
        let basic = host(BotEditorView(model: closed, identity: identity))
        XCTAssertLessThanOrEqual(basic.width, DS.Size.sheetWidth + 0.5)
        XCTAssertLessThanOrEqual(basic.height, DS.Size.windowMinHeight)
    }

    /// Live UI test 2026-11-06 (round 2): with Advanced open the Edit sheet stayed 484 pt tall whatever the
    /// window, and the skills list, toolsets, MCP and SOUL were clipped and unreachable. The real `RootView` (no
    /// backend: empty lock dir, spawn off) in a 520 pt window presents the sheet; it must stay inside the window,
    /// keep Save on screen, give the skills list real height and scroll down to the SOUL.
    func testEditSheetWithAdvancedOpenScrollsInsideAMinimumHeightWindow() async throws {
        let saved = ["HERMES_BOT_APP_LOCK_DIR", "HERMES_BOT_APP_NO_SPAWN"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        let lockDir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-editor-locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        setenv("HERMES_BOT_APP_LOCK_DIR", lockDir.path, 1)
        setenv("HERMES_BOT_APP_NO_SPAWN", "1", 1)
        defer {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: lockDir)
        }

        let s = BotManagementTests.FakeService()
        s.snapshot = .init(soul: String(repeating: "A long SOUL line that wraps. ", count: 40), provider: "openrouter", model: "a/b",
                           skills: (0..<102).map { .init(name: "skill-\($0)", enabled: $0 % 3 == 0) },
                           toolsets: (0..<20).map { .init(name: "toolset\($0)", enabled: true, label: "Toolset \($0)", toolCount: 2) },
                           mcpServers: (0..<8).map { .init(name: "mcp-\($0)", enabled: true, detail: "http") })
        s.providers = [.init(slug: "openrouter", name: "OpenRouter", models: ["a/b"])]
        let app = AppModel()
        let bot = bot("hba-layout")
        app.bots = [bot]
        let size = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: app).environment(\.motionEnabled, false))
        window.setContentSize(size)
        window.orderFrontRegardless()
        windows.append(window)
        spin(0.6)

        app.presentEdit(bot, service: s)
        guard case .edit(let m)? = app.botSheet else { return XCTFail("no edit sheet") }
        m.toggleAdvanced()
        let end = Date().addingTimeInterval(5)
        while (m.advancedPhase != .loaded || m.loadingModels) && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(m.advancedPhase, .loaded)
        spin(0.8)

        let sheet = try XCTUnwrap(window.attachedSheet, "the Edit sheet is attached")
        defer { app.botSheet = nil; spin(0.3) }
        let limit = BotEditorLayout.sheetMaxHeight(windowHeight: window.frame.height)
        XCTAssertLessThanOrEqual(sheet.frame.height, limit + 1, "sheet \(sheet.frame) vs window \(window.frame)")
        XCTAssertGreaterThan(sheet.frame.height, 300, "Advanced open uses the room the window has: \(sheet.frame)")

        // SwiftUI buttons are not NSViews: the sheet's scroll views carry the geometry. The body is the widest
        // one; the Cancel / Save row sits below it, inside the sheet.
        let content = try XCTUnwrap(sheet.contentView)
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        XCTAssertLessThanOrEqual(content.fittingSize.height, content.bounds.height + 1, "nothing is cut off below the fold")
        let scrolls = views(content).compactMap { $0 as? NSScrollView }
        let outer = try XCTUnwrap(scrolls.max { $0.frame.width < $1.frame.width }, "the scrolling body")
        let body = outer.convert(outer.bounds, to: nil)
        let footerRoom = DS.Space.s4 + DS.Size.controlHeight + DS.Space.s5
        XCTAssertGreaterThanOrEqual(body.minY, footerRoom - 1, "the Cancel / Save row fits below the body: \(body)")
        XCTAssertLessThanOrEqual(body.maxY, content.bounds.height, "the body stays inside the sheet")
        let document = try XCTUnwrap(outer.documentView)
        XCTAssertGreaterThan(document.frame.height, outer.contentView.bounds.height + 100, "the body scrolls")

        // The skills list (topmost list box) has its real height and holds its rows.
        let inner = scrolls.filter { $0 !== outer && $0.isDescendant(of: document) }
        XCTAssertGreaterThanOrEqual(inner.count, 3, "skills, toolsets and SOUL scroll inside the body")
        let byTop = inner.sorted { $0.convert($0.bounds, to: document).minY < $1.convert($1.bounds, to: document).minY }
        let topFirst = document.isFlipped ? byTop : byTop.reversed()
        let skills = try XCTUnwrap(topFirst.first)
        XCTAssertEqual(skills.frame.height, BotEditorLayout.listHeight, accuracy: 1, "skills list height")
        XCTAssertGreaterThan(skills.documentView?.frame.height ?? 0, BotEditorLayout.listHeight, "102 skill rows laid out")

        // Scrolled to the end, the SOUL editor (bottom-most) is inside the visible body; the footer did not move.
        let soul = try XCTUnwrap(topFirst.last)
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.frame.height : 0))
        spin(0.3)
        let visible = outer.contentView.documentVisibleRect
        XCTAssertTrue(visible.intersects(soul.convert(soul.bounds, to: document)), "SOUL reachable: \(visible)")
        XCTAssertEqual(outer.convert(outer.bounds, to: nil).minY, body.minY, accuracy: 0.5, "Cancel / Save stay pinned")
    }

    func testDeleteSheetWrapsALongProfilePath() {
        let path = "/Users/someone-with-a-long-name/.hermes/profiles/" + String(repeating: "a", count: 64)
        let m = BotDeleteModel(bot: bot("hba-layout", path: path), service: BotManagementTests.FakeService())
        let size = host(BotDeleteView(model: m))
        XCTAssertLessThanOrEqual(size.width, DS.Size.sheetWidth + 0.5, "\(size)")
        XCTAssertLessThanOrEqual(size.height, DS.Size.windowMinHeight)
    }

    func testInspectorActionsFitTheNarrowestInspector() {
        let size = host(BotInspector(bot: bot("hba-layout"), identity: BotIdentity(profile: "hba-layout", title: "hba-layout", slot: 0),
                                     app: AppModel())
            .frame(width: DS.Size.inspectorMin))
        XCTAssertLessThanOrEqual(size.width, DS.Size.inspectorMin + 0.5, "\(size)")
    }
}
