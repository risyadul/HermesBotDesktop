import AppKit
import HermesGatewayKit

/// The Edit sheet for one bot (A8 title / description / avatar, A9 advanced settings), modelled on Hermes
/// Desktop's Edit Profile dialog (`edit-profile-dialog.tsx`, `profile-config.tsx`, `model-picker.tsx`):
/// - Only fields that differ from what the sheet opened with are written (a value seeded minutes ago is not
///   an edit: sending it would undo what another app wrote since).
/// - Title: `ui_meta["hermes-bots"].title` with Desktop's compare-and-swap write. Description, SOUL, model,
///   skills, toolsets and MCP servers: one `profiles.configure` whose `applied` map reports each section.
///   Avatar: a 256 px PNG with `profiles.set_asset` (or `clear`). "Inherit" model: `config unset model`.
/// - Each field reports its own failure; saved fields become the new baseline, so Save again retries only
///   what failed. The sheet closes once everything saved.
/// - A guarded (expensive / data-policy) model answers `confirm_required`: nothing is written until the user
///   confirms, then only the model section is resent with `confirm_expensive_model: true`.
/// - An edited SOUL keeps the agent messaging protocol section (`SoulProtocol.ensure`, Desktop's `soul.ts`).
/// - A10 avatar: Desktop's `editedLook` writes the look with it (`imageKind`, `custom`, and for a shape face `shape`
///   and `color`), then the picture (a shape face is pushed as Desktop's 160 px face raster).
/// - A13 Find Skills and A14 MCP server setup act on the profile at once (as in Desktop), not on Save; what they add
///   joins the lists as already saved.
@MainActor
final class BotEditorModel: ObservableObject, Identifiable, BotModelChoosing {
    enum Field: Hashable, CaseIterable { case title, description, avatar, model, soul, skills, toolsets, mcp }
    typealias AvatarEdit = BotAvatarEdit
    enum AdvancedPhase: Equatable { case idle, loading, loaded, failed(String) }
    struct ModelConfirm: Equatable { let message: String; let provider: String; let model: String }

    nonisolated var id: String { bot.name }
    nonisolated let bot: Bot
    private let service: any BotProfileService
    /// The sheet closes; `changed` = something was saved (the app re-lists the roster).
    var onClose: (_ changed: Bool) -> Void = { _ in }
    /// A new avatar was saved (nil = removed), so every tile shows it at once.
    var onAvatarSaved: (Data?) -> Void = { _ in }

    // MARK: basics
    @Published var title: String
    @Published var description: String
    @Published private(set) var avatar: AvatarEdit = .unchanged
    /// The profile had an avatar image when the sheet opened.
    let hadAvatar: Bool
    private(set) var openedTitle: String
    private(set) var openedDescription: String

    // MARK: advanced
    @Published var advancedOpen = false
    @Published private(set) var advancedPhase: AdvancedPhase = .idle
    @Published private(set) var providers: [BotProfileAPI.ModelProvider] = []
    @Published private(set) var loadingModels = false
    /// The user chose free-text provider/model entry; nil = follow the catalog (Desktop's `manualEntry`).
    @Published var manualModelEntry: Bool?
    @Published var provider = ""
    @Published var model = ""
    @Published var soul = ""
    @Published var skills: [BotProfileAPI.Capability] = []
    @Published var toolsets: [BotProfileAPI.Capability] = []
    @Published var mcpServers: [BotProfileAPI.Capability] = []
    @Published var skillFilter = ""
    private var loaded = BotProfileAPI.Snapshot()
    private var teammates: [SoulProtocol.Teammate] = []
    private var serverInjectsProtocol = false

    // MARK: A10 / A13 / A14
    /// The avatar picker is open (the sheet scrolls then).
    @Published var avatarPickerOpen = false
    /// The Find Skills panel is open.
    @Published var skillsFinderOpen = false
    private(set) lazy var picker = BotAvatarPickerModel(
        service: service,
        seed: { [unowned self] in .init(name: bot.name, title: title, description: description) },
        apply: { [unowned self] in stageAvatar($0) },
        monogram: { [unowned self] in removeAvatar() })
    private(set) lazy var skillsFinder = BotSkillsFinderModel(profile: bot.name, service: service) { [weak self] _ in
        await self?.refreshSkills()
    }
    private(set) lazy var mcp = BotMcpModel(profile: bot.name, service: service) { [weak self] servers in
        self?.mcpListed(servers)
    }
    private var lookRequested = false

