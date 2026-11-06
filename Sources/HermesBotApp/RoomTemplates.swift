import AppKit
import HermesGatewayKit
import SwiftUI

// D13: room templates. "Save as Template…" (a room's sidebar menu, or File → Save Group Chat as Template…)
// keeps the room's member set (bot profile names) and an opening prompt under a name; File → New Group Chat from
// Template opens New Group Chat prefilled with them (`CreateRoomPrefill`) and, once the room is created, puts the
// prompt in its composer. Nothing is ever sent by itself. Templates live in this Mac's UserDefaults.

struct RoomTemplate: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    /// Bot (profile) names, in the room's order.
    let members: [String]
    /// Put into the new room's composer; may be empty.
    let prompt: String
}

@MainActor
final class RoomTemplateStore: ObservableObject {
    static let key = "hba.roomTemplates"
    static let maxTemplates = 50

    enum SaveError: Error, Equatable {
        case name, members, promptTooLong

        var message: String {
            switch self {
            case .name: return "Give the template a name (up to 64 characters)."
            case .members: return "A template needs 2 to 6 bots."
            case .promptTooLong: return "The opening prompt is too long for a group chat message."
            }
        }
    }

    @Published private(set) var templates: [RoomTemplate]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        templates = data.flatMap { try? JSONDecoder().decode([RoomTemplate].self, from: $0) } ?? []
    }

    /// Saves a template; one with the same name (ignoring case) is replaced. Sorted by name.
    @discardableResult
    func save(name raw: String, members: [String], prompt: String) -> Result<RoomTemplate, SaveError> {
        guard let name = RoomSummary.normalizedName(raw) else { return .failure(.name) }
        var unique: [String] = []
        for m in members where !unique.contains(m) { unique.append(m) }
        guard (2...6).contains(unique.count) else { return .failure(.members) }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= RoomComposer.maxTextBytes else { return .failure(.promptTooLong) }
        let template = RoomTemplate(id: UUID(), name: name, members: unique, prompt: text)
        var next = templates.filter { $0.name.lowercased() != name.lowercased() }
        next.append(template)
        next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        templates = Array(next.prefix(Self.maxTemplates))
        persist()
        return .success(template)
    }

    func remove(_ id: UUID) {
        guard templates.contains(where: { $0.id == id }) else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) { defaults.set(data, forKey: Self.key) }
    }

    /// What New Group Chat starts with: the template's name, the members that are still bots here, the prompt.
    nonisolated static func prefill(_ template: RoomTemplate, bots: [Bot]) -> CreateRoomPrefill {
        let present = Set(bots.map(\.name))
        return CreateRoomPrefill(name: template.name, members: template.members.filter(present.contains),
                                 draft: template.prompt)
    }

    /// "Alpha, Beta and 2 more" (bot titles where known).
    nonisolated static func memberSummary(_ template: RoomTemplate, bots: [Bot]) -> String {
        let titles = template.members.map { name in bots.first { $0.name == name }?.title ?? "@\(name)" }
        guard titles.count > 2 else { return titles.joined(separator: " and ") }
        return "\(titles[0]), \(titles[1]) and \(titles.count - 2) more"
    }
}

// MARK: - AppModel

extension AppModel {
    /// New Group Chat can open (connected, Group Chat available, two bots).
    var canCreateRoom: Bool { backend != nil && groupsAvailable && bots.count >= 2 }

    /// File → New Group Chat from Template → <name>.
    func newRoom(from template: RoomTemplate) {
        guard canCreateRoom, !showCreateRoom else { return }
        createRoomPrefill = RoomTemplateStore.prefill(template, bots: bots)
        showCreateRoom = true
    }

    /// "Save as Template…" for a listed room.
    func saveTemplate(from roomId: String) {
        guard let room = rooms.first(where: { $0.roomId == roomId }) else { return }
        templateSource = room
    }

    var selectedRoom: RoomSummary? {
        guard case .room(let id)? = selection else { return nil }
        return rooms.first { $0.roomId == id }
    }
}

// MARK: - save sheet

struct SaveRoomTemplateView: View {
    let room: RoomSummary
    let onSave: (_ name: String, _ prompt: String) -> String?
    let onClose: () -> Void
    @State private var name: String
    @State private var prompt = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(room: RoomSummary, onSave: @escaping (String, String) -> String?, onClose: @escaping () -> Void) {
        self.room = room; self.onSave = onSave; self.onClose = onClose
        _name = State(initialValue: room.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Save as template").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            Text("Keeps these bots and an opening prompt. File → New Group Chat from Template starts a new group chat with them and puts the prompt in its composer; you still send it.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden().focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Members").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                Text(room.members.map { "\($0.title) (@\($0.handle))" }.joined(separator: ", "))
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("Opening prompt").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextEditor(text: $prompt)
                    .font(DS.Typeface.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Size.fieldInset)
                    .frame(height: DS.Size.templatePromptHeight)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                    .accessibilityLabel("Opening prompt")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save Template") {
                    error = onSave(name, prompt)
                    if error == nil { onClose() }
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(RoomSummary.normalizedName(name) == nil)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .onAppear { nameFocused = true }
    }
}

/// File menu: New Group Chat from Template (and Delete Template), Save Group Chat as Template….
struct RoomTemplateCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: RoomTemplateStore

    var body: some View {
        Menu("New Group Chat from Template") {
            ForEach(store.templates) { t in
                Button(t.name) { model.newRoom(from: t) }
            }
            if !store.templates.isEmpty {
                Divider()
                Menu("Delete Template") {
                    ForEach(store.templates) { t in Button(t.name) { store.remove(t.id) } }
                }
            }
        }
        .disabled(store.templates.isEmpty || !model.canCreateRoom || model.showCreateRoom)
        Button("Save Group Chat as Template…") {
            if let room = model.selectedRoom { model.saveTemplate(from: room.roomId) }
        }
        .disabled(model.selectedRoom == nil || model.templateSource != nil)
    }
}

extension DS.Size {
    /// The opening prompt editor in Save as Template (about five lines).
    static let templatePromptHeight: CGFloat = 96
}
