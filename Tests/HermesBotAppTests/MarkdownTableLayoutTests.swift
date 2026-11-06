import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp

/// A table with wrapping cells drew taller than it reported (Grid measured cells at other widths than it
/// placed them at), so the next timeline row overlapped the end of the message. The table now reports exactly
/// the height it draws.
@MainActor
final class MarkdownTableLayoutTests: XCTestCase {
    private static let md = """
    | SHA | Isi |
    | --- | --- |
    | `4622353` | `fix: run Quit cleanup on Ctrl+C (SIGINT)`: perubahan di `HermesBotApp.swift`, runner dan fixture regresi, lifecycle di `docs/development.md`, serta langkah Quit di README |
    | `70aef01` | `docs: contributing guide, security policy, issue templates, screenshots` |
    """

    func testColumnWidths() {
        XCTAssertEqual(MarkdownTableLayout.widths(ideal: [60, 200], available: 720), [60, 200], "fits: content widths")
        XCTAssertEqual(MarkdownTableLayout.widths(ideal: [60, 2000], available: 720), [60, 660], "narrow column kept, wide one gets the rest")
        XCTAssertEqual(MarkdownTableLayout.widths(ideal: [900, 900], available: 600), [300, 300])
        XCTAssertEqual(MarkdownTableLayout.widths(ideal: [100, 900, 300], available: 700).reduce(0, +), 700, accuracy: 2)
        XCTAssertEqual(MarkdownTableLayout.widths(ideal: [10, 20], available: nil), [10, 20])
    }

    func testReportedHeightIsTheDrawnHeight() throws {
        let blocks = MarkdownBlock.parse(Self.md)
        guard case .table = blocks.first else { return XCTFail("\(blocks)") }
        for width: CGFloat in [420, 720] {
            let measure = NSHostingView(rootView: MarkdownView(blocks: blocks).frame(width: width))
            measure.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
            measure.layoutSubtreeIfNeeded()
            let reported = measure.fittingSize.height

            // Drawn top-aligned in a much taller red frame: the last non-red pixel row is where the table ends.
            let tall: CGFloat = 1200
            let host = NSHostingView(rootView: MarkdownView(blocks: blocks).frame(width: width)
                .frame(width: width, height: tall, alignment: .top).background(Color(red: 1, green: 0, blue: 0))
                .environment(\.colorScheme, .light))
            host.frame = NSRect(x: 0, y: 0, width: width, height: tall)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsHigh) / tall
            var lastContentRow = 0
            for y in 0..<rep.pixelsHigh {
                let c = rep.colorAt(x: Int(width * scale / 2), y: y)
                let red = (c?.redComponent ?? 0) > 0.9 && (c?.greenComponent ?? 1) < 0.1 && (c?.blueComponent ?? 1) < 0.1
                if !red { lastContentRow = y }
            }
            let drawn = CGFloat(lastContentRow + 1) / scale
            XCTAssertEqual(drawn, reported, accuracy: 2, "width \(width): drawn \(drawn) vs reported \(reported)")
        }
    }
}
