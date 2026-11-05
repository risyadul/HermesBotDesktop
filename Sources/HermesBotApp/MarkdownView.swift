import AppKit
import SwiftUI

/// Renders `MarkdownBlock`s the way Hermes Desktop shows a reply: headings, paragraphs, bulleted and
/// numbered lists (nested), block quotes, GFM tables, fenced code with its language and a copy button,
/// and horizontal rules. Inline code gets the code face on a surface tint; links open through the
/// environment's `openURL` (MessageBody allows http/https only).
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }

    /// Inline styling shared by every leaf block: inline code in the code face on a surface tint, links blue
    /// and underlined, @mentions of `mentions` (room member handles) blue and semibold.
    static func styled(_ text: AttributedString, mentions: Set<String> = []) -> AttributedString {
        var a = text
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = DS.Typeface.code
            a[run.range].backgroundColor = DS.Palette.surface
        }
        TextStyling.styleLinks(&a)
        TextStyling.highlightMentions(&a, handles: mentions)
        return a
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return DS.Typeface.titleState
        case 2, 3: return DS.Typeface.titlePane
        default: return DS.Typeface.bodyStrong
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.mentionHandles) private var mentions

    var body: some View {
        switch block {
        case .paragraph(let text):
            Prose(text: text)
        case .heading(let level, let text):
            Text(MarkdownView.styled(text, mentions: mentions))
                .font(MarkdownView.headingFont(level)).foregroundStyle(DS.Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 3 ? DS.Space.s1 : 0)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let code):
            CodeBlock(text: code, language: language)
        case .list(let ordered, let start, let items):
            MarkdownList(ordered: ordered, start: start, items: items)
        case .quote(let inner):
            HStack(alignment: .top, spacing: DS.Space.s3) {
                RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(DS.Palette.hairline)
                    .frame(width: DS.Space.s1 - 1)
                MarkdownView(blocks: inner).foregroundStyle(DS.Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle().fill(DS.Palette.hairline).frame(height: DS.Stroke.ring)
                .padding(.vertical, DS.Space.s1)
                .accessibilityHidden(true)
        }
    }
}

private struct Prose: View {
    let text: AttributedString
    @Environment(\.mentionHandles) private var mentions
    var body: some View {
        Text(MarkdownView.styled(text, mentions: mentions))
            .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
            .lineSpacing(DS.Typeface.proseLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownList: View {
    let ordered: Bool
    let start: Int
    let items: [[MarkdownBlock]]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(ordered ? "\(start + index)." : "•")
                        .font(DS.Typeface.body).foregroundStyle(DS.Palette.muted).monospacedDigit()
                        .frame(minWidth: DS.Space.s3, alignment: .trailing)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        ForEach(Array(item.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                }
            }
        }
    }
}

/// GFM table: header row in the strong face, hairline rules between rows, columns sized to their content,
/// cells wrap within the message width (no horizontal scroll, as in Hermes Desktop).
private struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.mentionHandles) private var mentions

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !table.header.isEmpty {
                row(table.header, header: true)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(DS.Palette.hairline).frame(height: DS.Stroke.hairline).gridCellUnsizedAxes(.horizontal)
                row(cells, header: false)
            }
        }
        .background(DS.Palette.window)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.ring))
    }

    private func row(_ cells: [AttributedString], header: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                Text(MarkdownView.styled(cell, mentions: mentions))
                    .font(header ? DS.Typeface.bodyStrong : DS.Typeface.body)
                    .foregroundStyle(DS.Palette.ink)
                    .multilineTextAlignment(textAlignment(column))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
                    .gridColumnAlignment(horizontalAlignment(column))
            }
        }
    }

    private func alignment(_ column: Int) -> MarkdownTable.Alignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Fenced code: optional language label and a copy button over a horizontally scrolling block.
struct CodeBlock: View {
    let text: String
    var language: String? = nil
    /// The language and copy row; off for the approval command, which shows only the command itself.
    var header = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header { headerRow }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.codeLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, DS.Space.s3).padding(.top, header ? DS.Space.s1 : DS.Space.gutter)
                    .padding(.bottom, DS.Space.gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.s2) {
            if let language {
                Text(language).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Copy code")
        }
        .padding(.horizontal, DS.Space.s3).padding(.top, DS.Space.s2)
    }
}

// MARK: - links and mentions

extension EnvironmentValues {
    /// Handles of the room's members: their @mentions in message text are highlighted. Empty in Bot Chat.
    @Entry var mentionHandles: Set<String> = []
}

/// Link and @mention styling shared by markdown blocks and user bubbles.
enum TextStyling {
    /// Links: blue and underlined, so clickable text reads as clickable (the app tint is graphite). A link that
    /// would not open (anything but http/https, e.g. an autolinked `mailto:`) is plain text, not a dead link.
    static func styleLinks(_ a: inout AttributedString) {
        for run in a.runs {
            guard let url = run.link else { continue }
            if MessageBody.opensLink(url) {
                a[run.range].foregroundColor = DS.Palette.link
                a[run.range].underlineStyle = .single
            } else {
                a[run.range].link = nil
            }
        }
    }

    /// `@handle` of a room member (and `@all` / `@everyone`): blue and semibold. Not inside inline code or a
    /// link, and not mid-word (`a@b.c` is not a mention).
    static func highlightMentions(_ a: inout AttributedString, handles: Set<String>) {
        guard !handles.isEmpty else { return }
        let text = String(a.characters)
        for range in mentionRanges(text, handles: handles) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let lo = a.characters.index(a.startIndex, offsetBy: start)
            let hi = a.characters.index(lo, offsetBy: length)
            let ar = lo..<hi
            if a[ar].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            a[ar].foregroundColor = DS.Palette.link
            a[ar].font = DS.Typeface.bodyStrong
        }
    }

    /// Ranges of `@handle` mentions of `handles` (plus @all / @everyone) in `text`.
    static func mentionRanges(_ text: String, handles: Set<String>) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w@])@([A-Za-z0-9][A-Za-z0-9._:-]*[A-Za-z0-9]|[A-Za-z0-9])")
        else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let h = ns.substring(with: m.range(at: 1))
            guard handles.contains(h) || ["all", "everyone"].contains(h.lowercased()) else { return nil }
            return Range(m.range, in: text)
        }
    }

    /// Plain text with its URLs as links (user messages are not markdown).
    static func linkified(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, MessageBody.opensLink(url), let r = Range(m.range, in: text),
                  let ar = Range(r, in: a) else { continue }
            a[ar].link = url
        }
        styleLinks(&a)
        return a
    }
}
