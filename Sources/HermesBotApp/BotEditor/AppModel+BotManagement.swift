import Foundation
import HermesGatewayKit

/// The one bot-management sheet on screen (New Bot, Edit, Duplicate or Delete), presented by `RootView`.
enum BotSheet: Identifiable {
    case create(BotCreateModel)
    case edit(BotEditorModel)
    case duplicate(BotDuplicateModel)
    case delete(BotDeleteModel)

    var id: String {
        switch self {
        case .create(let m): return m.id
        case .edit(let m): return "edit:" + m.id
        case .duplicate(let m): return m.id
        case .delete(let m): return m.id
        }
    }
}

/// A8 / A9 / A11 / A12 entry points (bot row menu and inspector) and what the app does after each one:
/// re-list the roster, update avatars, forget a deleted bot.
extension AppModel {
    /// The live service for the current connection; nil while not connected.
    func botService() -> (any BotProfileService)? { backend.map { LiveBotProfileService(client: $0.client) } }

    private func bot(_ name: String) -> Bot? { bots.first { $0.name == name } }

    func editBot(_ name: String) {
        guard let bot = bot(name), let service = botService() else { return }
        presentEdit(bot, service: service)
    }

    func duplicateBot(_ name: String) {
        guard let bot = bot(name), let service = botService() else { return }
        presentDuplicate(bot, service: service)
    }

    func deleteBot(_ name: String) {
        guard let bot = bot(name), BotDeleteModel.canDelete(bot), let service = botService() else { return }
        presentDelete(bot, service: service)
    }

    func presentEdit(_ bot: Bot, service: any BotProfileService) {
        guard botSheet == nil else { return }
        let m = BotEditorModel(bot: bot, service: service, hadAvatar: AvatarStore.shared.images[bot.name] != nil)
        m.onAvatarSaved = { data in AvatarStore.shared.replace(bot.name, data: data) }
        m.onClose = { [weak self] changed in
            self?.botSheet = nil
            if changed { Task { await self?.refreshBots() } }
        }
        botSheet = .edit(m)
    }

    func presentDuplicate(_ bot: Bot, service: any BotProfileService) {
        guard botSheet == nil else { return }
        let m = BotDuplicateModel(source: bot, service: service)
        m.onCreated = { [weak self] result in
            await self?.refreshBots()
            self?.log("profiles.create \(result.name) (clone of \(bot.name))" + (result.warnings.isEmpty ? "" : ": \(result.warnings.joined(separator: " "))"))
        }
        m.onClose = { [weak self] in self?.botSheet = nil }
        m.onOpen = { [weak self] name in
            self?.botSheet = nil
            if self?.bots.contains(where: { $0.name == name }) == true { self?.selection = .bot(name) }
        }
        botSheet = .duplicate(m)
    }

    func presentDelete(_ bot: Bot, service: any BotProfileService) {
        guard botSheet == nil, BotDeleteModel.canDelete(bot) else { return }
        let m = BotDeleteModel(bot: bot, service: service)
        m.beforeDelete = { [weak self] name in self?.releaseBot(name) }
        m.onDeleted = { [weak self] name in
            self?.botDeleted(name)
            await self?.refreshBots()
        }
        m.onClose = { [weak self] in self?.botSheet = nil }
        botSheet = .delete(m)
    }

    /// `profiles.list` again after a change, keeping every open chat (its bot gets the new title / model).
    func refreshBots() async {
        guard let b = backend else { return }
        do {
            let listed = try await Bot.list(b)
            guard backend === b else { return }
            applyRoster(listed)
            log("profiles.list (refresh) → \(listed.map(\.name))")
        } catch {
            log("profiles.list (refresh) failed: \(Redaction.describe(error))")
        }
    }

    func applyRoster(_ listed: [Bot]) {
        bots = listed
        botMeta.refresh(listed)
        for bot in listed { chats[bot.name]?.bot = bot }
    }

    /// Before a delete: leave the bot's pane and detach its Bot Chat (never `session.close` / `.delete`). If
    /// the delete fails, selecting the bot again opens a fresh chat model.
    func releaseBot(_ name: String) {
        if selection == .bot(name) { selection = nil }
        if let chat = chats.removeValue(forKey: name) { chat.close() }
        notifications.untrack(name)
    }

    /// A deleted bot leaves the app: selection, its Bot Chat model (detached), notifications, Pin/Hide state,
    /// avatar and the roster row.
    func botDeleted(_ name: String) {
        releaseBot(name)
        botMeta.forget(name)
        AvatarStore.shared.replace(name, data: nil)
        bots.removeAll { $0.name == name }
        log("bot \(name) deleted → removed from the app")
    }
}
