import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - create sheet

struct CreateRoomView: View {
    let bots: [Bot]
    let onCreate: (String, [RoomMember]) async -> String?
    /// Closes the sheet (Cancel, Escape, or a successful create). The sheet is presented by
    /// `motionSheet`, not SwiftUI, so `\.dismiss` would not reach it.
    let onClose: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var name = "Group chat"
    @State private var picked: Set<String> = []
    @State private var error: String?
    @State private var creating = false
    /// The Name field takes focus on open, as it did under SwiftUI's `.sheet`.
    @FocusState private var nameFocused: Bool

    private var eligible: [(Bot, RoomMember)] { bots.compactMap { b in RoomMember.forBot(b).map { (b, $0) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("New group chat").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden()
                    .focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Members").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s2), GridItem(.flexible(), spacing: DS.Space.s2)],
                          spacing: DS.Space.s2) {
                    ForEach(eligible, id: \.0.name) { bot, _ in memberToggle(bot) }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s2) {
                Text("\(picked.count) of 2 to 6 bots").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    creating = true
                    Task {
                        let members = eligible.filter { picked.contains($0.0.name) }.map(\.1)
                        error = await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), members)
                        creating = false
                        if error == nil { onClose() }
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !(2...6).contains(picked.count) || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
    }

    private func memberToggle(_ bot: Bot) -> some View {
        let on = picked.contains(bot.name)
        let id = avatars.identity(profile: bot.name, title: bot.title)
        return Toggle(isOn: Binding(get: { on }, set: { if $0 { picked.insert(bot.name) } else { picked.remove(bot.name) } })) {
            HStack(spacing: DS.Space.s2) {
                AvatarView(identity: id, size: DS.Size.avatarSuggestion)
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    Text("@\(bot.name)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, DS.Space.s2).frame(maxWidth: .infinity, minHeight: DS.Size.memberToggleHeight, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(on ? id.color : DS.Palette.hairline, lineWidth: on ? DS.Stroke.selectedToggle : DS.Stroke.hairline))
    }
}
