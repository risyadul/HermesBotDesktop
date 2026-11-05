import AppKit
import HermesGatewayKit

/// A7 New Bot, Hermes Desktop's New Bot dialog (`create-dialog.tsx`, `BotCreate`): name, title, description,
/// avatar (A10 picker), and under Advanced clone from (a profile, or fresh), model and provider (the A9 picker),
/// SOUL, share keys, skip bundled skills. Create runs, each step reported:
/// 1. `profiles.list` again: the name must still be free; its roster feeds the SOUL's teammate list.
/// 2. `profiles.create` with Desktop's payload. If that fails, the roster is read once more: a profile that exists
///    after all is reported as created (with the error), never left unmentioned.
/// 3. The look (`ui_meta["hermes-bots"]`: title, shape, colour, imageKind, created), then the picture
///    (`profiles.set_asset`: an uploaded or generated 256 px PNG, a pet frame, or the shape's 160 px face).
/// 4. `setup.runtime_check {profile}`: only `ok: false` means "needs a model" (no intro then).
/// With nothing to report the sheet closes and the bot's Bot Chat opens, sending the intro when "Say hello" is
/// on (Desktop's default). Otherwise the sheet shows what happened, with Set Up Model… and Open Bot Chat.
@MainActor
final class BotCreateModel: ObservableObject, Identifiable, BotModelChoosing {
    enum Phase: Equatable {
        case editing
        case working(String)
        case created(Outcome)
    }

    struct Outcome: Equatable {
        let name: String
        let path: String
        /// Steps after `profiles.create` that did not work (the profile exists).
        let warnings: [String]
        /// `setup.runtime_check` said no model can be served: its reason (may be empty).
        let needsModel: String?
    }

    nonisolated let id = "create"
    private let service: any BotProfileService
    /// The profiles the app lists now (taken names, clone sources).
    let roster: [Bot]

    var onClose: () -> Void = {}
    /// The profile exists: the app re-lists the roster and shows the saved picture (nil = none).
    var onCreated: (_ name: String, _ avatar: Data?) async -> Void = { _, _ in }
    /// Close the sheet and open the bot's Bot Chat, sending the intro when `kickoff`.
    var onOpen: (_ name: String, _ kickoff: Bool) -> Void = { _, _ in }
    /// Close the sheet and open the Edit sheet's model settings for the new bot.
    var onEditModel: (_ name: String) -> Void = { _ in }

    // MARK: fields
    @Published var name = ""
    @Published var title = ""
    @Published var description = ""
    @Published private(set) var avatar: BotAvatarEdit = .unchanged
    @Published private(set) var avatarError: String?
    @Published var avatarPickerOpen = false
    @Published var advancedOpen = false
    /// nil = a fresh profile with the bundled skills (Desktop's `__none__`); Desktop starts on `default`.
    @Published var cloneFrom: String? = "default"
    @Published var provider = ""
    @Published var model = ""
    @Published var manualModelEntry: Bool?
    @Published private(set) var providers: [BotProfileAPI.ModelProvider] = []
    @Published private(set) var loadingModels = false
    @Published var soul = ""
    @Published var shareKeys = true
    @Published var skipBundledSkills = false
    /// Desktop always sends the intro on New Bot; here it can be turned off.
    @Published var sayHello = true

    @Published private(set) var phase: Phase = .editing
    @Published private(set) var error: String?
    private var modelsLoaded = false

    private(set) lazy var picker = BotAvatarPickerModel(
        service: service,
        seed: { [unowned self] in .init(name: slug, title: botTitle, description: description) },
        apply: { [unowned self] in avatar = $0; avatarError = nil },
        monogram: { [unowned self] in avatar = .remove; avatarError = nil })

    init(roster: [Bot], service: any BotProfileService) {
        self.roster = roster
        self.service = service
    }

    // MARK: name

    var slug: String { BotCreate.identity(name: name, title: title).slug }
    var botTitle: String { BotCreate.identity(name: name, title: title).title }
    var isTaken: Bool { roster.contains { $0.name == slug } }

