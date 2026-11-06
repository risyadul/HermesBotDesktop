import HermesGatewayKit
import SwiftUI

/// What the section-name sheet is doing (A5): a new section (optionally filing the bot whose menu opened
/// it) or a rename.
enum SectionNameRequest: Identifiable, Equatable {
    case create(filing: String?)
    case rename(BotSection)

    var id: String {
        switch self {
        case .create(let bot): return "create:" + (bot ?? "")
        case .rename(let s): return "rename:" + s.id
        }
    }
}

/// New Section… / Rename Section… sheet: one name field, Create / Rename and Cancel.
struct SectionNameView: View {
    let request: SectionNameRequest
    let onSave: (String) -> Void
    /// Presented by `motionSheet`, so `\.dismiss` would not reach it.
    let onClose: () -> Void
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(request: SectionNameRequest, onSave: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.request = request; self.onSave = onSave; self.onClose = onClose
        if case .rename(let s) = request { _name = State(initialValue: s.name) } else { _name = State(initialValue: "") }
    }

    static func canSave(_ name: String, request: SectionNameRequest) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if case .rename(let s) = request { return clean != s.name }
        return true
    }

    private var isRename: Bool { if case .rename = request { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(isRename ? "Rename section" : "New section").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $name, prompt: Text("Clients")).textFieldStyle(.roundedBorder).labelsHidden()
                    .focused($nameFocused)
                    .onSubmit(save)
                Text("Sections group bots in the sidebar. Each bot remembers its section in its profile, so Hermes Desktop shows the same folders.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create", action: save)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSave(name, request: request))
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard Self.canSave(name, request: request) else { return }
        onSave(name)
        onClose()
    }
}

/// A section's header in the Bots list: chevron, name, count; a drop target for dragged bot rows. The
/// Unassigned header has no menu (it is not a section).
struct BotSectionHeader<Menu: View>: View {
    let title: String
    let count: Int
    let collapsed: Bool
    /// False for Unassigned, which is what is left, not a folder.
    let isSection: Bool
    let dropTargeted: Bool
    let onToggle: () -> Void
    @ViewBuilder var menu: Menu

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(DS.Typeface.meta)
                if isSection { Image(systemName: "folder").font(DS.Typeface.iconSmall) }
                Text(title).font(DS.Typeface.captionStrong).lineLimit(1)
                Text("\(count)").font(DS.Typeface.caption.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.muted)
            .frame(minHeight: DS.Size.sectionHeader)
            .padding(.horizontal, DS.Space.s2)
            .background(dropTargeted ? DS.Palette.selected : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
        .accessibilityLabel("\(title) section, \(count) bot\(count == 1 ? "" : "s")")
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

/// An empty named section: a quiet dashed slot that says what it is for and takes a dropped bot.
struct BotSectionEmptySlot: View {
    let dropTargeted: Bool

    var body: some View {
        Text("Drag bots here")
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            .frame(maxWidth: .infinity, minHeight: DS.Size.sectionHeader)
            .background(dropTargeted ? DS.Palette.selected : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.hairline, style: StrokeStyle(lineWidth: DS.Stroke.ring, dash: [DS.Space.s1])))
            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s0)
    }
}

/// The undo line after a section was deleted: names the section and how many bots went to Unassigned.
struct SectionUndoLine: View {
    let deletion: BotSectionsModel.Deletion
    let onUndo: () -> Void
    let onDismiss: () -> Void

    static func text(_ d: BotSectionsModel.Deletion) -> String {
        let n = d.members.count
        return n == 0 ? "Deleted “\(d.section.name)”"
            : "Deleted “\(d.section.name)”: \(n) \(n == 1 ? "bot" : "bots") moved to Unassigned"
    }

    /// How long the line stays before it dismisses itself.
    static let lifetime: TimeInterval = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(Self.text(deletion)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onUndo) { Text("Undo").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink) }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo deleting \(deletion.section.name)")
        }
        .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
        .task(id: deletion.token) {
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            if !Task.isCancelled { onDismiss() }
        }
    }
}
