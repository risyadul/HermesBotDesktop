import HermesGatewayKit
import SwiftUI

/// What a tool row shows, derived from a `.tool` transcript line (unit tested).
struct ToolRowPresentation: Equatable {
    let name: String
    let context: String
    let summary: String?
    let state: ToolLine.State
    let duration: String?

    init(_ line: ChatLine) {
        let tool = line.tool
        name = tool?.name ?? "tool"
        context = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = tool?.summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        state = tool?.state ?? .done
        duration = tool?.duration.map(Self.format)
    }

    /// "0.4s", "12s", "2m 05s".
    static func format(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", max(0, seconds)) }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    var symbol: String? {
        switch state {
        case .running: return nil
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var expandable: Bool { summary != nil }

    var accessibilityLabel: String {
        let status: String
        switch state {
        case .running: status = "running"
        case .done: status = "done"
        case .failed: status = "failed"
        }
        return ["Tool \(name)", context.isEmpty ? nil : context, status, duration].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Compact tool-call row: state (spinner, check, cross), tool name, one-line context, duration. Click
/// expands the summary when the call returned one.
struct ToolActivityRow: View {
    let line: ChatLine
    @State private var expanded = false
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let p = ToolRowPresentation(line)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button {
                guard p.expandable else { return }
                if motion { withAnimation(DS.Motion.ease) { expanded.toggle() } } else { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.s2) {
                    Group {
                        if let symbol = p.symbol {
                            Image(systemName: symbol).font(DS.Typeface.iconSmall)
                                .foregroundStyle(p.state == .failed ? DS.Palette.danger : DS.Palette.statusOK)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: DS.Space.s4)
                    Text(p.name).font(DS.Typeface.code).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if !p.context.isEmpty {
                        Text(p.context).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: DS.Space.s2)
                    if let d = p.duration {
                        Text(d).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).monospacedDigit()
                    }
                    if p.expandable {
                        Image(systemName: "chevron.right").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionRowStyle(highlighted: false))
            .accessibilityLabel(p.accessibilityLabel)
            .accessibilityHint(p.expandable ? (expanded ? "Hides the result summary" : "Shows the result summary") : "")
            if expanded, let summary = p.summary {
                Text(summary).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    .transition(motion ? .opacity : .identity)
            }
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
        .padding(.leading, DS.Size.contentInset - DS.Space.s2)
    }
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