    // MARK: save state
    @Published private(set) var errors: [Field: String] = [:]
    @Published private(set) var saving = false
    @Published var pendingConfirm: ModelConfirm?
    /// Something was saved during this sheet's life (also when a later field failed).
    private(set) var changedSomething = false

    init(bot: Bot, service: any BotProfileService, hadAvatar: Bool) {
        self.bot = bot
        self.service = service
        self.hadAvatar = hadAvatar
        openedTitle = bot.metaTitle ?? ""
        openedDescription = bot.description ?? ""
        title = openedTitle
        description = openedDescription
    }

    /// Opens or closes the avatar picker; the first open reads the bot's current shape and colour from `ui_meta`.
    func toggleAvatarPicker() {
        avatarPickerOpen.toggle()
        guard avatarPickerOpen, !lookRequested else { return }
        lookRequested = true
        let service = self.service, name = bot.name
        Task { [weak self] in
            guard let row = try? await service.roster().row(name) else { return }
            let ns = row["ui_meta"]?[BotMetaSync.namespace]
            self?.picker.showCurrent(shape: ns?["shape"]?.string, color: ns?["color"]?.string)
        }
    }

    /// The Title field's placeholder while no Bot Mode title is set: the name the bot shows now, the profile's
    /// `display_name` or else its name. `profiles.list` sends `display_name: ""` for a profile without one, and
    /// that empty prompt left the field blank (live UI test 2026-11-06, round 2).
    var titlePlaceholder: String { Self.titlePlaceholder(bot) }

    nonisolated static func titlePlaceholder(_ bot: Bot) -> String {
        let display = bot.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return display.isEmpty ? bot.name : display
    }

    // MARK: dirty fields

    var dirtyFields: Set<Field> {
        var d: Set<Field> = []
        if trimmed(title) != trimmed(openedTitle) { d.insert(.title) }
        if trimmed(description) != trimmed(openedDescription) { d.insert(.description) }
        if avatar != .unchanged { d.insert(.avatar) }
        guard advancedPhase == .loaded else { return d }
        if trimmed(provider) != loaded.provider || trimmed(model) != loaded.model { d.insert(.model) }
        if soul != loaded.soul { d.insert(.soul) }
        if Self.enabled(skills) != Self.enabled(loaded.skills) { d.insert(.skills) }
        if Self.enabled(toolsets) != Self.enabled(loaded.toolsets) { d.insert(.toolsets) }
        if Self.enabled(mcpServers) != Self.enabled(loaded.mcpServers) { d.insert(.mcp) }
        return d
    }

    var canSave: Bool { !saving && pendingConfirm == nil && !dirtyFields.isEmpty }

    private static func enabled(_ c: [BotProfileAPI.Capability]) -> Set<String> { Set(c.filter(\.enabled).map(\.name)) }
    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: avatar

    /// A picked file: ≤ 15 MB, PNG or JPEG, cropped and scaled to 256 px. Nothing is uploaded until Save.
    func pickAvatar(_ url: URL) {
        do {
            avatar = .set(try ProfileAvatar.normalize(try ProfileAvatar.read(url)))
            errors[.avatar] = nil
        } catch {
            errors[.avatar] = BotManagementText.describe(error)
        }
    }

    func removeAvatar() { avatar = hadAvatar ? .remove : .unchanged; errors[.avatar] = nil }
    func keepAvatar() { avatar = .unchanged; errors[.avatar] = nil }
    /// A pick from the avatar picker (a shape face, a generated image or a pet).
    func stageAvatar(_ edit: AvatarEdit) { avatar = edit; errors[.avatar] = nil }

