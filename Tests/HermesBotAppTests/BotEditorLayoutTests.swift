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
