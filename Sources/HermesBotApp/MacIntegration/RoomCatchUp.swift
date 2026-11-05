import Foundation
import HermesGatewayKit
import SwiftUI

// D12: "Summarize since I left" for rooms. When a room's pane comes on screen, the room's seen-through seq
// (RoomDigestHub, persisted) is captured as "where the user left" (`RoomDigestHub.leftAt`, taken before the
// visit marks anything seen); the toolbar button builds a summary prompt
// from the messages after it and asks a bot the user picks, in that bot's Bot Chat. The summary streams into
// the sheet (and stays in the Bot Chat). Nothing is ever posted into the room.

/// The summary prompt. Pure (RoomCatchUpTests).
///
///     Summarize what happened in the group chat "Ops" since I last read it (14 new messages, quoted below as
///     context only). List decisions, open questions and anything waiting on me. Be brief.
///
///     > Alpha: the deploy is green
///     > You: thanks
///     > [thread] Beta: can someone review #12
enum RoomCatchUp {
    /// Messages quoted (the newest ones when there are more).
    static let messageLimit = 80
    /// Characters of the whole prompt: oldest quotes are left out until it fits.
    static let charLimit = 12_000
    /// Characters of one quoted message.
    static let quoteLimit = 600

    /// User and member messages after `seq` (every thread), oldest first.
    static func unseen(_ lines: [RoomLine], after seq: Int) -> [RoomLine] {
        lines.filter { ($0.kind == .user || $0.kind == .member) && $0.id > seq }.sorted { $0.id < $1.id }
    }

    /// The prompt for the bot, and how many messages it quotes (nil when nothing is unseen).
    static func prompt(room: RoomSummary, lines: [RoomLine], after seq: Int) -> (text: String, quoted: Int, total: Int)? {
        let new = unseen(lines, after: seq)
        guard !new.isEmpty else { return nil }
        var quotes = new.suffix(messageLimit).map(quote)
        while true {
            let text = compose(room: room, total: new.count, quotes: quotes)
            if text.count <= charLimit || quotes.count <= 1 { return (text, quotes.count, new.count) }
            quotes.removeFirst()
        }
    }

    private static func compose(room: RoomSummary, total: Int, quotes: [String]) -> String {
        let name = RoomCarryOver.safe(room.name, limit: RoomCarryOver.nameLimit)
        let count = total == 1 ? "1 new message" : "\(total) new messages"
        let shown = quotes.count < total ? ", the latest \(quotes.count) quoted below" : ", quoted below"
        return """
            Summarize what happened in the group chat "\(name)" since I last read it (\(count)\(shown) as context \
            only). List decisions, open questions and anything waiting on me. Be brief.

            \(quotes.joined(separator: "\n"))
            """
    }

    /// One `> Author: text` line (`RoomCarryOver.safe`: one line, control frames relabelled, `@` dropped);
    /// thread messages are marked.
    static func quote(_ line: RoomLine) -> String {
        let parts = RoomAttachments.split(line.text)
        var body = RoomCarryOver.safe(parts.text, limit: quoteLimit)
        let files = parts.paths.map { RoomCarryOver.safe(URL(fileURLWithPath: $0).lastPathComponent, limit: RoomCarryOver.nameLimit) }
        if !files.isEmpty { body += (body.isEmpty ? "" : " ") + "(files: \(files.joined(separator: ", ")))" }
        let thread = line.threadId == RoomThreads.main ? "" : "[thread] "
        return "> \(thread)\(RoomCarryOver.safe(line.author, limit: RoomCarryOver.nameLimit)): \(body)"
    }

    /// The bot offered first: the room's first member that is still a bot, else the first bot.
    static func defaultBot(room: RoomSummary, bots: [Bot]) -> String? {
        let names = Set(bots.map(\.name))
        return room.members.map(\.profile).first(where: names.contains) ?? bots.first?.name
    }
}

/// The sheet's state, headless (RoomCatchUpTests).
@MainActor
final class RoomCatchUpModel: ObservableObject {
    @Published var bot: String?
    @Published private(set) var turn: QuickTurn?
    @Published private(set) var error: String?
    @Published private(set) var sending = false

    let room: RoomSummary
    let prompt: (text: String, quoted: Int, total: Int)?
    let sender: () -> QuickSender

    init(room: RoomSummary, lines: [RoomLine], after seq: Int, sender: @escaping () -> QuickSender) {
        self.room = room
        prompt = RoomCatchUp.prompt(room: room, lines: lines, after: seq)
        self.sender = sender
        bot = RoomCatchUp.defaultBot(room: room, bots: sender().bots())
    }

    var bots: [Bot] { sender().bots() }
    var canAsk: Bool { prompt != nil && bot != nil && !sending && turn == nil }

    /// Sends the prompt to the bot's Bot Chat (never to the room).
    func ask() async {
        guard canAsk, let bot, let prompt else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            turn = try await sender().send(prompt.text, toBot: bot)
        } catch {
            self.error = (error as? QuickSendError)?.description ?? Redaction.describe(error)
        }
    }
}

/// The room toolbar's "Summarize" button.
struct RoomCatchUpButton: View {
    @ObservedObject var model: RoomModel
    @ObservedObject var digests: RoomDigestHub
    @State private var sheet: RoomCatchUpModel?
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let left = digests.leftAt[model.id] ?? digests.seenThrough[model.id] ?? 0
        let unseen = RoomCatchUp.unseen(model.lines, after: left).count
        Button {
            sheet = RoomCatchUpModel(room: model.room, lines: model.lines, after: left,
                                     sender: { AppModel.shared.quickSender })
        } label: { Label("Summarize", systemImage: "text.badge.star") }
            .help(unseen == 0 ? "Nothing new since you last read this room"
                              : "Ask a bot to summarize the \(unseen) message\(unseen == 1 ? "" : "s") since you last read this room")
            .disabled(unseen == 0 || model.lastSync == nil)
            .motionSheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }), motion: motion) {
                if let sheet {
                    RoomCatchUpSheet(model: sheet, onOpen: { name in
                        self.sheet = nil
                        AppModel.shared.openFromIntegration(.bot(name))
                    }, onClose: { self.sheet = nil })
                }
            }
    }
}

struct RoomCatchUpSheet: View {
    @ObservedObject var model: RoomCatchUpModel
    let onOpen: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text("Summarize Since You Left").font(DS.Typeface.titlePane)
            if let prompt = model.prompt {
                Text(prompt.total == 1 ? "1 new message in \(model.room.name)." : "\(prompt.total) new messages in \(model.room.name).")
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                Text("The summary is asked in the bot's Bot Chat. Nothing is posted in the group chat.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing new since you last read this room.").font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
            }
            Picker("Ask", selection: $model.bot) {
                ForEach(model.bots) { bot in Text(bot.title).tag(Optional(bot.name)) }
            }
            .disabled(model.turn != nil)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let turn = model.turn {
                Hairline()
                QuickReplyView(chat: turn.chat, userLine: turn.userLine, maxHeight: 320)
            }
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if model.sending { ProgressView().controlSize(.small) }
                if let turn = model.turn {
                    Button("Open Bot Chat") { onOpen(turn.chat.bot.name) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                } else {
                    Button("Summarize") { Task { await model.ask() } }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAsk)
                }
            }
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Size.sheetWidth)
    }
}
