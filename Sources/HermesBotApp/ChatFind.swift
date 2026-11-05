import HermesGatewayKit
import SwiftUI

/// B13: Find in chat (⌘F). Matches are case- and diacritic-insensitive occurrences of the query in the text
/// the transcript shows as messages: the user's messages, the bot's replies, errors and notes. Thought and
/// tool rows (collapsed by default) and Hermes notices are not searched, so every match is on screen when
/// scrolled to. Unit tested (ChatFindTests).
struct ChatFind: Equatable {
    struct Match: Equatable {
        let lineId: UUID
        /// Which occurrence within its line (0-based).
        let occurrence: Int
    }

    private(set) var query = ""
    private(set) var matches: [Match] = []
    /// Index of the current match in `matches`; nil when there is none.
    private(set) var current: Int?

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    var currentMatch: Match? { current.map { matches[$0] } }

    /// "3 of 12", "No results", or "" before anything is typed.
    var label: String {
        guard !query.isEmpty else { return "" }
        guard let current else { return "No results" }
        return "\(current + 1) of \(matches.count)"
    }

    /// The text a line is searched in, nil when the line is not searched.
    static func searchable(_ line: ChatLine) -> String? {
        switch line.role {
        case .user: return SystemNotice.parse(line.text) == nil ? line.text : nil
        case .bot, .error, .system: return line.text
        case .thought, .tool: return nil
        }
    }

    static func count(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var n = 0
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: query, options: options, range: from..<text.endIndex) {
            n += 1
            from = r.isEmpty ? text.index(after: r.lowerBound) : r.upperBound
        }
        return n
    }

    /// A new query: matches are rebuilt and the current one is the last (the newest message, nearest the
    /// bottom where a chat is read).
    mutating func setQuery(_ q: String, lines: [ChatLine]) {
        query = q
        rebuild(lines)
        current = matches.isEmpty ? nil : matches.count - 1
    }

    /// The transcript changed (a reply streamed in): matches are rebuilt and the current match stays on
    /// the same occurrence when it still exists, else the nearest one before it.
    mutating func refresh(_ lines: [ChatLine]) {
        let previous = currentMatch
        let previousIndex = current
        rebuild(lines)
        guard !matches.isEmpty else { current = nil; return }
        if let previous, let i = matches.firstIndex(of: previous) {
            current = i
        } else {
            current = min(previousIndex ?? matches.count - 1, matches.count - 1)
        }
    }

    /// Next (Return, ⌘G) and previous (⇧Return, ⇧⌘G), wrapping around.
    mutating func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let c = current ?? (delta > 0 ? -1 : 0)
        current = ((c + delta) % matches.count + matches.count) % matches.count
    }

    private mutating func rebuild(_ lines: [ChatLine]) {
        var out: [Match] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : query
        if !q.isEmpty {
            for line in lines {
                guard let text = Self.searchable(line) else { continue }
                for k in 0..<Self.count(of: q, in: text) { out.append(Match(lineId: line.id, occurrence: k)) }
            }
        }
        matches = out
    }
}

extension EnvironmentValues {
    /// B13: the Find in chat query; its occurrences are highlighted in message text. Empty when the find bar is
    /// closed (and everywhere outside Bot Chat).
    @Entry var findQuery: String = ""
}

extension TextStyling {
    /// B13: every occurrence of `query` gets the `find-match` background.
    static func highlightFind(_ a: inout AttributedString, query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = String(a.characters)
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: query, options: ChatFind.options, range: from..<text.endIndex), !r.isEmpty {
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let length = text.distance(from: r.lowerBound, to: r.upperBound)
            let lo = a.characters.index(a.startIndex, offsetBy: start)
            let hi = a.characters.index(lo, offsetBy: length)
            a[lo..<hi].backgroundColor = DS.Palette.findMatch
            from = r.upperBound
        }
    }
}

/// The ring around the message holding the current match (`find-current`), just outside its bounds.
struct FindCurrentRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.findCurrent, lineWidth: DS.Stroke.focus)
            .padding(-DS.Space.s1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The find bar above the Bot Chat transcript: query field, match count, previous / next, Done.
/// Return goes to the next match, ⇧Return to the previous one, Esc closes; ⌘G / ⇧⌘G work while it is open.
struct ChatFindBar: View {
    @Binding var find: ChatFind
    let lines: [ChatLine]
    /// Bumped by ⌘F while the bar is open: the caret goes back to the field.
    var focusRequest = 0
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "magnifyingglass").font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                .accessibilityHidden(true)
            TextField("Find in chat", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typeface.body)
                .focused($focused)
                .onSubmit { find.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityLabel("Find in chat")
            Text(find.label)
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                .monospacedDigit().lineLimit(1).fixedSize()
                .accessibilityLabel(find.label.isEmpty ? "" : "Match \(find.label)")
            IconButton(symbol: "chevron.up", label: "Previous match") { find.step(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find.matches.isEmpty)
            IconButton(symbol: "chevron.down", label: "Next match") { find.step(1) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(find.matches.isEmpty)
            Button("Done", action: onClose)
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .help("Close the find bar (Esc)")
        }
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s2)
        .background(DS.Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.hairline).frame(height: DS.Stroke.hairline) }
        .onAppear { text = find.query; focused = true }
        .onChange(of: text) { _, q in find.setQuery(q, lines: lines) }
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in chat")
    }
}
