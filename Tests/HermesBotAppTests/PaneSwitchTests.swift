import SwiftUI
import XCTest
@testable import HermesBotApp

/// Switching quickly between group chats and a Bot Chat showed an older room under the new pane: the
/// selection changed inside a spring animation, and SwiftUI keeps every removed pane on screen (fully
/// opaque, `.identity` removal) until the animation settles. The switch is now never animated; the new
/// pane fades in on its own.
@MainActor
final class PaneSwitchTests: XCTestCase {
    func testSidebarSelectionIsNeverAnAnimatedTransaction() {
        let t = SidebarView.selectionTransaction
        XCTAssertTrue(t.disablesAnimations)
        XCTAssertNil(t.animation)
    }

    func testPaneArrivalStartsOffsetAndTransparentOnlyWithMotion() {
        XCTAssertEqual(PaneArrival.state(arrived: false, motion: true).opacity, PaneArrival.startOpacity)
        XCTAssertGreaterThan(PaneArrival.startOpacity, 0, "never a fully empty frame on a switch")
        XCTAssertEqual(PaneArrival.state(arrived: false, motion: true).offset, DS.Motion.paneOffset)
        XCTAssertEqual(PaneArrival.state(arrived: true, motion: true).opacity, 1)
        XCTAssertEqual(PaneArrival.state(arrived: false, motion: false).opacity, 1, "motion off: in place at once")
        XCTAssertEqual(PaneArrival.state(arrived: false, motion: false).offset, 0)
    }
}

/// Opening a room that has not synced yet showed "No messages yet" before its history arrived.
final class RoomEmptyStateTests: XCTestCase {
    func testUnsyncedRoomIsLoadingNotEmpty() {
        XCTAssertEqual(RoomView.emptyKind(synced: false, syncFailed: false), .loading)
        XCTAssertEqual(RoomView.emptyKind(synced: true, syncFailed: false), .empty)
        XCTAssertEqual(RoomView.emptyKind(synced: false, syncFailed: true), .empty, "a failed first sync stops the spinner")
    }
}
