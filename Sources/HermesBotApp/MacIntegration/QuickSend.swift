import AppKit
import HermesGatewayKit
import SwiftUI

// The one send path behind the macOS integration surfaces (D3 menu bar quick send, D4 Quick Ask panel,
// D6 Services chooser, D7 Shortcuts actions, D12 "Summarize since I left"). Everything goes through the
// running app's own models: a bot's message becomes a turn in its canonical Bot Chat (`ChatModel.sendDirect`,
// the same gate as the composer: refused while a reply runs), a room message is one `groups.send` on `main`.
// Nothing here sends on its own: every send is a user action (a Send button, a Shortcuts action the user ran).

/// Where a quick message goes.
enum QuickSendTarget: Hashable, Sendable {
    case bot(String)
    case room(String)

    var item: SidebarItem {
        switch self {
        case .bot(let name): return .bot(name)
        case .room(let id): return .room(id)
        }
    }
}

/// Why a quick send did not go out (or its reply did not come back). User-facing, token-free text.
enum QuickSendError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notConnected
    case unknownBot(String)
    case unknownRoom(String)
    case empty
    case tooLong
    case notReady(String)
    case busy(String)
    case timedOut(String)
    case failed(String)

    var description: String {
        switch self {
        case .notConnected: return "Hermes Bot is not connected to Hermes. Open the app and connect first."
        case .unknownBot(let name): return "There is no bot named \(name)."
        case .unknownRoom(let name): return "There is no group chat \(name)."
        case .empty: return "Type a message first."
        case .tooLong: return "The message is too long for a group chat."
        case .notReady(let bot): return "\(bot)'s Bot Chat is not open yet. Try again in a moment."
        case .busy(let bot): return "\(bot) is still replying. Send again when the reply ends."
        case .timedOut(let bot): return "\(bot) did not finish replying in time. The reply continues in its Bot Chat."
        case .failed(let why): return why
        }
    }

    var errorDescription: String? { description }
}

/// A message this app sent into a Bot Chat: the chat and the user line that started the turn.
struct QuickTurn {
    let chat: ChatModel
    let userLine: UUID
}

/// What a quick turn's reply looks like right now, from the chat's lines after the turn's user line.
/// Pure (QuickSendTests).
enum QuickReply: Equatable {
    /// Sent, nothing streamed yet.
    case waiting
    /// Text so far while the turn runs.
    case streaming(String)
    /// The turn ended with this text (empty: the bot answered with tools only).
    case done(String)
    /// The turn ended with an error, or its user line is gone (the send was taken back).
    case failed(String)

    static func state(lines: [ChatLine], after userLine: UUID, busy: Bool) -> QuickReply {
        guard let start = lines.firstIndex(where: { $0.id == userLine }) else {
            return busy ? .waiting : .failed("The message did not go out.")
        }
        let after = lines[(start + 1)...]
        // The turn's output ends at the next user line (a later message in the same chat starts a new turn).
        let turn = after.prefix { $0.role != .user }
        let text = turn.filter { $0.role == .bot }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if busy && turn.count == after.count { return text.isEmpty ? .waiting : .streaming(text) }
        if let error = turn.last(where: { $0.role == .error }), text.isEmpty { return .failed(error.text) }
        return .done(text)
    }

    var text: String {
        switch self {
        case .waiting: return ""
        case .streaming(let t), .done(let t), .failed(let t): return t
        }
    }

    var failed: Bool { if case .failed = self { return true }; return false }

    var finished: Bool {
        switch self {
        case .done, .failed: return true
        case .waiting, .streaming: return false
        }
    }
}

/// Sends quick messages through the app's models. AppModel builds the live one (`AppModel.quickSender`);
/// tests build one over `FakeChatLink` chats and `FakeRoomActions`.
@MainActor
struct QuickSender {
    var connected: () -> Bool
    var bots: () -> [Bot]
    var rooms: () -> [RoomSummary]
    /// The bot's Bot Chat model (created on first use, like selecting the bot).
    var chat: (Bot) -> ChatModel
    var roomActions: () -> (any RoomActions)?
    /// A room message went out: the open room polls now.
    var roomSent: (String) -> Void = { _ in }
    /// How long a Bot Chat may take to open before a send gives up.
    var openTimeout: TimeInterval = 15
    /// Poll step while waiting on a chat (open, reply).
    var step: UInt64 = 50_000_000

    func bot(_ name: String) throws -> Bot {
        guard connected() else { throw QuickSendError.notConnected }
        guard let bot = bots().first(where: { $0.name == name }) else { throw QuickSendError.unknownBot(name) }
        return bot
    }

    func room(_ id: String) throws -> RoomSummary {
        guard connected() else { throw QuickSendError.notConnected }
        guard let room = rooms().first(where: { $0.roomId == id }) else { throw QuickSendError.unknownRoom(id) }
        return room
    }

