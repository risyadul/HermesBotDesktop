import AppKit
import HermesGatewayKit
import SwiftUI
import XCTest
@testable import HermesBotApp

/// Live UI test 2026-11-06: in the Room Activity panel (inspector, at most 260 pt) tool titles were cut to
/// "Ran python3 -c 'i…" and the turn divider to "Turn finished ·…". Tool titles there now wrap to two
/// lines with the duration kept beside them, and the divider label never shrinks. Headless: views measured
/// in an NSHostingController.
@MainActor
final class ActivityPanelLayoutTests: XCTestCase {
    /// The panel's content width at the inspector maximum, less its 16 pt side padding.
    private static let panelContent = DS.Size.inspectorMax - 2 * DS.Space.s4

    private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2000))
    }

    func testTurnLabelKeepsItsDuration() {
        XCTAssertEqual(ActivityTurnDivider.label(finished: true, duration: "4.2s"), "Turn finished · 4.2s")
        XCTAssertEqual(ActivityTurnDivider.label(finished: true, duration: nil), "Turn finished")
        XCTAssertEqual(ActivityTurnDivider.label(finished: false, duration: "1s"), "Turn started")

        let label = Text("Turn finished · 1m 37s").font(DS.Typeface.caption).fixedSize()
        let full = size(label, width: 2000).width
        let divider = ActivityTurnDivider(title: nil, finished: true, duration: "1m 37s")
        // Squeezed far below its text: the divider still takes the whole label (the rules give way instead).
        XCTAssertGreaterThanOrEqual(size(divider, width: 60).width, full + DS.Space.s3 + DS.Space.s2,
                                    "the label was compressed (truncated)")
    }

    func testToolTitleWrapsToTwoLinesInThePanel() {
        let long = ChatLine(role: .tool, text: "", tool: ToolLine(
            toolId: "t1", name: "terminal", state: .done, duration: 0.2,
            args: ["command": "python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[\"items\"])' data.json"]))
        let short = ChatLine(role: .tool, text: "", tool: ToolLine(
            toolId: "t2", name: "terminal", state: .done, duration: 0.2, args: ["command": "ls"]))
        func height(_ line: ChatLine, lines: Int) -> CGFloat {
            size(ToolActivityRow(line: line, titleLines: lines).environmentObject(DisclosureStore()), width: Self.panelContent).height
        }
        let oneLine = height(short, lines: ActivityTurnDivider.toolTitleLines)
        XCTAssertGreaterThan(height(long, lines: ActivityTurnDivider.toolTitleLines), oneLine + 8,
                             "a long command wraps to a second line in the panel")
        XCTAssertEqual(height(long, lines: 1), oneLine, accuracy: 0.5, "Bot Chat keeps one line")
    }
}
