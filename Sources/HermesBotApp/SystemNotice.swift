import HermesGatewayKit
import SwiftUI

/// A user-role transcript row that Hermes itself wrote ("[IMPORTANT: Background process … exited …]",
/// "[System: …]", "[CONTEXT SUMMARY]: …"), shown as a muted, collapsible notice instead of a user bubble.
/// Pure, unit tested (SystemNoticeTests).
///
/// The openers mirror hermes-agent `agent/prompt_builder.py` `CONTROL_FRAME_OPENERS` (commit 837acdc91d7, the
/// list hosted rooms and Hermes Desktop relabel) plus `[Your active task list` from
/// `agent/context_compressor.py` `_SYNTHETIC_USER_ROW_PREFIXES`. Two kinds of frame carry the user's own words
/// and stay user bubbles: the steer marker (`[OUT-OF-BAND USER MESSAGE …`, a message the user sent mid-turn)
/// and skill invocations (`[IMPORTANT: The user has invoked …` / `[IMPORTANT: The "X" skill …`, followed by
/// what the user typed). Only a message that starts with a frame counts, case-sensitively as Hermes writes
/// them, so text a person typed is never folded away.
struct SystemNotice: Equatable {
    /// One line naming the notice ("Background process proc_8c0e… exited (exit code 1).").
    let title: String
    /// The whole message, shown when the notice is opened.
    let text: String

    /// Text after the "[" of a Hermes control frame.
    static let openers = [
        "CONTEXT COMPACTION", "CONTEXT SUMMARY]", "PRIOR CONTEXT", "Runtime note:", "System note:", "System:",
        "SYSTEM]", "IMPORTANT:", "Planning state preserved", "ASYNC DELEGATION", "Your active task list",
    ]
    /// Frames that wrap words the user typed (agent/skill_commands.py).
    static let userFrames = ["IMPORTANT: The user ", "IMPORTANT: The \""]
    static let titleLimit = 120

    /// The notice for a user-role message written by Hermes, or nil for anything a person wrote.
    static func parse(_ text: String) -> SystemNotice? {
        let body = text.drop { $0.isWhitespace || $0.isNewline }
        guard body.first == "[" else { return nil }
        let frame = body.dropFirst()
        guard let opener = openers.first(where: { frame.hasPrefix($0) }),
              !userFrames.contains(where: { frame.hasPrefix($0) }) else { return nil }
        return SystemNotice(title: title(firstLine: String(frame.prefix { !$0.isNewline }), opener: opener), text: text)
    }

    /// The first line without the bracket, the "IMPORTANT:"-style label and a closing "]": "Background
    /// process … exited", "Context summary".
    static func title(firstLine: String, opener: String) -> String {
        var line = Substring(firstLine)
        if opener.hasSuffix(":") { line = line.dropFirst(opener.count) }
        var title = line.trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("]") { title.removeLast() }
        if let close = title.firstIndex(of: "]"), title[..<close].uppercased() == title[..<close] {
            title = String(title[..<close])  // "CONTEXT SUMMARY]: …" names the frame, not its body
        }
        title = title.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
        if title.isEmpty { title = opener.trimmingCharacters(in: CharacterSet(charactersIn: ":]")) }
        if title == title.uppercased() { title = title.prefix(1) + title.dropFirst().lowercased() }
        return title.count > titleLimit ? String(title.prefix(titleLimit)) + "…" : title
    }
}

/// `system-notice`: Hermes' own message in the transcript. One muted row (info symbol, "Hermes note", the
/// notice title, chevron) on the content edge; click opens the full text behind a hairline bar, like a
/// Thought. Collapsed by default; the user's toggle is kept in the `DisclosureStore`.
struct SystemNoticeRow: View {
    let notice: SystemNotice
    let id: UUID
    @EnvironmentObject private var disclosure: DisclosureStore
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let expanded = disclosure.isOpen(.notice, id)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Button {
                if motion { withAnimation(DS.Motion.ease) { disclosure.set(.notice, id, !expanded) } }
                else { disclosure.set(.notice, id, !expanded) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Image(systemName: "info.circle").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                    Text("Hermes note").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.muted)
                    Text(notice.title).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionRowStyle(highlighted: false))
            .accessibilityLabel("Hermes note: \(notice.title)")
            .accessibilityHint(expanded ? "Hides the note" : "Shows the whole note")
            if expanded {
                Text(notice.text)
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .lineSpacing(DS.Typeface.proseLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DS.Space.s2)
                    .overlay(alignment: .leading) { Rectangle().fill(DS.Palette.hairline).frame(width: DS.Stroke.ring) }
                    .padding(.leading, DS.Space.s2)
                    .transition(motion ? .opacity : .identity)
            }
        }
        .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
        .padding(.leading, DS.Size.contentInset - DS.Space.s2)
    }
}
