import HermesGatewayKit
import SwiftUI

/// Keyboard model of the composer's slash menu: open while the draft is "/" plus a command word (no space
/// yet) and the catalog has matches, unless Esc closed it for this exact draft. ↑/↓ move (wrapping),
/// Tab/Return accept (`/name ` replaces the draft). Pure value type, unit tested.
struct SlashMenuState: Equatable {
    var selection = 0
    /// The draft Esc closed the menu on; typing anything else reopens it.
    var dismissedDraft: String?

    /// The text after "/" while the draft is a bare command word; nil otherwise.
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.hasPrefix("//") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        return String(rest)
    }

    static func items(_ draft: String, catalog: SlashCatalog?) -> [SlashCommand] {
        guard let q = query(draft), let catalog else { return [] }
        return catalog.filter(q)
    }

    func isOpen(_ draft: String, catalog: SlashCatalog?) -> Bool {
        dismissedDraft != draft && !Self.items(draft, catalog: catalog).isEmpty
    }

    /// The highlighted command (selection clamped to the current matches).
    func highlighted(_ draft: String, catalog: SlashCatalog?) -> SlashCommand? {
        let items = Self.items(draft, catalog: catalog)
        guard !items.isEmpty else { return nil }
        return items[min(max(selection, 0), items.count - 1)]
    }

    mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = ((min(selection, count - 1) + delta) % count + count) % count
    }

    /// The draft changed (typing): the highlight goes back to the best match.
    mutating func draftChanged(_ draft: String) {
        selection = 0
        if dismissedDraft != draft { dismissedDraft = nil }
    }

    mutating func dismiss(_ draft: String) { dismissedDraft = draft }

    /// Return with the menu open: accept the highlight, unless the draft already names it exactly (then the
    /// command is sent as typed).
    func returnAccepts(_ draft: String, catalog: SlashCatalog?) -> Bool {
        guard isOpen(draft, catalog: catalog), let h = highlighted(draft, catalog: catalog) else { return false }
        return h.name.lowercased() != draft.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The draft after accepting the highlight, or nil when nothing is highlighted.
    func accept(_ draft: String, catalog: SlashCatalog?) -> String? {
        highlighted(draft, catalog: catalog).map { "\($0.name) " }
    }
}

/// The popover list above the composer. Rows are buttons (click accepts); the highlighted row follows
/// the keyboard selection.
struct SlashCommandMenu: View {
    let items: [SlashCommand]
    let selected: String?
    let onPick: (SlashCommand) -> Void
    private static let maxRows = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { c in
                        Button { onPick(c) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                                Text(c.name).font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                                Text(c.description).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Size.fieldInset)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SuggestionRowStyle(highlighted: c.name == selected))
                        .id(c.name)
                        .accessibilityLabel("\(c.name), \(c.description)")
                        .accessibilityAddTraits(c.name == selected ? .isSelected : [])
                    }
                }
                .padding(DS.Space.s1)
            }
            .frame(maxHeight: CGFloat(min(items.count, Self.maxRows)) * (DS.Size.controlHeight + DS.Space.s0) + DS.Space.s2)
            .onChange(of: selected) { _, name in if let name { proxy.scrollTo(name) } }
        }
        .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
        .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
        .dsShadow(DS.Elevation.popover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }
}
