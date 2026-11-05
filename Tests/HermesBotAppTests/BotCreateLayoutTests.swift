import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// New Bot and the Edit sheet's avatar picker, Find Skills and MCP setup on a real window: every tab and form stays
/// inside the sheet width and the 520 pt window minimum. Opt-in (`WindowTestGate`); a fake service, no backend.
@MainActor
final class BotCreateLayoutTests: XCTestCase {
    typealias FakeService = BotManagementTests.FakeService
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

    private func assertFits(_ size: NSSize, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(size.width, DS.Size.sheetWidth + 0.5, "\(what): \(size)", file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, DS.Size.windowMinHeight, "\(what): \(size)", file: file, line: line)
    }

    func testNewBotSheetFitsWithEveryAvatarTabAndAdvancedOpen() async throws {
        let s = FakeService()
        s.providers = [.init(slug: "openrouter", name: "OpenRouter with a long display name", models: [String(repeating: "m", count: 80)])]
        s.gallery = .success((0..<60).map { .init(slug: "pet-with-a-long-name-\($0)", displayName: "A pet with a long name \($0)") })
        let roster = (0..<30).map { Bot(["name": .string("profile-with-a-long-name-\($0)")])! }
        let m = BotCreateModel(roster: roster, service: s)
        m.name = String(repeating: "Very long bot name ", count: 6)
        m.toggleAdvanced()
        m.toggleAvatarPicker()
        for tab in BotAvatarPickerModel.Tab.allCases {
            m.picker.tab = tab
            try await Task.sleep(nanoseconds: 50_000_000)
            assertFits(host(BotCreateView(model: m)), "New Bot, \(tab.rawValue) tab")
        }
    }

    func testEditSheetWithAvatarPickerSkillsFinderAndMcpFormFits() async throws {
        let s = FakeService()
        s.snapshot = .init(skills: [.init(name: "web", enabled: true)],
                           mcpServers: [.init(name: "a-very-long-mcp-server-name-for-layout", enabled: true, detail: "http")])
        s.mcpList = .success([.init(name: "a-very-long-mcp-server-name-for-layout", transport: "http", url: "https://x", auth: "oauth")])
        s.skillResults = .success((0..<10).map { .init(name: "owner/a-very-long-skill-name-\($0)", description: String(repeating: "Does things. ", count: 10)) })
        let m = BotEditorModel(bot: Bot(["name": "hba-layout"])!, service: s, hadAvatar: false)
        m.toggleAvatarPicker()
        m.toggleAdvanced()
        let end = Date().addingTimeInterval(5)
        while (m.advancedPhase != .loaded || m.mcp.phase != .loaded) && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        m.skillsFinderOpen = true
        m.skillsFinder.query = "pdf"
        await m.skillsFinder.search()
        m.mcp.toggleAdd()
        m.mcp.openKey("a-very-long-mcp-server-name-for-layout")
        let identity = BotIdentity(profile: "hba-layout", title: "hba-layout", slot: 0)
        assertFits(host(BotEditorView(model: m, identity: identity)), "Edit with everything open")
    }
}