    /// What the preview tile shows: the staged image or face, none (monogram), or the current one.
    var avatarPreview: NSImage? {
        switch avatar {
        case .set(let data): return NSImage(data: data)
        case .shape(let s, let color):
            return BotLook.render(shape: s, color: color, name: bot.name)
                .map { NSImage(cgImage: $0, size: NSSize(width: BotLook.faceEdge, height: BotLook.faceEdge)) }
        case .unchanged, .remove: return nil
        }
    }

    var showsAvatarImage: Bool {
        switch avatar {
        case .set, .shape: return true
        case .remove: return false
        case .unchanged: return hadAvatar
        }
    }

    // MARK: advanced: load

    func toggleAdvanced() {
        advancedOpen.toggle()
        if advancedOpen { loadAdvanced() }
    }

    /// `profiles.describe` + `profiles.list` (teammates and `bot_mode_protocol` for the SOUL section) once per
    /// sheet; `model.options` separately, so a slow catalog only keeps the model menus waiting.
    func loadAdvanced() {
        switch advancedPhase {
        case .idle, .failed: break
        case .loading, .loaded: return
        }
        advancedPhase = .loading
        let service = self.service, name = bot.name
        Task { [weak self] in
            do {
                async let snapshot = service.describe(name)
                async let roster = service.roster()
                let (s, r) = try await (snapshot, roster)
                self?.loaded(s, roster: r)
            } catch {
                self?.advancedPhase = .failed(BotManagementText.describe(error))
            }
        }
        loadingModels = true
        Task { [weak self] in
            let options = (try? await service.modelOptions(name)) ?? []
            self?.providers = options.filter { !$0.slug.isEmpty }
            self?.loadingModels = false
        }
    }

    private func loaded(_ s: BotProfileAPI.Snapshot, roster: BotProfileAPI.Roster) {
        loaded = s
        provider = s.provider; model = s.model; soul = s.soul
        skills = s.skills; toolsets = s.toolsets; mcpServers = s.mcpServers
        teammates = roster.teammates
        serverInjectsProtocol = roster.injectsProtocol
        advancedPhase = .loaded
        Task { await mcp.load() }
    }

    // MARK: advanced: model (Desktop's ModelPicker rules: `BotModelChoosing`)

    static let inheritTag = BotModelTag.inherit
    static let manualTag = BotModelTag.manual

    // MARK: A13 / A14: what was installed or added joins the lists as saved

    /// After a skill install: `profiles.describe` again; new skills are added (as the backend reports them) without
    /// touching the user's unsaved toggles.
    func refreshSkills() async {
        guard let s = try? await service.describe(bot.name) else { return }
        let have = Set(skills.map(\.name))
        let added = s.skills.filter { !have.contains($0.name) }
        guard !added.isEmpty else { return }
        skills += added
        rebase(skills: loaded.skills + added)
        changedSomething = true
    }

    /// `mcp.servers.list` answered: servers the toggles do not know yet (just added) join them as saved.
    private func mcpListed(_ servers: [MCPServers.Server]) {
        let have = Set(mcpServers.map(\.name))
        let added = servers.filter { !have.contains($0.name) }
            .map { BotProfileAPI.Capability(name: $0.name, enabled: $0.enabled, detail: $0.transport) }
        guard !added.isEmpty else { return }
        mcpServers += added
        rebase(mcp: loaded.mcpServers + added)
        changedSomething = true
    }

    private func rebase(skills: [BotProfileAPI.Capability]? = nil, mcp: [BotProfileAPI.Capability]? = nil) {
        let s = loaded
        loaded = .init(description: s.description, soul: s.soul, provider: s.provider, model: s.model,
                       skills: skills ?? s.skills, toolsets: s.toolsets, mcpServers: mcp ?? s.mcpServers)
    }

    // MARK: advanced: toggles

    func setSkill(_ name: String, _ on: Bool) { set(&skills, name, on) }
    func setToolset(_ name: String, _ on: Bool) { set(&toolsets, name, on) }
    func setMcp(_ name: String, _ on: Bool) { set(&mcpServers, name, on) }

    private func set(_ list: inout [BotProfileAPI.Capability], _ name: String, _ on: Bool) {
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        list[i].enabled = on
    }

