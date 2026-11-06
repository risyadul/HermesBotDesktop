import Foundation
import HermesGatewayKit

/// A11: Duplicate, Desktop's `duplicateBot` (`BotDuplicate`): the sheet shows each step while it runs, then
/// the new bot (with Open) or why it failed. Starts on `start()`; nothing to confirm, a copy changes no
/// existing profile.
@MainActor
final class BotDuplicateModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case running(String)
        case done(BotDuplicate.Result)
        case failed(String)
    }

    nonisolated var id: String { "duplicate:" + source.name }
    nonisolated let source: Bot
    private let service: any BotProfileService
    @Published private(set) var phase: Phase = .running("Finding a free name…")
    /// The copy exists (also when only its look failed): the app re-lists the roster.
    var onCreated: (BotDuplicate.Result) async -> Void = { _ in }
    var onClose: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }
    private var started = false

    init(source: Bot, service: any BotProfileService) {
        self.source = source
        self.service = service
    }

    static func text(_ step: BotDuplicate.Step) -> String {
        switch step {
        case .creating(let name): return "Creating @\(name)…"
        case .copyingLook: return "Copying the title and look…"
        case .copyingAvatar: return "Copying the avatar…"
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let result = try await service.duplicate(source.name, description: source.description ?? "") { [weak self] step in
                await MainActor.run { self?.phase = .running(Self.text(step)) }
            }
            await onCreated(result)
            phase = .done(result)
        } catch {
            phase = .failed(BotManagementText.describe(error))
        }
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }
}

/// A12: Delete, never `default`. The confirmation names the profile path; `hermes profile delete <name> --yes`
/// runs only after the user confirms. On success the app forgets the bot (selection, Pin/Hide state, its Bot
/// Chat model) and re-lists the roster.
@MainActor
final class BotDeleteModel: ObservableObject, Identifiable {
    nonisolated var id: String { "delete:" + bot.name }
    nonisolated let bot: Bot
    private let service: any BotProfileService
    @Published private(set) var deleting = false
    @Published private(set) var error: String?
    /// Runs right before the CLI: the app lets go of the bot (selection, its Bot Chat session) so nothing of
    /// ours keeps the profile open while Hermes removes its folder.
    var beforeDelete: (String) -> Void = { _ in }
    var onDeleted: (String) async -> Void = { _ in }
    var onClose: () -> Void = {}

    init(bot: Bot, service: any BotProfileService) {
        self.bot = bot
        self.service = service
    }

    /// The default profile is never offered for deletion (menu and inspector hide the action).
    nonisolated static func canDelete(_ bot: Bot) -> Bool { !bot.isDefault && !ProfileCLI.isDefault(bot.name) }

    /// The profile folder as `profiles.list` reports it (full path, as Desktop's confirmation shows it).
    var profilePath: String { bot.path.flatMap { $0.isEmpty ? nil : $0 } ?? "its Hermes profile folder" }

    func confirm() async {
        guard !deleting, Self.canDelete(bot) else { return }
        deleting = true
        error = nil
        beforeDelete(bot.name)
        do {
            try await service.delete(bot.name)
            await onDeleted(bot.name)
            deleting = false
            onClose()
        } catch {
            self.error = BotManagementText.describe(error)
            deleting = false
        }
    }
}
