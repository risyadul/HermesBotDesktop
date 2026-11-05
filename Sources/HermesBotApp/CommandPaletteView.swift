import AppKit
import HermesGatewayKit
import SwiftUI

// D5 / D10: the palette. ⌘K opens it on "Go to" (fuzzy search over group chats, bots and boards), ⇧⌘F on
// "Messages" (QuickSwitch.swift `MessageSearch` over what the app holds). Tab switches scope, ↑/↓ move, Return
// opens, Escape closes. Opening a message selects its pane and scrolls to it (`MessageJumpTarget`).

struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var mutes: NotificationMutes
    @StateObject private var search: MessageSearchModel
    @State private var mode: PaletteMode
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool
    let onClose: () -> Void

    init(model: AppModel, mode: PaletteMode, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _mutes = ObservedObject(wrappedValue: model.mutes)
        _search = StateObject(wrappedValue: MessageSearchModel(sources: { [weak model] in model?.searchSources ?? [] },
                                                               changes: model.searchSourcesChanged))
        _mode = State(initialValue: mode)
        self.onClose = onClose
    }

    private var switchResults: [QuickSwitchCandidate] { QuickSwitch.results(query, model.switchCandidates) }
    private var messageResults: [MessageSearch.Hit] { search.hits }
    private var count: Int { mode == .switcher ? switchResults.count : messageResults.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: mode == .switcher ? "arrow.right.circle" : "magnifyingglass")
                    .font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                TextField(mode == .switcher ? "Go to a group chat, bot or board" : "Search messages in open chats and rooms",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typeface.titlePane)
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.tab) { switchMode(); return .handled }
                    .onExitCommand(perform: onClose)
                    .accessibilityLabel(mode == .switcher ? "Go to" : "Search messages")
                Picker("Scope", selection: $mode) {
                    ForEach(PaletteMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Tab switches between Go to and Messages")
            }
            .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mode == .switcher { switcherRows } else { messageRows }
                    }
                    .padding(DS.Space.s2)
                }
                .frame(height: DS.Size.paletteListHeight)
                .onChange(of: selected) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: DS.Size.paletteWidth)
        .background(DS.Palette.window)
        .onAppear { fieldFocused = true; search.search(query) }
        .onChange(of: query) { _, q in selected = 0; search.search(q) }
        .onChange(of: mode) { _, _ in selected = 0; fieldFocused = true }
    }

    @ViewBuilder private var switcherRows: some View {
        let rows = switchResults
        if rows.isEmpty {
            placeholder("No group chat, bot or board matches.")
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
            PaletteRow(selected: i == selected, action: { open(c) }) {
                Image(systemName: Self.symbol(c.kind)).font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                    .frame(width: DS.Size.avatarRow)
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text(c.title).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    if !c.subtitle.isEmpty {
                        Text(c.subtitle).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if mutes.isMuted(c.item) {
                    Image(systemName: "bell.slash").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                        .accessibilityLabel("Notifications muted")
                }
                if let n = shortcutNumber(c.item) {
                    Text("⌘\(n)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            .id(i)
        }
    }

    @ViewBuilder private var messageRows: some View {
        let hits = messageResults
        if query.trimmingCharacters(in: .whitespaces).count < MessageSearch.minQuery {
            placeholder("Type at least \(MessageSearch.minQuery) characters. Searches the Bot Chats opened since launch and the recent messages of every group chat.")
        } else if hits.isEmpty {
            placeholder(MessageSearch.noResultsNote)
        }
        ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
            PaletteRow(selected: i == selected, action: { open(hit) }) {
                Image(systemName: hit.item.isRoom ? "bubble.left.and.bubble.right" : "bubble.left")
                    .font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                    .frame(width: DS.Size.avatarRow)
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text("\(hit.sourceTitle) · \(hit.author)").font(DS.Typeface.metaStrong)
                        .foregroundStyle(DS.Palette.muted).lineLimit(1)
                    Text(Self.highlighted(hit.snippet, terms: MessageSearch.terms(query)))
                        .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .id(i)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DS.Space.s3)
    }

    private func shortcutNumber(_ item: SidebarItem) -> Int? {
        SidebarShortcuts.targets(model.sidebarOrder).firstIndex(of: item).map { $0 + 1 }
    }

    private func move(_ delta: Int) {
        guard count > 0 else { return }
        selected = min(max(0, selected + delta), count - 1)
    }

    private func switchMode() {
        mode = mode == .switcher ? .messages : .switcher
    }

    private func openSelected() {
        if mode == .switcher {
            let rows = switchResults
            if rows.indices.contains(selected) { open(rows[selected]) }
        } else {
            let hits = messageResults
            if hits.indices.contains(selected) { open(hits[selected]) }
        }
    }

    private func open(_ c: QuickSwitchCandidate) {
        onClose()
        model.select(c.item)
    }

    private func open(_ hit: MessageSearch.Hit) {
        onClose()
        model.open(hit)
    }

    static func symbol(_ kind: QuickSwitchCandidate.Kind) -> String {
        switch kind {
        case .room: return "bubble.left.and.bubble.right"
        case .bot: return "person.crop.circle"
        case .board: return "square.grid.3x2"
        }
    }

    /// The snippet with every query term in bold.
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var out = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchStart = out.startIndex
            while let r = out[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].inlinePresentationIntent = .stronglyEmphasized
                searchStart = r.upperBound
            }
        }
        return out
    }
}

/// One palette row: the selection uses the sidebar's selected tint; hover tints like a sidebar row.
private struct PaletteRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.gutter) { content }
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .frame(maxWidth: .infinity, minHeight: DS.Size.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PaletteRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PaletteRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label.background {
                let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                if selected { shape.fill(DS.Palette.selected) } else if hovering || configuration.isPressed { shape.fill(DS.Palette.hover) }
            }
        }
    }
}

extension SidebarItem {
    var isRoom: Bool { if case .room = self { return true }; return false }
}

extension DS.Size {
    static let paletteWidth: CGFloat = 560
    static let paletteListHeight: CGFloat = 360
}
