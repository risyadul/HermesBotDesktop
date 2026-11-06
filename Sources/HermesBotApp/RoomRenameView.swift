import HermesGatewayKit
import SwiftUI

// MARK: - rename sheet

/// Room menu → Rename… (`groups.rename`). Rename hands the name to `RoomModel.rename`, which shows it at
/// once and reports a failure in the note bar, so the sheet closes right away.
struct RenameRoomView: View {
    let current: String
    /// Returns false when the model refused the name (nothing was sent).
    let onRename: (String) -> Bool
    /// Presented by `motionSheet`, so `\.dismiss` would not reach it (CreateRoomView.swift).
    let onClose: () -> Void
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(current: String, onRename: @escaping (String) -> Bool, onClose: @escaping () -> Void) {
        self.current = current; self.onRename = onRename; self.onClose = onClose
        _name = State(initialValue: current)
    }

    static func canRename(_ name: String, current: String) -> Bool {
        guard let n = RoomSummary.normalizedName(name) else { return false }
        return n != current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Rename group chat").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden()
                    .focused($nameFocused)
                    .onSubmit(rename)
                Text("Everyone in the room sees the new name. Bots use it from their next turn.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canRename(name, current: current))
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
    }

    private func rename() {
        guard Self.canRename(name, current: current), onRename(name) else { return }
        onClose()
    }
}
