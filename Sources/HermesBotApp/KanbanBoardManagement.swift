import AppKit
import HermesGatewayKit
import SwiftUI
import UniformTypeIdentifiers

// K7: board management (New / Rename / Delete = archive / Export / Import) and the orchestration settings
// sheet, from the board header's Board menu. The calls go through `KanbanService` (KanbanBoardsAPI.swift).
// Like Desktop, a deleted board is archived (recoverable) and `default` is never offered; deleting the
// server's current board warns first (Hermes then falls back to `default` for the CLI). Export / Import pass a
// file path the backend reads or writes itself (Desktop transfer.ts: the backend is on this Mac).

/// A one-line result of a board action, shown under the board header until dismissed or replaced.
struct KanbanBoardNote: Equatable {
    let text: String
    let isError: Bool
}

struct KanbanBoardFailure: Error, Equatable {
    let message: String
}

enum KanbanBoardRules {
    /// The server refuses to remove `default` (`remove_board`).
    static func canArchive(_ slug: String) -> Bool { slug != KanbanAPI.defaultBoard }

    static func archiveTitle(_ name: String) -> String { "Delete the board “\(name)”?" }

    /// The confirmation's words: archived, not erased; plus a warning for the server's current board.
    static func archiveMessage(_ summary: KanbanBoardSummary?) -> String {
        var text = "The board is archived, not erased: its cards and attachments stay on disk in Hermes and can be restored."
        if summary?.isCurrent == true {
            text += " It is Hermes' current board (the one the CLI and slash commands use); Hermes switches back to the default board."
        }
        return text
    }

    /// Why a new board name cannot be used, or nil. The server answers an existing slug with that board
    /// (idempotent create), so a taken slug is refused here instead of quietly opening the old board.
    static func newNameProblem(_ name: String, existing: [KanbanBoardSummary]) -> String? {
        let slug = KanbanAPI.boardSlug(fromName: name)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if slug.isEmpty { return "Use at least one letter or digit." }
        if existing.contains(where: { $0.slug == slug }) { return "A board with the id “\(slug)” already exists." }
        return nil
    }

    /// `<slug>.tar.gz`, the name Desktop's save panel proposes.
    static func exportFileName(_ slug: String) -> String { "\(slug).tar.gz" }
}

extension KanbanHub {
    func dismissBoardNote() { boardNote = nil }

    /// `POST /boards`; the new slug on success (the caller opens it).
    func createBoard(name: String) async -> Result<String, KanbanBoardFailure> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = KanbanBoardRules.newNameProblem(name, existing: boards) {
            return .failure(KanbanBoardFailure(message: problem.isEmpty ? "Give the board a name." : problem))
        }
        guard let api else { return .failure(KanbanBoardFailure(message: "Not connected to Hermes.")) }
        let slug = KanbanAPI.boardSlug(fromName: name)
        do {
            let made = try await api.createBoard(slug: slug, name: name)
            await refreshBoards()
            boardNote = KanbanBoardNote(text: "Created the board “\(name)”.", isError: false)
            return .success(made?.slug ?? slug)
        } catch {
            return .failure(KanbanBoardFailure(message: KanbanBoardModel.describe(error)))
        }
    }

    /// `PATCH /boards/{slug} {name}`; nil on success, else the reason.
    func renameBoard(_ slug: String, to name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the board a name." }
        guard let api else { return "Not connected to Hermes." }
        do {
            _ = try await api.renameBoard(slug, name: name)
            await refreshBoards()
            boardNote = nil
            return nil
        } catch {
            return KanbanBoardModel.describe(error)
        }
    }

    /// `DELETE /boards/{slug}` (archive). Refused before sending for `default`. nil on success.
    func archiveBoard(_ slug: String) async -> String? {
        guard KanbanBoardRules.canArchive(slug) else { return "The default board can't be deleted." }
        guard let api else { return "Not connected to Hermes." }
        let name = summary(slug)?.name ?? slug
        do {
            let r = try await api.archiveBoard(slug)
            await refreshBoards()  // drops the board's model; the selection follows (onBoardsListed)
            boardNote = KanbanBoardNote(text: "Archived the board “\(name)”" + (r.newPath.map { " to \($0)." } ?? "."), isError: false)
            return nil
        } catch {
            let text = "Delete “\(name)” failed: \(KanbanBoardModel.describe(error))"
            boardNote = KanbanBoardNote(text: text, isError: true)
            return text
        }
    }

    /// `POST /boards/{slug}/export {output}`: the backend writes the archive to `file`.
    @discardableResult
    func exportBoard(_ slug: String, to file: URL) async -> Result<KanbanBoardExport, KanbanBoardFailure> {
        guard let api else { return .failure(KanbanBoardFailure(message: "Not connected to Hermes.")) }
        do {
            let r = try await api.exportBoard(slug, to: file.path)
            let size = r.size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file)))" : ""
            boardNote = KanbanBoardNote(text: "Exported to \(r.archive.isEmpty ? file.path : r.archive)\(size).", isError: false)
            return .success(r)
        } catch {
            let text = "Export failed: \(KanbanBoardModel.describe(error))"
            boardNote = KanbanBoardNote(text: text, isError: true)
            return .failure(KanbanBoardFailure(message: text))
        }
    }

    /// `POST /boards/import {archive}`: the archive becomes a new board; its slug on success.
    @discardableResult
    func importBoard(from file: URL) async -> Result<String, KanbanBoardFailure> {
        guard let api else { return .failure(KanbanBoardFailure(message: "Not connected to Hermes.")) }
        do {
            let r = try await api.importBoard(archive: file.path)
            await refreshBoards()
            var text = "Imported “\(r.name.isEmpty ? r.board : r.name)”."
            if r.renamed { text += " That id was taken, so it is “\(r.board)”." }
            if !r.warnings.isEmpty { text += " " + r.warnings.joined(separator: " ") }
            boardNote = KanbanBoardNote(text: text, isError: false)
            return .success(r.board)
        } catch {
            let text = "Import failed: \(KanbanBoardModel.describe(error))"
            boardNote = KanbanBoardNote(text: text, isError: true)
            return .failure(KanbanBoardFailure(message: text))
        }
    }
}

