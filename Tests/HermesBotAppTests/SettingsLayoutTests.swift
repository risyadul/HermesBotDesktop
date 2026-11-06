import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Live UI test 2026-11-06: the Settings window opened 420 × 452 and the "Kanban dispatcher" section sat
/// below the fold. The form now reports its full content height, which is what the Settings window sizes
/// to. Headless: the real form measured in an NSHostingView, its models pointed at an empty temp home (no
/// LaunchAgent, no `hermes`, nothing is installed or started).
@MainActor
final class SettingsLayoutTests: XCTestCase {
    private var home: URL!
    private var suite = ""

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hba-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("locks"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        suite = "hba-settings-test-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func form(maxHeight: CGFloat? = nil) -> SettingsForm {
        let host = BackgroundServeHost(ownsSpawnedBackend: { false }, attachedServePID: { nil },
                                       stopOwnedBackend: {}, reconnect: { _ in })
        let background = BackgroundServeSettingsModel(control: BackgroundServe(home: home, environment: [:]), host: host,
                                                      defaults: UserDefaults(suiteName: suite)!)
        let dispatcher = DispatcherStatusModel(control: GatewayStatus(lockDir: home.appendingPathComponent("locks"), home: home,
                                                                      environment: [:]))
        var form = SettingsForm(background: background, dispatcher: dispatcher)
        if let maxHeight { form.maxHeight = maxHeight }
        return form
    }

    func testTheFormIsCappedAtTheScreenAndScrollsPastIt() {
        XCTAssertEqual(SettingsLayout.maxContentHeight(visibleHeight: 800), 800 - SettingsLayout.titleBar)
        XCTAssertEqual(SettingsLayout.maxContentHeight(visibleHeight: nil), .infinity)
        XCTAssertFalse(SettingsLayout.scrolls(height: 600, limit: 900), "fits: no scrolling, no rubber band")
        XCTAssertTrue(SettingsLayout.scrolls(height: 500, limit: 500), "capped: the rest scrolls")
        XCTAssertFalse(SettingsLayout.scrolls(height: 600, limit: .infinity))
    }

    /// A screen shorter than the form (a small display, a larger text size): the window stops at the screen
    /// and the form scrolls instead of running off the bottom with scrolling turned off.
    func testOnAShortScreenTheWindowStopsThereAndTheFormScrolls() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let controller = NSHostingController(rootView: form(maxHeight: 360))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let content = try XCTUnwrap(window.contentView)
        XCTAssertLessThanOrEqual(content.frame.height, 360.5, "the window stops at the screen's height")
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let scroll = try XCTUnwrap(views(content).compactMap { $0 as? NSScrollView }.max { $0.frame.height < $1.frame.height })
        let visible = scroll.contentView.bounds.height, document = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(document, visible + 50, "the rest of the form is below, reachable by scrolling")
        let before = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: before + 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, before, "it scrolls")
    }

    /// Opens a window: the grouped form lays its rows out lazily, so only a real window measures them all.
    func testSettingsWindowShowsEverySectionWithoutScrolling() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        // The Settings scene sizes its window to the content's preferred size. A screen taller than the form
        // (the cap is tested on its own below): the form must show whole, not in a viewport.
        let controller = NSHostingController(rootView: form(maxHeight: .infinity))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.width, DS.Size.settingsWidth, accuracy: 0.5)
        // It opened at 420 pt of content and cut the third section off; the three grouped sections with their
        // footnotes need well over that.
        XCTAssertGreaterThan(content.frame.height, 560, "window sized to a viewport, not to the content")
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let scrolls = views(content).compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrolls.isEmpty, "the grouped form is a scroll view")
        for scroll in scrolls {
            let visible = scroll.contentView.bounds.height, document = scroll.documentView?.frame.height ?? 0
            XCTAssertLessThanOrEqual(document, visible + 0.5, "content \(document) pt runs below the fold at \(visible) pt")
        }
    }
}
