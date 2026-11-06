import AppKit
import XCTest
@testable import HermesBotApp

/// The last-window decision: with the menu bar extra shown the app keeps running after its last window
/// closes, and a reopen (Dock, menu bar) brings a main window back. Pure policy plus the delegate over a
/// defaults suite; no window is opened.
@MainActor
final class WindowLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "hba-window-lifecycle-tests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testTheAppStaysRunningWhileTheMenuBarExtraShows() {
        XCTAssertFalse(WindowLifecyclePolicy.terminatesAfterLastWindowClosed(menuBarExtraShown: true))
        XCTAssertTrue(WindowLifecyclePolicy.terminatesAfterLastWindowClosed(menuBarExtraShown: false))

        let delegate = AppDelegate()
        delegate.defaults = defaults
        XCTAssertTrue(WindowLifecyclePolicy.menuBarExtraShown(defaults), "the extra is on by default")
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                       "default (extra shown): closing the last window keeps the app running")
        defaults.set(false, forKey: MenuBarScene.settingKey)
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                      "extra hidden: nothing would be left on screen, so the app quits")
    }

    func testReopenBringsAMainWindowBack() {
        XCTAssertEqual(WindowLifecyclePolicy.reopen(hasVisibleWindows: true, hasMainWindow: true, canOpenNew: true), .systemDefault)
        XCTAssertEqual(WindowLifecyclePolicy.reopen(hasVisibleWindows: false, hasMainWindow: true, canOpenNew: true), .frontExisting,
                       "minimised or hidden: restore it rather than open a second one")
        XCTAssertEqual(WindowLifecyclePolicy.reopen(hasVisibleWindows: false, hasMainWindow: false, canOpenNew: true), .openNew,
                       "the last window was closed: open a new one")
        XCTAssertEqual(WindowLifecyclePolicy.reopen(hasVisibleWindows: false, hasMainWindow: false, canOpenNew: false), .systemDefault,
                       "no opener captured yet: leave it to SwiftUI")
    }
}
