import SwiftUI
import XCTest
@testable import HermesBotApp

/// Clickable text reads as clickable: links blue and underlined (bot markdown and user bubbles), @mentions of
/// room members blue and semibold. The link blue keeps normal-text contrast in both themes.
@MainActor
final class LinkMentionStylingTests: XCTestCase {
    private func runs(_ a: AttributedString, _ needle: String) -> [AttributedString.Runs.Run] {
        let s = String(a.characters)
        guard let r = s.range(of: needle) else { return [] }
        let start = s.distance(from: s.startIndex, to: r.lowerBound)
        let lo = a.characters.index(a.startIndex, offsetBy: start)
        let hi = a.characters.index(lo, offsetBy: needle.count)
        return Array(a[lo..<hi].runs)
    }

    func testMarkdownLinksAreBlueAndUnderlined() {
        guard case .paragraph(let p)? = MarkdownBlock.parse("See [docs](https://example.com) and https://x.org now").first else {
            return XCTFail()
        }
        let styled = MarkdownView.styled(p)
        for needle in ["docs", "https://x.org"] {
            let r = runs(styled, needle)
            XCTAssertFalse(r.isEmpty, needle)
            XCTAssertTrue(r.allSatisfy { $0.underlineStyle == .single && $0.foregroundColor == DS.Palette.link }, needle)
        }
        XCTAssertTrue(runs(styled, "now").allSatisfy { $0.underlineStyle == nil }, "plain text is not underlined")
    }

    func testMentionsOfMembersAreBlueNotOthers() {
        guard case .paragraph(let p)? = MarkdownBlock.parse("@orchestrator please ask @nobody, mail a@orchestrator.io, `@orchestrator`").first else {
            return XCTFail()
        }
        let styled = MarkdownView.styled(p, mentions: ["orchestrator"])
        let colored = styled.runs.filter { $0.foregroundColor == DS.Palette.link }.map { String(styled[$0.range].characters) }
        XCTAssertEqual(colored, ["@orchestrator"], "not @nobody, not an email, not inside inline code")
        XCTAssertTrue(MarkdownView.styled(p).runs.allSatisfy { $0.foregroundColor == nil }, "Bot Chat: no handles, no mentions")
    }

    func testUserBubbleLinkifiesUrlsAndHighlightsMentions() {
        let a = UserBubble.mentions("@default check https://example.com/a?b=1 and file:///etc/passwd @all", handles: ["default"])
        XCTAssertEqual(runs(a, "https://example.com/a?b=1").first?.link?.absoluteString, "https://example.com/a?b=1")
        XCTAssertTrue(runs(a, "https://example.com/a?b=1").allSatisfy { $0.underlineStyle == .single })
        XCTAssertTrue(runs(a, "file:///etc/passwd").allSatisfy { $0.link == nil }, "only http(s) becomes a link")
        for m in ["@default", "@all"] {
            XCTAssertTrue(runs(a, m).allSatisfy { $0.foregroundColor == DS.Palette.link }, m)
        }
    }

    func testLinkBlueKeepsTextContrast() {
        func lum(_ hex: UInt32) -> Double {
            func c(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * c(hex >> 16 & 0xFF) + 0.7152 * c(hex >> 8 & 0xFF) + 0.0722 * c(hex & 0xFF)
        }
        func ratio(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        // window, surface (code/table), user bubble — light then dark
        for bg: UInt32 in [0xFFFFFF, 0xF7F6F3, 0xEEEEF0] { XCTAssertGreaterThanOrEqual(ratio(DS.Palette.linkLight, bg), 4.5, String(bg, radix: 16)) }
        for bg: UInt32 in [0x232326, 0x2A2A2E, 0x34343A] { XCTAssertGreaterThanOrEqual(ratio(DS.Palette.linkDark, bg), 4.5, String(bg, radix: 16)) }
    }
}
