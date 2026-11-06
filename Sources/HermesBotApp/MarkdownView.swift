import AppKit
import HermesGatewayKit
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
    /// and underlined, @mentions of `mentions` (room member handles) blue and semibold, Find in chat matches of
    /// `find` (B13) on the `find-match` background.
    static func styled(_ text: AttributedString, mentions: Set<String> = [], find: String = "") -> AttributedString {
        var a = text
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = DS.Typeface.code
            a[run.range].backgroundColor = DS.Palette.surface
        }
        TextStyling.styleLinks(&a)
        TextStyling.highlightMentions(&a, handles: mentions)
        TextStyling.highlightFind(&a, query: find)
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
    @Environment(\.findQuery) private var find

    var body: some View {
        switch block {
        case .paragraph(let text):
            Prose(text: text)
        case .heading(let level, let text):
            Text(MarkdownView.styled(text, mentions: mentions, find: find))
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
    @Environment(\.findQuery) private var find
    var body: some View {
        Text(MarkdownView.styled(text, mentions: mentions, find: find))
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
/// cells wrap within the message width (no horizontal scroll, as in Hermes Desktop). Laid out by
/// `MarkdownTableLayout`, not `Grid`: Grid measured wrapped cells at other widths than it placed them at, so a
/// table could draw taller than it reported and the next row of the timeline overlapped its end.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.mentionHandles) private var mentions
    @Environment(\.findQuery) private var find

    private var columns: Int { max(table.alignments.count, table.header.count, table.rows.map(\.count).max() ?? 0) }

    var body: some View {
        let rows = (table.header.isEmpty ? [] : [table.header]) + table.rows
        MarkdownTableLayout(columns: columns) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, cells in
                let header = r == 0 && !table.header.isEmpty
                ForEach(0..<columns, id: \.self) { c in
                    cell(c < cells.count ? cells[c] : AttributedString(), column: c, header: header, ruled: r > 0)
                }
            }
        }
        .background(DS.Palette.window)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.ring))
    }

    /// One cell, filling its slot (so the rule above it spans the column) with the text at the top.
    private func cell(_ text: AttributedString, column: Int, header: Bool, ruled: Bool) -> some View {
        Text(MarkdownView.styled(text, mentions: mentions, find: find))
            .font(header ? DS.Typeface.bodyStrong : DS.Typeface.body)
            .foregroundStyle(DS.Palette.ink)
            .multilineTextAlignment(textAlignment(column))
            .textSelection(.enabled)
            .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(column))
            .overlay(alignment: .top) {
                if ruled { Rectangle().fill(DS.Palette.hairline).frame(height: DS.Stroke.hairline) }
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

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}

/// Row-major table layout with one rule for column widths, used both to measure and to place: each column
/// gets its content's ideal width when everything fits; otherwise columns narrower than an even share keep
/// their ideal width and the rest of the width goes to the wide columns in proportion to their ideal widths.
/// Row heights are measured at exactly those widths, so the reported height is the drawn height.
struct MarkdownTableLayout: Layout {
    let columns: Int

    struct Cache {
        var ideal: [CGFloat] = []
        var measuredWidths: [CGFloat]?
        var measuredHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var ideal = Array(repeating: CGFloat(0), count: columns)
        for (i, v) in subviews.enumerated() where columns > 0 {
            ideal[i % columns] = max(ideal[i % columns], ceil(v.sizeThatFits(.unspecified).width))
        }
        return Cache(ideal: ideal)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }

    /// Column widths for an available width (`nil`: unconstrained).
    static func widths(ideal: [CGFloat], available: CGFloat?) -> [CGFloat] {
        guard let available, ideal.reduce(0, +) > available, !ideal.isEmpty else { return ideal }
        var fixed = Set<Int>()
        while true {
            let open = ideal.indices.filter { !fixed.contains($0) }
            guard !open.isEmpty else { break }
            let left = available - fixed.reduce(0) { $0 + ideal[$1] }
            let share = left / CGFloat(open.count)
            let narrow = open.filter { ideal[$0] <= share }
            if narrow.isEmpty {
                let total = open.reduce(0) { $0 + ideal[$1] }
                var out = ideal
                for c in open { out[c] = max(0, floor(left * ideal[c] / total)) }
                return out
            }
            fixed.formUnion(narrow)
        }
        return ideal
    }

    private func rowHeights(_ widths: [CGFloat], subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let rows = (subviews.count + columns - 1) / columns
        var heights = Array(repeating: CGFloat(0), count: rows)
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            heights[i / columns] = max(heights[i / columns], ceil(h))
        }
        return heights
    }

    private func rowHeights(_ widths: [CGFloat], subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.measuredWidths == widths { return cache.measuredHeights }
        let heights = rowHeights(widths, subviews: subviews)
        cache.measuredWidths = widths
        cache.measuredHeights = heights
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = Self.widths(ideal: cache.ideal, available: proposal.width)
        return CGSize(width: widths.reduce(0, +), height: rowHeights(widths, subviews: subviews, cache: &cache).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = Self.widths(ideal: cache.ideal, available: bounds.width)
        let heights = rowHeights(widths, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for r in heights.indices {
            var x = bounds.minX
            for c in 0..<columns {
                let i = r * columns + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: widths[c], height: heights[r]))
                x += widths[c]
            }
            y += heights[r]
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

    /// `@handle` of a room member (and `@all` / `@everyone`): blue and semibold. `@user` (a bot asking the
    /// user) is `attention` and semibold, so "the bot needs you" stands out, unless a member is handled
    /// `user`. Not inside inline code or a link, and not mid-word (`a@b.c` is not a mention): the grammar is
    /// `UserMention`'s, shared with the room badge and the notifications. Group Chat only (`handles` empty in
    /// Bot Chat).
    static func highlightMentions(_ a: inout AttributedString, handles: Set<String>) {
        guard !handles.isEmpty else { return }
        let text = String(a.characters)
        let userIsMember = handles.contains { UserMention.isUser($0) }
        for m in mentionRanges(text, handles: handles) {
            let range = m.range
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let lo = a.characters.index(a.startIndex, offsetBy: start)
            let hi = a.characters.index(lo, offsetBy: length)
            let ar = lo..<hi
            if a[ar].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            a[ar].foregroundColor = m.isUser && !userIsMember ? DS.Palette.attention : DS.Palette.link
            a[ar].font = DS.Typeface.bodyStrong
        }
    }

    /// `@handle` mentions of `handles` (plus @all / @everyone and @user) in `text`.
    static func mentionRanges(_ text: String, handles: Set<String>) -> [UserMention.Mention] {
        UserMention.mentions(in: text).filter {
            handles.contains($0.handle) || ["all", "everyone", "user"].contains($0.handle.lowercased())
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