    var visibleSkills: [BotProfileAPI.Capability] {
        let q = trimmed(skillFilter).lowercased()
        return q.isEmpty ? skills : skills.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: save

    func save() async {
        guard !saving, pendingConfirm == nil else { return }
        let dirty = dirtyFields
        guard !dirty.isEmpty else { return close() }
        saving = true
        errors = [:]
        if dirty.contains(.title) { await saveTitle() }
        await saveConfigure(dirty)
        if dirty.contains(.avatar) { await saveAvatar() }
        saving = false
        if errors.isEmpty && pendingConfirm == nil { close() }
    }

    func cancel() { close() }

    private func close() {
        mcp.cancelAll()
        onClose(changedSomething)
    }

    private func saveTitle() async {
        let value = trimmed(title)
        do {
            switch try await service.saveTitle(bot.name, value) {
            case .persisted:
                openedTitle = value; title = value
                changedSomething = true
            case .failed: errors[.title] = "Hermes did not save the title (another app may have changed this bot). Try again."
            case .unsupported: errors[.title] = "This Hermes Agent cannot store bot titles. Update Hermes to rename bots."
            case .notFound: errors[.title] = "Hermes no longer lists this bot."
            }
        } catch {
            errors[.title] = BotManagementText.describe(error)
        }
    }

    /// The `profiles.configure` key that reports each section in `applied`.
    private static let appliedKey: [Field: String] = [.description: "description", .soul: "soul", .model: "model",
                                                      .skills: "skills", .toolsets: "toolsets", .mcp: "mcp_servers"]

    private func saveConfigure(_ dirty: Set<Field>) async {
        var changes = BotProfileAPI.Changes()
        var sent: [Field] = []
        var unsetModel = false
        if dirty.contains(.description) { changes.description = trimmed(description); sent.append(.description) }
        if dirty.contains(.soul) {
            changes.soul = SoulProtocol.ensure(soul, name: bot.name, roster: teammates, serverInjects: serverInjectsProtocol)
            sent.append(.soul)
        }
        if dirty.contains(.model) {
            let p = trimmed(provider), m = trimmed(model)
            if !p.isEmpty && !m.isEmpty {
                changes.model = (p, m); sent.append(.model)
            } else if p.isEmpty && m.isEmpty {
                unsetModel = true
            } else {
                errors[.model] = "Choose both a provider and a model, or Inherit."
            }
        }
        if dirty.contains(.skills) { changes.disabledSkills = skills.filter { !$0.enabled }.map(\.name); sent.append(.skills) }
        if dirty.contains(.toolsets) { changes.enabledToolsets = BotProfileAPI.enabledToolsets(toolsets); sent.append(.toolsets) }
        if dirty.contains(.mcp) { changes.enabledMcpServers = mcpServers.filter(\.enabled).map(\.name); sent.append(.mcp) }
        if !changes.isEmpty {
            do {
                let result = try await service.configure(bot.name, changes)
                for field in sent {
                    if field == .model, let message = result.confirmMessage, let pin = changes.model {
                        pendingConfirm = ModelConfirm(message: message, provider: pin.provider, model: pin.model)
                    } else if result.applied[Self.appliedKey[field] ?? ""] == true {
                        accept(field, changes)
                    } else {
                        errors[field] = Self.notSaved(field)
                    }
                }
            } catch {
                let why = BotManagementText.describe(error)
                for field in sent { errors[field] = why }
            }
        }
        if unsetModel {
            do {
                try await service.unsetModel(bot.name)
                accept(.model, changes)
            } catch {
                errors[.model] = "Could not switch to the inherited model: \(BotManagementText.describe(error))"
            }
        }
    }

    /// A saved field becomes the new baseline (Save again sends only what failed).
    private func accept(_ field: Field, _ changes: BotProfileAPI.Changes) {
        changedSomething = true
        let s = loaded
        switch field {
        case .description:
            openedDescription = changes.description ?? openedDescription
            description = openedDescription
        case .soul:
            soul = changes.soul ?? soul
            loaded = .init(description: s.description, soul: soul, provider: s.provider, model: s.model,
                           skills: s.skills, toolsets: s.toolsets, mcpServers: s.mcpServers)
        case .model:
            provider = trimmed(provider); model = trimmed(model)
            loaded = .init(description: s.description, soul: s.soul, provider: provider, model: model,
                           skills: s.skills, toolsets: s.toolsets, mcpServers: s.mcpServers)
        case .skills:
            loaded = .init(description: s.description, soul: s.soul, provider: s.provider, model: s.model,
                           skills: skills, toolsets: s.toolsets, mcpServers: s.mcpServers)
        case .toolsets:
            loaded = .init(description: s.description, soul: s.soul, provider: s.provider, model: s.model,
                           skills: s.skills, toolsets: toolsets, mcpServers: s.mcpServers)
        case .mcp:
            loaded = .init(description: s.description, soul: s.soul, provider: s.provider, model: s.model,
                           skills: s.skills, toolsets: s.toolsets, mcpServers: mcpServers)
        case .title, .avatar: break
        }
    }

    static func notSaved(_ field: Field) -> String {
        switch field {
        case .description: return "Hermes did not save the description."
        case .soul: return "Hermes did not save the SOUL."
        case .model: return "Hermes did not save the model."
        case .skills: return "Hermes did not save the skills."
        case .toolsets: return "Hermes did not save the toolsets."
        case .mcp: return "Hermes did not save the MCP servers."
        case .title: return "Hermes did not save the title."
        case .avatar: return "Hermes did not save the avatar."
        }
    }

    /// Writes the avatar's look fields; false (with the avatar error set) when Hermes did not keep them. An older
    /// gateway that cannot store `ui_meta` is no reason to hold back the picture (Desktop goes on as well).
    private func saveLook(_ patch: BotLook.Patch) async throws -> Bool {
        switch try await service.saveLook(bot.name, patch) {
        case .persisted, .unsupported: return true
        case .failed: errors[.avatar] = "Hermes did not save the avatar (another app may have changed this bot). Try again."
        case .notFound: errors[.avatar] = "Hermes no longer lists this bot."
        }
        return false
    }

    /// The look first (Desktop's `editedLook`), then the picture; both are sent again on Save after a failure.
    private func saveAvatar() async {
        do {
            switch avatar {
            case .unchanged: return
            case .set(let data):
                guard try await saveLook(BotLook.imagePatch(hasImage: true)) else { return }
                try await service.setAvatar(bot.name, data)
                onAvatarSaved(data)
            case .remove:
                guard try await saveLook(BotLook.imagePatch(hasImage: false)) else { return }
                try await service.clearAvatar(bot.name)
                onAvatarSaved(nil)
            case .shape(let s, let color):
                guard let face = BotLook.facePNG(shape: s, color: color, name: bot.name) else {
                    errors[.avatar] = "Could not draw the avatar."
                    return
                }
                guard try await saveLook(BotLook.shapePatch(shape: s, color: color)) else { return }
                try await service.setAvatar(bot.name, face)
                onAvatarSaved(face)
            }
            avatar = .unchanged
            changedSomething = true
        } catch {
            errors[.avatar] = BotManagementText.describe(error)
        }
    }

    // MARK: expensive model confirmation

    /// The user confirmed the guarded model: resend only the model section with `confirm_expensive_model`.
    func confirmModel() async {
        guard let pending = pendingConfirm else { return }
        pendingConfirm = nil
        saving = true
        var changes = BotProfileAPI.Changes()
        changes.model = (pending.provider, pending.model)
        changes.confirmExpensiveModel = true
        do {
            let r = try await service.configure(bot.name, changes)
            if r.applied["model"] == true { accept(.model, changes) } else { errors[.model] = Self.notSaved(.model) }
        } catch {
            errors[.model] = BotManagementText.describe(error)
        }
        saving = false
        if errors.isEmpty { close() }
    }

    /// The user declined: the model is not changed and the sheet stays open.
    func declineModel() {
        pendingConfirm = nil
        errors[.model] = "Model not changed."
    }
}