    /// Why the name cannot be used (nil while it is empty or fine).
    var nameProblem: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !BotCreate.isValidName(slug) { return "Use letters or digits for the name." }
        if isTaken { return "A bot named @\(slug) already exists." }
        return nil
    }

    var canCreate: Bool { phase == .editing && BotCreate.isValidName(slug) && !isTaken }

    /// Clone sources: every listed profile (Desktop's roster menu).
    var cloneSources: [String] { roster.map(\.name) }

    // MARK: avatar

    /// The face a new bot gets when the user picks nothing: Desktop's default shape for the name.
    var defaultFace: BotAvatarEdit { .shape(BotLook.defaultShape(for: slug.isEmpty ? "agent" : slug), color: nil) }
    /// What the preview shows and Create saves.
    var effectiveAvatar: BotAvatarEdit { avatar == .unchanged ? defaultFace : avatar }

    func toggleAvatarPicker() {
        avatarPickerOpen.toggle()
        if avatarPickerOpen, case .shape(let s, let c) = effectiveAvatar { picker.showCurrent(shape: s, color: c) }
    }

    func pickAvatar(_ url: URL) {
        do {
            avatar = .set(try ProfileAvatar.normalize(try ProfileAvatar.read(url)))
            avatarError = nil
        } catch {
            avatarError = BotManagementText.describe(error)
        }
    }

    func resetAvatar() { avatar = .unchanged; avatarError = nil }

    // MARK: advanced

    func toggleAdvanced() {
        advancedOpen.toggle()
        if advancedOpen { loadModels() }
    }

    /// `model.options` in the clone source's scope (the new profile does not exist yet).
    func loadModels() {
        guard !modelsLoaded else { return }
        modelsLoaded = true
        loadingModels = true
        let service = self.service, scope = cloneFrom ?? "default"
        Task { [weak self] in
            let options = (try? await service.modelOptions(scope)) ?? []
            self?.providers = options.filter { !$0.slug.isEmpty }
            self?.loadingModels = false
        }
    }

    // MARK: create

    func cancel() { if !isWorking { onClose() } }

    var isWorking: Bool { if case .working = phase { return true }; return false }

    func create() async {
        guard canCreate else { return }
        let name = slug, botTitle = botTitle
        error = nil
        let p = provider.trimmingCharacters(in: .whitespacesAndNewlines), m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty != m.isEmpty { return fail("Choose both a provider and a model, or Inherit.") }

        phase = .working("Checking the name…")
        let live: BotProfileAPI.Roster
        do { live = try await service.roster() } catch {
            return fail("Could not read the bot list: \(BotManagementText.describe(error))")
        }
        if live.names.contains(name) { return fail("A bot named @\(name) already exists.") }

        let description = self.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = BotCreate.Request(
            name: name, title: botTitle, description: description, cloneFrom: cloneFrom, shareAuth: shareKeys,
            // Hermes refuses `no_skills` with a clone (a clone copies its source's skills).
            noSkills: cloneFrom == nil && skipBundledSkills,
            soul: BotCreate.soul(name: name, title: botTitle, description: description, custom: soul,
                                 roster: live.teammates, serverInjects: live.injectsProtocol),
            provider: p, model: m)

        phase = .working("Creating @\(name)…")
        var warnings: [String] = []
        var path = ""
        do {
            let created = try await service.create(request)
            path = created.path
            if !created.soulWritten { warnings.append("Hermes did not write the SOUL.") }
            if !p.isEmpty && !created.modelSet { warnings.append("Hermes did not pin the model; the bot inherits the main profile's.") }
        } catch {
            let why = BotManagementText.describe(error)
            // Never leave a profile behind without saying so: did it get created after all?
            guard (try? await service.roster())?.names.contains(name) == true else {
                return fail("Could not create the bot: \(why)")
            }
            warnings.append("Hermes reported an error, but @\(name) was created: \(why)")
        }

        phase = .working("Saving the title and look…")
        let look = effectiveAvatar
        var shape: String?, color: String?
        if case .shape(let s, let c) = look { shape = s; color = c }
        if case .set = look { shape = BotLook.defaultShape(for: name) }
        let patch = BotLook.createPatch(shape: shape, color: color, hasImage: { if case .set = look { return true }; return false }(),
                                        title: botTitle, created: Date())
        do {
            switch try await service.saveLook(name, patch) {
            case .persisted, .unsupported: break
            case .failed, .notFound: warnings.append("The title and look were not saved. Set them with Edit….")
            }
        } catch {
            warnings.append("The title and look were not saved: \(BotManagementText.describe(error))")
        }

        var picture: Data?
        switch look {
        case .set(let data): picture = data
        case .shape(let s, let c): picture = BotLook.facePNG(shape: s, color: c, name: name)
        case .remove, .unchanged: break
        }
        if let data = picture {
            phase = .working("Saving the avatar…")
            do { try await service.setAvatar(name, data) } catch {
                picture = nil
                warnings.append("The avatar was not saved: \(BotManagementText.describe(error))")
            }
        }

        phase = .working("Checking that it can reply…")
        var needsModel: String?
        if case .noModel(_, _, let reason) = await service.readiness(name) { needsModel = reason ?? "" }

        await onCreated(name, picture)
        if warnings.isEmpty && needsModel == nil {
            phase = .created(Outcome(name: name, path: path, warnings: [], needsModel: nil))
            onOpen(name, sayHello)
        } else {
            phase = .created(Outcome(name: name, path: path, warnings: warnings, needsModel: needsModel))
        }
    }

    private func fail(_ message: String) {
        error = message
        phase = .editing
    }

    /// Open Bot Chat from the result panel: the intro only when the bot can reply.
    func openCreated() {
        guard case .created(let o) = phase else { return }
        onOpen(o.name, sayHello && o.needsModel == nil)
    }

    func editModel() {
        guard case .created(let o) = phase else { return }
        onEditModel(o.name)
    }
}
