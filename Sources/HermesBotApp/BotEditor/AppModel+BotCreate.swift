import SwiftUI
import HermesGatewayKit

/// A7 entry points (the Bots section's "+" and File → New Bot…) and what happens after a create: re-list the roster,
/// show the new avatar, select the bot (its Bot Chat opens) and send the intro once the chat is ready.
extension AppModel {
    /// How long the intro waits for the new bot's Bot Chat to open.
    static let kickoffWait: TimeInterval = 60

    func newBot() {
        guard let service = botService() else { return }
        presentCreate(service: service)
    }

    func presentCreate(service: any BotProfileService) {
        guard botSheet == nil else { return }
        let m = BotCreateModel(roster: bots, service: service)
        m.onCreated = { [weak self] name, avatar in
            if let avatar { AvatarStore.shared.replace(name, data: avatar) }
            await self?.refreshBots()
            self?.log("profiles.create \(name) (New Bot)")
        }
        m.onClose = { [weak self] in self?.botSheet = nil }
        m.onOpen = { [weak self] name, kickoff in
            self?.botSheet = nil
            self?.openNewBot(name, kickoff: kickoff)
        }
        m.onEditModel = { [weak self] name in
            self?.botSheet = nil
            self?.editBot(name)
            if case .edit(let editor)? = self?.botSheet, !editor.advancedOpen { editor.toggleAdvanced() }
        }
        botSheet = .create(m)
    }

    /// Selects the new bot; with `kickoff`, opens its Bot Chat and sends Desktop's intro prompt once it is ready
    /// and still empty (an intro is never sent into a chat that already has messages).
    func openNewBot(_ name: String, kickoff: Bool, wait: TimeInterval = AppModel.kickoffWait) {
        guard let bot = bots.first(where: { $0.name == name }) else { return }
        selection = .bot(name)
        guard kickoff else { return }
        let chat = chat(for: bot)
        chat.open()
        Task { [weak self] in
            let end = Date().addingTimeInterval(wait)
            while !chat.isReady {
                if case .failed = chat.phase { return }
                if Date() > end || chat.closed { self?.log("New Bot intro for \(name) skipped: the Bot Chat did not open"); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard chat.lines.isEmpty, !chat.busy else { return }
            chat.sendDirect(BotCreate.kickoff, display: BotCreate.kickoff)
        }
    }
}

/// File → New Bot… (A7).
struct NewBotCommand: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button("New Bot…") { model.newBot() }
            .disabled(model.backend == nil || model.botSheet != nil)
    }
}
