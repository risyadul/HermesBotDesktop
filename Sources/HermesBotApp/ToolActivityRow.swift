import HermesGatewayKit
import SwiftUI

/// One tool call, as in Hermes Desktop: category glyph (spinner while running, cross when failed), title
/// ("Ran git status", "Atlassian · getjiraissue"), muted count and duration. Click expands what the call
/// did: command or arguments, diff, output, exit code.
struct ToolActivityRow: View {
    let line: ChatLine
    /// 1 in the Bot Chat transcript; the narrow Activity panel wraps the title to 2 lines so a command
    /// stays readable (the count and duration never shrink).
    var titleLines = 1
    @EnvironmentObject private var disclosure: DisclosureStore
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let p = ToolRowPresentation(line)
        let expanded = p.expandable && disclosure.isOpen(.row, line.id)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button {
                guard p.expandable else { return }
                toggle(disclosure, .row, line.id, to: !expanded, motion: motion)
            } label: {
                HStack(alignment: titleLines > 1 ? .firstTextBaseline : .center, spacing: DS.Space.s2) {
                    ToolStateGlyph(state: p.state, symbol: p.symbol)
                    Text(p.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                        .lineLimit(titleLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: titleLines > 1)
                        .layoutPriority(titleLines > 1 ? 1 : 0)
                    if let context = p.context {
                        Text(context).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    ForEach([p.count, p.duration].compactMap { $0 }, id: \.self) { meta in
                        Text(meta).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).monospacedDigit()
                            .fixedSize()
                    }
                    if p.expandable {
                        Image(systemName: "chevron.right").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionRowStyle(highlighted: false))
            .accessibilityLabel(p.accessibilityLabel)
            .accessibilityHint(p.expandable ? (expanded ? "Hides the details" : "Shows what the tool did") : "")
            if expanded {
                ToolDetailsView(details: p.details)
                    .padding(.leading, DS.Space.s5)
                    .transition(motion ? .opacity : .identity)
            }
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
    }
}

struct ToolStateGlyph: View {
    let state: ToolLine.State
    let symbol: String?
    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(DS.Typeface.iconSmall)
                    .foregroundStyle(state == .failed ? DS.Palette.danger : DS.Palette.muted)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: DS.Space.s4)
        .accessibilityHidden(true)
    }
}

private struct ToolDetailsView: View {
    let details: [ToolDetail]
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                switch detail {
                case .code(let label, let language, let text):
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text(label).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                        CodeBlock(text: text, language: language)
                    }
                case .text(let label, let text):
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        Text(label).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                        Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Two or more adjacent tool calls: one summary line ("Ran 2 commands, used 1 tool"), collapsed by
/// default like Hermes Desktop. While a call runs, the collapsed line also shows what is running now.
struct ToolGroupView: View {
    let lines: [ChatLine]
    @EnvironmentObject private var disclosure: DisclosureStore
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let summary = ToolCategory.summary(lines.map { $0.tool?.name ?? "tool" })
        let running = lines.last { $0.tool?.state == .running }.map { ToolRowPresentation($0).title }
        let failed = lines.contains { $0.tool?.state == .failed }
        let expanded = disclosure.isOpen(.group, lines[0].id)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button {
                toggle(disclosure, .group, lines[0].id, to: !expanded, motion: motion)
            } label: {
                HStack(spacing: DS.Space.s2) {
                    Text(summary).font(DS.Typeface.body).foregroundStyle(DS.Palette.muted).lineLimit(1)
                    if failed {
                        Image(systemName: "xmark.circle.fill").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.danger)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.down").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    if !expanded, let running {
                        ProgressView().controlSize(.mini)
                        Text(running).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionRowStyle(highlighted: false))
            .accessibilityLabel(summary + (failed ? ", a call failed" : "") + (running.map { ", running \($0)" } ?? ""))
            .accessibilityHint(expanded ? "Hides the tool calls" : "Shows each tool call")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { ToolActivityRow(line: $0) }
                }
                .transition(motion ? .opacity : .identity)
            }
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
    }
}

/// A step's reasoning: "Thinking" and open while it streams (the latest lines in a short scrolling
/// preview), "Thought" and collapsed once done or when loaded from history, as in Hermes Desktop
/// (`ThinkingDisclosure`, `message-parts.tsx:203-342`). The user's toggle wins over both defaults.
struct ThoughtRow: View {
    let line: ChatLine
    /// Bot Chat opens a streaming Thought; the narrow Activity panel keeps it collapsed until clicked.
    var opensWhileStreaming = true
    @EnvironmentObject private var disclosure: DisclosureStore
    @Environment(\.motionEnabled) private var motion

    static let previewHeight: CGFloat = 160

    var body: some View {
        let expanded = disclosure.isOpen(.thought, line.id, fallback: line.streaming && opensWhileStreaming)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button {
                toggle(disclosure, .thought, line.id, to: !expanded, motion: motion)
            } label: {
                HStack(spacing: DS.Space.s2) {
                    Text(line.streaming ? "Thinking" : "Thought").font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
                    if line.streaming { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionRowStyle(highlighted: false))
            .accessibilityLabel(line.streaming ? "Thinking" : "Thought")
            .accessibilityHint(expanded ? "Hides the reasoning" : "Shows the reasoning")
            if expanded {
                Group {
                    if line.streaming {
                        ScrollView { reasoning }.frame(maxHeight: Self.previewHeight).defaultScrollAnchor(.bottom)
                    } else {
                        reasoning
                    }
                }
                .padding(.leading, DS.Space.s2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DS.Palette.hairline).frame(width: DS.Stroke.ring)
                }
                .padding(.leading, DS.Space.s2)
                .transition(motion ? .opacity : .identity)
            }
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
    }

    private var reasoning: some View {
        Text(MarkdownView.styled(MarkdownBlock.inline(line.text)))
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            .lineSpacing(DS.Typeface.proseLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private func toggle(_ store: DisclosureStore, _ kind: DisclosureStore.Kind, _ id: UUID, to open: Bool, motion: Bool) {
    if motion { withAnimation(DS.Motion.ease) { store.set(kind, id, open) } } else { store.set(kind, id, open) }
}

/// Client notes (slash command output, notices, history system rows): muted, leading, no bubble.
struct SystemNoteRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Image(systemName: "info.circle").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                .accessibilityHidden(true)
            Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}
