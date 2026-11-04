import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A bounded discussion (`room.activity` status `bounded`, `gateway/hosted_room_discussion.py` decide())
/// is a per-message reply/round budget. The old divider read "Discussion ended · message limit reached",
/// which users took for an account quota or a full room. The copy now says what happened and what to do.
@MainActor
final class DiscussionLimitCopyTests: XCTestCase {
    private func activity(_ status: String, _ reason: String?) -> RoomEvent {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let reason { payload["reason_code"] = .string(reason) }
        return RoomEvent(seq: 1, eventId: "e1", kind: "room.activity", payload: .object(payload))
    }

    func testBoundedReasonsExplainTheNextStep() {
        XCTAssertEqual(RoomPresentation.dividerText(activity("bounded", "max_messages"), fallback: "x"),
                       "Reply limit reached for this discussion. Send a new message to continue.")
        XCTAssertEqual(RoomPresentation.dividerText(activity("bounded", "max_rounds"), fallback: "x"),
                       "Round limit reached for this discussion. Send a new message to continue.")
        XCTAssertEqual(RoomPresentation.dividerText(activity("bounded", nil), fallback: "x"),
                       "Limit reached for this discussion. Send a new message to continue.")
        XCTAssertEqual(RoomPresentation.dividerText(activity("settled", "silent_round"), fallback: "x"),
                       "Discussion settled", "the normal end keeps its short label")
    }

    func testCopyHasNoEmDash() {
        for reason in ["max_messages", "max_rounds", "other"] {
            XCTAssertFalse(RoomPresentation.dividerText(activity("bounded", reason), fallback: "x").contains("\u{2014}"))
        }
    }

    /// The longer label wraps inside the pane instead of widening the timeline.
    func testLongDividerFitsNarrowWidth() {
        let text = RoomPresentation.dividerText(activity("bounded", "max_messages"), fallback: "x")
        for width in [240.0, 320.0, 540.0] {
            let host = NSHostingView(rootView: RoundDivider(text: text).frame(width: width))
            let size = host.fittingSize
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "width \(width)")
            XCTAssertLessThan(size.height, 80, "bounded by lineLimit at width \(width)")
        }
        let tiny = NSHostingView(rootView: RoundDivider(text: text).frame(width: 4)).fittingSize
        XCTAssertLessThan(tiny.height, 80, "no one-glyph-per-line blow-up at a near-zero width")
    }
}
