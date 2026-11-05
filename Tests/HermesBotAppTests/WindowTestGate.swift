import Foundation
import XCTest

/// Tests that open real windows (they appear on screen and can take focus) are opt-in on a developer Mac:
/// a plain `swift test` stays headless. Run them before any UI change:
///
///     HERMES_BOT_APP_WINDOW_TESTS=1 swift test
///
/// CI (`CI=true`, set by GitHub Actions) has nobody at the screen, so window tests run there, except the
/// pixel-exact suites: they pin split-view widths, a 1120 pt window and sheet animation frames tuned to a
/// developer Mac, and hosted runners have a 1024 pt screen and an older macOS that settles differently.
enum WindowTestGate {
    static let optInKey = "HERMES_BOT_APP_WINDOW_TESTS"

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var onCI: Bool { env["CI"] == "true" }
    private static var optedIn: Bool { env[optInKey] == "1" }

    /// A test that opens a window: runs on CI or when opted in.
    static func requireWindows() throws {
        guard onCI || optedIn else {
            throw XCTSkip("opens a window: run with \(optInKey)=1")
        }
    }

    /// A window test that pins exact pixel geometry: local opt-in only.
    static func requirePixelExactWindows() throws {
        if onCI { throw XCTSkip("pixel-exact window test: run locally (CI runner screen size and macOS differ)") }
        guard optedIn else { throw XCTSkip("opens a window: run with \(optInKey)=1") }
    }
}