// MARK: - orchestration settings

/// The orchestration sheet's state: `GET /orchestration` + `GET /profiles`, and `PUT /orchestration` per change.
@MainActor
final class KanbanOrchestrationModel: ObservableObject {
    @Published private(set) var settings: KanbanOrchestration?
    @Published private(set) var profiles: [KanbanProfile] = []
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    let api: any KanbanService

    init(api: any KanbanService) { self.api = api }

    func load() async {
        do {
            async let s = api.orchestration()
            async let p = api.profiles()
            let (settings, profiles) = try await (s, p)
            self.settings = settings
            self.profiles = profiles
            error = nil
        } catch {
            self.error = "Settings not loaded: \(KanbanBoardModel.describe(error))"
        }
    }

    /// Saves one change; the server answers the resolved settings. False (settings unchanged) on failure.
    @discardableResult
    func save(_ patch: KanbanOrchestrationPatch) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            settings = try await api.setOrchestration(patch)
            error = nil
            return true
        } catch {
            self.error = "Not saved: \(KanbanBoardModel.describe(error))"
            return false
        }
    }

    /// Profile names for a picker: the roster, plus a configured name the roster no longer lists.
    static func choices(_ profiles: [KanbanProfile], current: String) -> [String] {
        var names = profiles.map(\.name)
        if !current.isEmpty, !names.contains(current) { names.append(current) }
        return names
    }
}

struct KanbanOrchestrationSheet: View {
    @StateObject private var model: KanbanOrchestrationModel
    let onClose: () -> Void

