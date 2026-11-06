import Foundation

/// Block structure of a markdown message (CommonMark + GFM tables), from Foundation's full markdown
/// parser (`AttributedString(markdown:)` with `.full` syntax): each run carries its block path as
/// `presentationIntent` components (innermost first, each with a stable identity), which is folded back
/// into a tree here. Inline styling (bold, italic, code, links, strikethrough) stays on the
/// `AttributedString` of each leaf block.
///
/// Parsing never fails a message: text the parser rejects, or a run without block intent, becomes a plain
/// paragraph, so no text is lost.
indirect enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(language: String?, String)
    /// Items in order; `start` is the first item's ordinal for ordered lists.
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule

    /// The block's text without markup (tests, accessibility).
    var plainText: String {
        switch self {
        case .paragraph(let a), .heading(_, let a): return String(a.characters)
        case .code(_, let s): return s
        case .list(_, _, let items): return items.map { $0.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .quote(let blocks): return blocks.map(\.plainText).joined(separator: "\n")
        case .table(let t):
            return ([t.header] + t.rows).map { $0.map { String($0.characters) }.joined(separator: "\t") }.joined(separator: "\n")
        case .rule: return ""
        }
    }

    /// Parses `text`. Soft line breaks become real line breaks: chat replies use single newlines as
    /// line breaks (bullet-like "• " lines, addresses), as in Hermes Desktop.
    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let blocks = parseUncached(text)
        cache.setObject(Parsed(blocks), forKey: text as NSString)
        return blocks
    }

    /// Parsed messages by text: a lazy row recreated while scrolling does not parse its message again
    /// (a long reply takes tens of milliseconds on the main thread).
    private final class Parsed {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
        let c = NSCache<NSString, Parsed>()
        c.countLimit = 256
        return c
    }()

    private static func parseUncached(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: escapingDroppedSyntax(text), options: options) else {
            return [.paragraph(AttributedString(text))]
        }
        let root = Node(kind: nil)
        for run in parsed.runs {
            var slice = AttributedString(parsed[run.range])
            if let i = run.inlinePresentationIntent, i.contains(.softBreak) {
                slice = AttributedString("\n")
            } else if let i = run.inlinePresentationIntent, i.contains(.lineBreak) {
                slice = AttributedString("\n")
            }
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            root.insert(slice, path: path[...])
        }
        let blocks = root.children.compactMap { $0.block() }
        return blocks.isEmpty ? [.paragraph(AttributedString(text))] : blocks
    }

    /// CommonMark constructs Foundation's parser consumes without emitting any text: HTML blocks (a line
    /// starting with `<`, which also swallows the lines after it up to a blank line), link reference and
    /// footnote definitions (`[x]: …`, `[^1]: …`). Their line-leading `<` / `[` (after any quote and list
    /// markers) is escaped so they show as the text the bot wrote. Lines inside fenced code are left
    /// alone; autolinks (`<https://…>`, `<a@b.c>`) keep working.
    static func escapingDroppedSyntax(_ text: String) -> String {
        // "\r\n" is one Character in Swift: normalise so the text splits into lines.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var fence: (char: Character, count: Int)?
        var out: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let prefixEnd = containerPrefixEnd(line)
            let body = line[prefixEnd...]
            if let f = fence {
                if Self.closesFence(body, f) { fence = nil }
                out.append(String(line))
                continue
            }
            if let f = Self.opensFence(body) {
                fence = f
                out.append(String(line))
            } else if Self.isDroppedConstruct(body) {
                out.append(String(line[..<prefixEnd]) + "\\" + body)
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }

    /// End of the leading container markup of a line: spaces, block-quote `>` and list markers
    /// (`-`, `*`, `+`, `1.`, `1)` followed by a space).
    private static func containerPrefixEnd(_ line: Substring) -> Substring.Index {
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == " " || c == "\t" || c == ">" { i = line.index(after: i); continue }
            if "-*+".contains(c), let next = line.index(i, offsetBy: 1, limitedBy: line.endIndex),
               next < line.endIndex, line[next] == " " {
                i = next; continue
            }
            if c.isASCII, c.isNumber {
                var j = i
                while j < line.endIndex, line[j].isASCII, line[j].isNumber { j = line.index(after: j) }
                if j < line.endIndex, line[j] == "." || line[j] == ")" {
                    let after = line.index(after: j)
                    if after < line.endIndex, line[after] == " " { i = after; continue }
                }
            }
            break
        }
        return i
    }

    /// A code fence: three or more backticks (whose info string has no backtick) or tildes.
    private static func opensFence(_ body: Substring) -> (char: Character, count: Int)? {
        guard let c = body.first, c == "`" || c == "~" else { return nil }
        let run = body.prefix(while: { $0 == c }).count
        guard run >= 3 else { return nil }
        if c == "`" && body.dropFirst(run).contains("`") { return nil }
        return (c, run)
    }

    /// Closed by the same character, at least as many, and nothing else on the line.
    private static func closesFence(_ body: Substring, _ f: (char: Character, count: Int)) -> Bool {
        let run = body.prefix(while: { $0 == f.char }).count
        return run >= f.count && body.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    private static func isDroppedConstruct(_ body: Substring) -> Bool {
        if body.hasPrefix("[") { return body.contains("]:") }
        guard body.hasPrefix("<") else { return false }
        // An autolink is not an HTML block: `<scheme:…>` or `<user@host>`.
        let inner = body.dropFirst().prefix(while: { $0 != ">" && $0 != " " })
        let isAutolink = body.dropFirst(inner.count + 1).first == ">"
            && (inner.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]{1,31}:"#, options: .regularExpression) != nil || inner.contains("@"))
        return !isAutolink
    }

    /// Inline markdown only (bold, italic, code, links), keeping line breaks: for text shown in one run,
    /// such as a Thought.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// One mutable tree node per block identity while folding runs.
    private final class Node {
        let kind: PresentationIntent.Kind?
        let identity: Int
        var children: [Node] = []
        var inline = AttributedString()

        init(kind: PresentationIntent.Kind?, identity: Int = -1) { self.kind = kind; self.identity = identity }

        func insert(_ slice: AttributedString, path: ArraySlice<PresentationIntent.IntentType>) {
            guard let first = path.first else { inline += slice; return }
            let child: Node
            if let last = children.last, last.identity == first.identity {
                child = last
            } else {
                child = Node(kind: first.kind, identity: first.identity)
                children.append(child)
            }
            child.insert(slice, path: path.dropFirst())
        }

        /// Leaf text: this node's own runs plus any nested leaves (a cell or heading never nests blocks,
        /// but a stray child is flattened rather than dropped).
        var flatInline: AttributedString {
            children.reduce(into: inline) { acc, c in
                let text = c.flatInline
                guard !text.characters.isEmpty else { return }
                if !acc.characters.isEmpty { acc += AttributedString("\n") }
                acc += text
            }
        }

        func blockChildren() -> [MarkdownBlock] {
            var out = children.compactMap { $0.block() }
            let own = Self.trimmed(inline)
            if !own.characters.isEmpty { out.insert(.paragraph(own), at: 0) }
            return out
        }

        func block() -> MarkdownBlock? {
            guard let kind else { return nil }
            switch kind {
            case .paragraph:
                let text = Self.trimmed(flatInline)
                return text.characters.isEmpty ? nil : .paragraph(text)
            case .header(let level):
                return .heading(level: level, Self.trimmed(flatInline))
            case .codeBlock(let language):
                var code = String(flatInline.characters)
                while code.last?.isNewline == true { code.removeLast() }
                return .code(language: language.flatMap { $0.isEmpty ? nil : $0 }, code)
            case .orderedList, .unorderedList:
                let items = children.map { $0.blockChildren() }
                let start = children.first.flatMap { c -> Int? in
                    if case .listItem(let n)? = c.kind { return n }
                    return nil
                } ?? 1
                if case .orderedList = kind { return .list(ordered: true, start: start, items: items) }
                return .list(ordered: false, start: 1, items: items)
            case .listItem:
                return .list(ordered: false, start: 1, items: [blockChildren()])
            case .blockQuote:
                return .quote(blockChildren())
            case .thematicBreak:
                return .rule
            case .table(let columns):
                return .table(table(columns))
            case .tableHeaderRow, .tableRow, .tableCell:
                let text = Self.trimmed(flatInline)
                return text.characters.isEmpty ? nil : .paragraph(text)
            @unknown default:
                let text = Self.trimmed(flatInline)
                return text.characters.isEmpty ? nil : .paragraph(text)
            }
        }

        private func table(_ columns: [PresentationIntent.TableColumn]) -> MarkdownTable {
            let alignments: [MarkdownTable.Alignment] = columns.map {
                switch $0.alignment {
                case .center: return .center
                case .right: return .trailing
                default: return .leading
                }
            }
            var header: [AttributedString] = []
            var rows: [[AttributedString]] = []
            for row in children {
                // A GFM row may have fewer cells than the header: pad it so every column lines up.
                var cells = Array(repeating: AttributedString(), count: alignments.count)
                for cell in row.children {
                    guard case .tableCell(let column)? = cell.kind, column < cells.count else { continue }
                    cells[column] = Self.trimmed(cell.flatInline)
                }
                if case .tableHeaderRow? = row.kind { header = cells } else { rows.append(cells) }
            }
            return MarkdownTable(alignments: alignments, header: header, rows: rows)
        }

        private static func trimmed(_ a: AttributedString) -> AttributedString {
            var a = a
            while let c = a.characters.first, c.isNewline || c == " " { a.removeSubrange(a.startIndex..<a.index(afterCharacter: a.startIndex)) }
            while let c = a.characters.last, c.isNewline || c == " " {
                a.removeSubrange(a.index(beforeCharacter: a.endIndex)..<a.endIndex)
            }
            return a
        }
    }
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    let alignments: [Alignment]
    /// One entry per column (empty strings for a missing header cell).
    let header: [AttributedString]
    let rows: [[AttributedString]]
}