    /// The bot's Bot Chat, opened (resumed) and ready. Opening is what selecting the bot does.
    func readyChat(_ name: String) async throws -> ChatModel {
        let chat = chat(try bot(name))
        chat.open()
        let deadline = Date().addingTimeInterval(openTimeout)
        while !chat.isReady {
            if case .failed(let why) = chat.phase { throw QuickSendError.failed(why) }
            guard Date() < deadline, !Task.isCancelled else { throw QuickSendError.notReady(chat.bot.title) }
            try? await Task.sleep(nanoseconds: step)
        }
        return chat
    }

    /// Sends `text` as a new turn in the bot's Bot Chat (the composer's draft and chips stay as they are).
    /// Refused while a reply or a client action runs there.
    func send(_ text: String, toBot name: String) async throws -> QuickTurn {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw QuickSendError.empty }
        let chat = try await readyChat(name)
        guard !chat.reconnecting, !chat.busy, chat.activity == nil else { throw QuickSendError.busy(chat.bot.title) }
        let serial = chat.transcript.turnSerial
        chat.sendDirect(chat.modelText(typed), display: typed)
        guard chat.transcript.turnSerial != serial, let line = chat.lines.last(where: { $0.role == .user }) else {
            throw QuickSendError.busy(chat.bot.title)
        }
        return QuickTurn(chat: chat, userLine: line.id)
    }

    /// Waits until the turn ends and returns its reply text. Past `timeout` it throws `timedOut`; the turn
    /// keeps running in the Bot Chat.
    func reply(_ turn: QuickTurn, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch QuickReply.state(lines: turn.chat.lines, after: turn.userLine, busy: turn.chat.busy) {
            case .done(let text): return text
            case .failed(let why): throw QuickSendError.failed(why)
            case .waiting, .streaming: break
            }
            guard Date() < deadline, !Task.isCancelled else { throw QuickSendError.timedOut(turn.chat.bot.title) }
            try? await Task.sleep(nanoseconds: step)
        }
    }

    /// Posts `text` to the room's `main` thread (`groups.send`). Mentions in the text pick who answers, as
    /// in the room's own composer.
    func send(_ text: String, toRoom id: String) async throws {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw QuickSendError.empty }
        let room = try room(id)
        guard typed.utf8.count <= RoomComposer.maxTextBytes else { throw QuickSendError.tooLong }
        guard let api = roomActions() else { throw QuickSendError.notConnected }
        let eventId = "hba-msg-\(UUID().uuidString.lowercased())"
        do {
            _ = try await api.sendMessage(roomId: room.roomId, eventId: eventId, text: typed, threadId: RoomThreads.main)
        } catch {
            throw QuickSendError.failed("The message may not have been posted: \(Redaction.describe(error))")
        }
        roomSent(room.roomId)
    }

    /// Puts `text` and `files` into the target's composer without sending (Services "Open in Composer").
    func prefill(_ target: QuickSendTarget, text: String, files: [URL], roomModel: (String) -> RoomModel?) async throws {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .bot(let name):
            let chat = try await readyChat(name)
            if !typed.isEmpty { chat.draft = Self.appending(typed, to: chat.draft) }
            if !files.isEmpty { chat.addAttachments(files) }
        case .room(let id):
            _ = try room(id)
            guard let model = roomModel(id) else { throw QuickSendError.unknownRoom(id) }
            if !typed.isEmpty { model.drafts[RoomThreads.main] = Self.appending(typed, to: model.drafts[RoomThreads.main] ?? "") }
            if !files.isEmpty { model.addAttachments(files) }
        }
    }

    /// A draft with `text` added below what the user already typed.
    nonisolated static func appending(_ text: String, to draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text
    }
}

extension AppModel {
    /// The live quick-send path over this connection's bots, chats and rooms.
    var quickSender: QuickSender {
        QuickSender(connected: { [weak self] in self?.phase.isConnected == true && self?.backend != nil },
                    bots: { [weak self] in self?.bots ?? [] },
                    rooms: { [weak self] in self?.groupsAvailable == true ? self?.rooms ?? [] : [] },
                    chat: { [unowned self] bot in self.chat(for: bot) },
                    roomActions: { [weak self] in self?.groups },
                    roomSent: { [weak self] id in self?.roomModels[id]?.nudge() })
    }

    /// Shows `item` in the main window and brings the app forward (menu bar rows, Quick Ask's "Open in
    /// Bot Chat", the Services chooser, Summarize's "Open Bot Chat").
    func openFromIntegration(_ item: SidebarItem) {
        switch item {
        case .bot(let name) where !bots.contains(where: { $0.name == name }): return
        case .room(let id) where !rooms.contains(where: { $0.roomId == id }): return
        default: break
        }
        NSApp?.activate(ignoringOtherApps: true)
        Self.mainWindowsFront()
        withTransaction(SidebarView.selectionTransaction) { selection = item }
    }

    /// Restores and orders front the app's document windows (not Settings, panels or the menu bar extra).
    static func mainWindowsFront() {
        guard let app = NSApp else { return }
        let windows = app.windows.filter { w in
            !(w is NSPanel) && w.canBecomeMain && !(w.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false)
        }
        for w in windows where w.isMiniaturized { w.deminiaturize(nil) }
        windows.first?.makeKeyAndOrderFront(nil)
    }
}
