import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - create sheet

struct CreateRoomView: View {
    let bots: [Bot]
    /// Change Members (C2.2): the room being replaced. Its name and members are prefilled, members who stay
    /// keep their roster entries, Create needs a different set of bots, and a successful create does not
    /// close the sheet (it moves on to the old room's choice, ChangeMembersSheet).
    var replacing: RoomSummary? = nil
    /// Name and members to start with ("Continue in a New Room" from the Desktop archive).
    var prefill: CreateRoomPrefill? = nil
    let onCreate: (String, [RoomMember]) async -> String?
    /// Closes the sheet (Cancel, Escape, or a successful create). The sheet is presented by
    /// `motionSheet`, not SwiftUI, so `\.dismiss` would not reach it.
    let onClose: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var name: String
    @State private var picked: Set<String>
    @State private var error: String?
    @State private var creating = false
    /// The Name field takes focus on open, as it did under SwiftUI's `.sheet`.
    @FocusState private var nameFocused: Bool

    init(bots: [Bot], replacing: RoomSummary? = nil, prefill: CreateRoomPrefill? = nil,
         onCreate: @escaping (String, [RoomMember]) async -> String?, onClose: @escaping () -> Void) {
        self.bots = bots; self.replacing = replacing; self.prefill = prefill
        self.onCreate = onCreate; self.onClose = onClose
        _name = State(initialValue: replacing?.name ?? "Group chat")
        _picked = State(initialValue: replacing.map { Self.prefill(bots: bots, room: $0) } ?? [])
    }

    private var eligible: [(Bot, RoomMember)] { Self.eligible(bots) }

    nonisolated static func eligible(_ bots: [Bot]) -> [(Bot, RoomMember)] {
        bots.compactMap { b in RoomMember.forBot(b).map { (b, $0) } }
    }

    /// The bots already in `room` (by profile) that can be picked; a member whose profile is gone cannot.
    nonisolated static func prefill(bots: [Bot], room: RoomSummary) -> Set<String> {
        let profiles = Set(room.members.map(\.profile))
        return Set(eligible(bots).map(\.0.name).filter(profiles.contains))
    }

    /// The roster to create, in bot order. Bots already in `replacing` keep their member entry (id, handle,
    /// display name), so the `@handle`s they know still name them.
    nonisolated static func members(bots: [Bot], picked: Set<String>, replacing: RoomSummary?) -> [RoomMember] {
        eligible(bots).filter { picked.contains($0.0.name) }.map { bot, fresh in
            replacing?.members.first { $0.profile == bot.name } ?? fresh
        }
    }

    /// Create is enabled: 2 to 6 bots and a name; when replacing a room, also a different set of bots.
    nonisolated static func canCreate(name: String, picked: Set<String>, replacing: RoomSummary?, bots: [Bot]) -> Bool {
        guard (2...6).contains(picked.count), RoomSummary.normalizedName(name) != nil else { return false }
        guard let replacing else { return true }
        let chosen = Set(members(bots: bots, picked: picked, replacing: replacing).map(\.profile))
        return chosen != Set(replacing.members.map(\.profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(replacing == nil ? "New group chat" : "Change members").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            if replacing != nil {
                Text("Hermes can't change who is in a room, so this starts a new group chat with these bots. Its recent messages are posted there as context (files are not copied). Then you choose what happens to this room.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    // Change Members: the old room's choice must follow a room that is being made.
                    .disabled(creating && replacing != nil)
                Button(replacing == nil ? "Create" : "Create New Room") {
                    creating = true
                    Task {
                        let members = Self.members(bots: bots, picked: picked, replacing: replacing)
                        error = await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), members)
                        creating = false
                        if error == nil && replacing == nil { onClose() }
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !Self.canCreate(name: name, picked: picked, replacing: replacing, bots: bots))
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($nameFocused, true)
        .onAppear {
            nameFocused = true
            if let prefill {
                name = prefill.name
                picked = Set(prefill.members).intersection(eligible.map(\.0.name))
            }
        }
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
