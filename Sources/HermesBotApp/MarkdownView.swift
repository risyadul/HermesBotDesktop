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

    /// Inline styling shared by every leaf block: inline code in the code face on a surface tint.
    static func styled(_ text: AttributedString) -> AttributedString {
        var a = text
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = DS.Typeface.code
            a[run.range].backgroundColor = DS.Palette.surface
        }
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

    var body: some View {
        switch block {
        case .paragraph(let text):
            Prose(text: text)
        case .heading(let level, let text):
            Text(MarkdownView.styled(text))
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
    var body: some View {
        Text(MarkdownView.styled(text))
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
                Text(MarkdownView.styled(cell))
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
