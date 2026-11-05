import AppKit
import HermesGatewayKit
import SwiftUI

/// UI wrapper around `ChatTranscript` (HermesGatewayKit), which owns the submit gate and the turn
/// settling rules and is unit tested there.
@MainActor
final class ChatModel: ObservableObject, Identifiable {
    let bot: Bot
    @Published private(set) var transcript = ChatTranscript()
    private(set) var session: BotChatSession?
    /// `BotChatSession.open` in flight: `close()` waits for it, so a session opened while the app quits
    /// is still closed (and deleted) instead of outliving cleanup.
    private var opening: Task<BotChatSession, Error>?
    private var closed = false
    var onTurnEvent: ((String, ChatModel) -> Void)?

    var lines: [ChatLine] { transcript.lines }
    var busy: Bool { transcript.busy }
    var deltaCount: Int { transcript.deltaCount }

    init(bot: Bot) { self.bot = bot }

    /// Synchronous submit gate. Returns true only when the message was accepted (the caller clears
    /// its input then); false while a turn runs or for blank input, with nothing sent or changed.
    /// Being synchronous on the main actor, a second submit before the network task starts sees
    /// `busy` already set.
    @discardableResult
    func submit(_ draft: String, backend: Backend, title: String) -> Bool {
        guard let text = transcript.beginTurn(draft) else { return false }
        Task { await self.run(text, backend: backend, title: title) }
        return true
    }

    private func run(_ text: String, backend: Backend, title: String) async {
        do {
            if session == nil {
                let open = Task { [bot] in try await BotChatSession.open(backend, bot: bot, title: title) }
                opening = open
                defer { opening = nil }
                let s = try await open.value
                guard !closed else { return }  // `close()` awaited `open` and closes this session
                // FIFO onto the main actor: one Task per event would not guarantee delta order.
                s.onEvent { [weak self] e in DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(e) } } }
                session = s
                AppModel.shared.log("chat opened: profile=\(bot.name) session_id=\(s.sessionId) stored=\(s.storedSessionId) title=\(s.titleResult ?? .null)")
            }
            let r = try await session!.send(text)
            AppModel.shared.log("prompt.submit → \(r)")
        } catch {
            let msg = Redaction.describe(error)
            AppModel.shared.log("send failed: \(msg)")
            transcript.fail(msg)
        }
    }

    private func apply(_ e: ChatEvent) {
        transcript.apply(e)
        switch e {
        case .started: onTurnEvent?("message.start", self)
        case .delta: onTurnEvent?("message.delta", self)
        case .interim: onTurnEvent?("message.interim", self)
        case .completed: onTurnEvent?("message.complete", self)
        case .error, .disconnected: onTurnEvent?("turn.failed", self)
        default: break
        }
    }

    var streamingText: String { transcript.lastBotText }

    func close() async -> [String] {
        closed = true
        var pending = session
        session = nil
        if pending == nil, let open = opening { pending = try? await open.value }
        guard let s = pending else { return [] }
        let keep = ProcessInfo.processInfo.environment["HERMES_BOT_APP_KEEP_SESSIONS"] == "1"
        return await s.close(deleteStored: !keep)
    }
}
