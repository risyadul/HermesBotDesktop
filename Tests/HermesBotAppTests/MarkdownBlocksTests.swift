import XCTest
@testable import HermesBotApp

/// Block markdown in bot replies (headings, GFM tables, lists, quotes, code, rules), parsed the way Hermes
/// Desktop renders them instead of showing the raw `###` / `| --- |` source.
final class MarkdownBlocksTests: XCTestCase {
    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    func testHeadingParagraphAndTable() throws {
        let md = """
        Selesai. **ok**

        ### Tiket yang dibuat

        | Tiket | Judul | SP |
        | --- | :---: | ---: |
        | [CUST-6563](https://x.atlassian.net/browse/CUST-6563) | `[ANDROID] keep` | **2.5** (total) |
        | CUST-6564 |
        """
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 3)
        guard case .paragraph(let p) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(plain(p), "Selesai. ok")
        guard case .heading(3, let h) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(plain(h), "Tiket yang dibuat")
        guard case .table(let t) = blocks[2] else { return XCTFail("\(blocks[2])") }
        XCTAssertEqual(t.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(t.header.map(plain), ["Tiket", "Judul", "SP"])
        XCTAssertEqual(t.rows.map { $0.map(plain) }, [["CUST-6563", "[ANDROID] keep", "2.5 (total)"], ["CUST-6564", "", ""]],
                       "a short row is padded to the column count")
        let link = t.rows[0][0].runs.first?.link
        XCTAssertEqual(link?.absoluteString, "https://x.atlassian.net/browse/CUST-6563", "inline links survive in cells")
    }

    func testListsQuoteCodeAndRule() throws {
        let md = """
        - a item
          - nested
        3. three
        4. four

        > quoted

        ```swift
        let x = 1
        ```
        ---
        """
        let blocks = MarkdownBlock.parse(md)
        guard blocks.count == 5 else { return XCTFail("\(blocks)") }
        guard case .list(false, _, let items) = blocks[0], items.count == 1 else { return XCTFail("\(blocks[0])") }
        guard case .paragraph(let first) = items[0][0], case .list(false, _, let nested) = items[0][1] else {
            return XCTFail("\(items[0])")
        }
        XCTAssertEqual(plain(first), "a item")
        XCTAssertEqual(nested.count, 1)
        guard case .list(true, 3, let ordered) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(ordered.count, 2)
        guard case .quote(let q) = blocks[2], case .paragraph(let qp) = q.first else { return XCTFail("\(blocks[2])") }
        XCTAssertEqual(plain(qp), "quoted")
        XCTAssertEqual(blocks[3], .code(language: "swift", "let x = 1"))
        XCTAssertEqual(blocks[4], .rule)
    }

    func testSoftBreaksStayLineBreaksAndBareUrlsLink() {
        let blocks = MarkdownBlock.parse("• a\n• b see https://example.com")
        guard case .paragraph(let p) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(plain(p), "• a\n• b see https://example.com")
        XCTAssertTrue(p.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    func testUnfinishedMarkupAndHtmlAreKeptAsText() {
        XCTAssertEqual(MarkdownBlock.parse("**unclosed and `code").map { block -> String in
            if case .paragraph(let p) = block { return plain(p) }
            return "\(block)"
        }, ["**unclosed and `code"])
        guard case .paragraph(let p) = MarkdownBlock.parse("a <br> b").first else { return XCTFail() }
        XCTAssertEqual(plain(p), "a <br> b", "raw HTML is shown as text, never interpreted")
        XCTAssertEqual(MarkdownBlock.parse(""), [])
    }

    func testHtmlBlocksAndDefinitionsKeepTheirText() {
        // Foundation's parser drops these silently; "Outro" used to vanish with the <details> block.
        let text = MarkdownBlock.parse("Intro\n<details>\n<summary>More</summary>\nhidden text\n</details>\nOutro")
            .map(\.plainText).joined(separator: "\n")
        for part in ["Intro", "<details>", "<summary>More</summary>", "hidden text", "</details>", "Outro"] {
            XCTAssertTrue(text.contains(part), "\(part) in \(text)")
        }
        let div = MarkdownBlock.parse("Use this:\n\n<div class=x>\n  hello\n</div>\n\nThat's it").map(\.plainText).joined(separator: "\n")
        XCTAssertTrue(div.contains("<div class=x>") && div.contains("hello") && div.contains("That's it"), div)
        let refs = MarkdownBlock.parse("See [^1].\n\n[^1]: the note\n[docs]: https://example.com").map(\.plainText).joined()
        XCTAssertTrue(refs.contains("the note") && refs.contains("https://example.com"), refs)
        XCTAssertEqual(MarkdownBlock.parse("```xml\n<a>\n[x]: y\n```"), [.code(language: "xml", "<a>\n[x]: y")],
                       "fenced code is untouched")
        XCTAssertEqual(MarkdownBlock.parse("```\nx\n\n\n```"), [.code(language: nil, "x")], "no trailing blank lines")
    }

    func testEscapingNeverLeaksBackslashesIntoCodeAndHandlesCrlfAndAutolinks() {
        XCTAssertEqual(MarkdownBlock.parse("1. ```html\n   <div>\n   ```").flatMap(codes), ["<div>"], "fence in a list item")
        XCTAssertEqual(MarkdownBlock.parse("- ```xml\n  <a/>\n  ```").flatMap(codes), ["<a/>"])
        XCTAssertEqual(MarkdownBlock.parse("````md\n```\n<div>\n[x]: y\n```\n````").flatMap(codes), ["```\n<div>\n[x]: y\n```"],
                       "a shorter inner fence does not close the outer one")
        let listHtml = MarkdownBlock.parse("- <div>\n  item text\n  </div>\n- next").map(\.plainText).joined(separator: "\n")
        XCTAssertFalse(listHtml.contains("\\"), listHtml)
        XCTAssertTrue(listHtml.contains("</div>") && listHtml.contains("item text"), listHtml)
        let crlf = MarkdownBlock.parse("Use:\r\n\r\n<div>\r\nhello\r\n</div>\r\n\r\nend").map(\.plainText).joined(separator: "\n")
        XCTAssertTrue(crlf.contains("hello") && crlf.contains("<div>") && crlf.contains("end"), crlf)
        guard case .paragraph(let auto)? = MarkdownBlock.parse("<https://example.com>\nis the site").first else { return XCTFail() }
        XCTAssertTrue(auto.runs.contains { $0.link?.absoluteString == "https://example.com" }, "a line-leading autolink still links")
        guard case .quote(let q)? = MarkdownBlock.parse("> <div>\n> quoted\n> </div>").first else { return XCTFail() }
        XCTAssertFalse(q.map(\.plainText).joined().hasSuffix("\n"), "no trailing newline in a quoted paragraph")
    }

    private func codes(_ block: MarkdownBlock) -> [String] {
        switch block {
        case .code(_, let s): return [s]
        case .list(_, _, let items): return items.flatMap { $0.flatMap(codes) }
        case .quote(let inner): return inner.flatMap(codes)
        default: return []
        }
    }

    func testHalfStreamedTableIsAParagraphUntilItsDelimiterRowArrives() {
        guard case .paragraph = MarkdownBlock.parse("| a | b |").first else { return XCTFail() }
        guard case .table = MarkdownBlock.parse("| a | b |\n| - | - |").first else { return XCTFail() }
    }
}
