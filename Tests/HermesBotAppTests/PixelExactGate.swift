import Foundation
import XCTest

/// Real-window suites that pin exact pixel geometry (split-view widths, a 1120pt window) and sheet
/// animation frames are tuned to a developer Mac's display and macOS version. Hosted CI runners have a
/// 1024pt-wide screen and an older macOS whose split view settles a few points differently, so these
/// suites skip there (`CI=true`, set by GitHub Actions). Run them locally before any UI change.
enum PixelExactGate {
    static func skipOnCI() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("pixel-exact window test: run locally (CI runner screen size and macOS differ)")
        }
    }
}
