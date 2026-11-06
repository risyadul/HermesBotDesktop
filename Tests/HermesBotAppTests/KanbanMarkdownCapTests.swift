import XCTest
@testable import HermesBotApp

/// Inspector markdown is capped before parsing (an unbounded description must not be laid out whole).
final class KanbanMarkdownCapTests: XCTestCase {
    func testShortTextIsUnchanged() {
        XCTAssertEqual(KanbanMarkdown.capped("**hi**"), "**hi**")
        let exact = String(repeating: "a", count: KanbanMarkdown.maxCharacters)
        XCTAssertEqual(KanbanMarkdown.capped(exact), exact)
    }

    func testLongTextIsTruncatedWithANote() {
        let long = String(repeating: "b", count: KanbanMarkdown.maxCharacters + 10)
        let capped = KanbanMarkdown.capped(long)
        XCTAssertTrue(capped.hasPrefix(String(repeating: "b", count: KanbanMarkdown.maxCharacters)))
        XCTAssertTrue(capped.hasSuffix(KanbanMarkdown.truncationNote))
        XCTAssertEqual(capped.count, KanbanMarkdown.maxCharacters + 2 + KanbanMarkdown.truncationNote.count)
        XCTAssertFalse(KanbanMarkdown.blocks(long).isEmpty)
    }
}