    init(api: any KanbanService, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: KanbanOrchestrationModel(api: api))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Orchestration settings").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            Text("How Hermes splits triage cards and who gets cards nobody picked. Saved to Hermes' config for every board.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let s = model.settings {
                profilePicker("Orchestrator profile", value: s.orchestratorProfile, resolved: s.resolvedOrchestratorProfile,
                              help: "The bot that plans decomposed work. Default: the card's assignee, else the active profile.") {
                    KanbanOrchestrationPatch(orchestratorProfile: $0)
                }
                profilePicker("Default assignee", value: s.defaultAssignee, resolved: s.resolvedDefaultAssignee,
                              help: "Gets subtasks the decomposer could not route to a bot.") {
                    KanbanOrchestrationPatch(defaultAssignee: $0)
                }
                toggle("Decompose new triage cards automatically", isOn: s.autoDecompose,
                       help: "The dispatcher splits triage cards into subtasks on its own.") {
                    KanbanOrchestrationPatch(autoDecompose: $0)
                }
                toggle("Queue subtasks right away", isOn: s.autoPromoteChildren,
                       help: "Off: subtasks wait in Todo for you to review them first.") {
                    KanbanOrchestrationPatch(autoPromoteChildren: $0)
                }
            } else if model.error == nil {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Loading settings…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                if model.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .task { await model.load() }
    }

    private func profilePicker(_ label: String, value: String, resolved: String, help: String,
                               patch: @escaping (String) -> KanbanOrchestrationPatch) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
            Picker(label, selection: Binding(get: { value }, set: { new in Task { await model.save(patch(new)) } })) {
                Text(value.isEmpty ? "Default (\(resolved))" : "Default").tag("")
                ForEach(KanbanOrchestrationModel.choices(model.profiles, current: value), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel(label)
            .disabled(model.saving)
            Text(help).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle(_ label: String, isOn: Bool, help: String, patch: @escaping (Bool) -> KanbanOrchestrationPatch) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s0) {
            Toggle(label, isOn: Binding(get: { isOn }, set: { new in Task { await model.save(patch(new)) } }))
                .accessibilityLabel(label)
                .disabled(model.saving)
            Text(help).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - board name sheet (New Board, Rename)

struct KanbanBoardNameSheet: View {
    enum Mode: Equatable { case create, rename(slug: String) }
    let mode: Mode
    let initialName: String
    let existing: [KanbanBoardSummary]
    /// Returns an error text, or nil when done.
    let onSave: (String) async -> String?
    let onClose: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    private var problem: String? {
        switch mode {
        case .create: return KanbanBoardRules.newNameProblem(name, existing: existing)
        case .rename: return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(mode == .create ? "New board" : "Rename board").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                TextField("Board name", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
                switch mode {
                case .create:
                    let slug = KanbanAPI.boardSlug(fromName: name)
                    if let p = problem, !p.isEmpty {
                        Text(p).font(DS.Typeface.caption).foregroundStyle(DS.Palette.danger)
                    } else if !slug.isEmpty {
                        Text("Id: \(slug)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    }
                case .rename(let slug):
                    Text("The id stays “\(slug)”.").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(mode == .create ? "Create Board" : "Rename") { save() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || problem != nil)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($focused, true)
        .onAppear { name = initialName; focused = true }
    }

    private func save() {
        guard !saving, problem == nil else { return }
        saving = true
        Task {
            error = await onSave(name)
            saving = false
            if error == nil { onClose() }
        }
    }
}

// MARK: - board menu

/// The board header's Board menu (trailing, `ellipsis.circle` + "Board"): New, Rename, Export, Import,
/// Orchestration Settings, Delete.
struct KanbanBoardMenu: View {
    @ObservedObject var hub: KanbanHub
    let slug: String
    let onNew: () -> Void
    let onRename: () -> Void
    let onOrchestration: () -> Void
    let onDelete: () -> Void
    let onSelectBoard: (String) -> Void

    var body: some View {
        Menu {
            Button("New Board…", action: onNew)
            Button("Rename Board…", action: onRename)
            Divider()
            Button("Export Board…") { export() }
            Button("Import Board…") { importArchive() }
            Divider()
            Button("Orchestration Settings…", action: onOrchestration)
            Divider()
            Button("Delete Board…", role: .destructive, action: onDelete)
                .disabled(!KanbanBoardRules.canArchive(slug))
        } label: {
            // Titled like the Room and Bot pane menus: the bare symbol at header size read as ⊖ ("remove") in the
            // live UI test 2026-11-06, round 5.
            Label("Board", systemImage: "ellipsis.circle")
        }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Board actions").help("Board actions")
    }

    private static var archiveTypes: [UTType] {
        [UTType.gzip, UTType(filenameExtension: "tgz")].compactMap { $0 }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Board"
        panel.message = "Hermes writes the board, its cards and attachments into one archive."
        panel.nameFieldStringValue = KanbanBoardRules.exportFileName(slug)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await hub.exportBoard(slug, to: url) }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.title = "Import Board"
        panel.message = "Choose a board archive exported from Hermes. It becomes a new board."
        panel.allowedContentTypes = Self.archiveTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if case .success(let slug) = await hub.importBoard(from: url) { onSelectBoard(slug) }
        }
    }
}
