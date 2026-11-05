import AppKit
import HermesGatewayKit
import SwiftUI

// D3: the menu bar extra. Bot and room status at a glance (needs you / working / idle, pending approvals
// and questions), a quick-send field into a bot's Bot Chat, and rows that open their bot or room in the main
// window. Settings → General → Show in menu bar (default on) inserts or removes it.

/// One row's state, the order rows are listed in (needs you first).
enum MenuBarRowState: Equatable, Comparable {
    /// Waiting on the user: request cards in a Bot Chat, an approval or `@user` in a room (count, ≥ 1).
    case needsYou(Int)
    case working
    case idle

    private var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .idle: return 2
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    var label: String {
        switch self {
        case .needsYou(let n): return n == 1 ? "Needs you" : "Needs you (\(n))"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

/// What the menu bar extra lists. Pure (MenuBarStatusTests).
struct MenuBarStatus: Equatable {
    struct Row: Identifiable, Equatable {
        let item: SidebarItem
        let title: String
        let state: MenuBarRowState
        var id: SidebarItem { item }
    }

    let bots: [Row]
    let rooms: [Row]
    /// Approvals and questions waiting across Bot Chats and rooms (what the Dock badge counts).
    let pending: Int

    /// Per-bot chat facts the app knows (only bots with an open Bot Chat model have any).
    struct ChatFacts: Equatable {
        var waiting: Int
        var busy: Bool
    }

    /// Per-room facts: approvals waiting, an unseen `@user`, a round running.
    struct RoomFacts: Equatable {
        var approvals: Int
        var mention: Bool
        var working: Bool
    }

    /// Hidden bots are left out (as in the sidebar). Within a state, the given order is kept.
    static func make(bots: [Bot], hidden: Set<String>, chats: [String: ChatFacts],
                     rooms: [RoomSummary], roomFacts: [String: RoomFacts]) -> MenuBarStatus {
        let botRows = bots.filter { !hidden.contains($0.name) }.map { bot -> Row in
            let f = chats[bot.name]
            let waiting = f?.waiting ?? 0
            let state: MenuBarRowState = waiting > 0 ? .needsYou(waiting) : f?.busy == true ? .working : .idle
            return Row(item: .bot(bot.name), title: bot.title, state: state)
        }
        let roomRows = rooms.map { room -> Row in
            let f = roomFacts[room.roomId]
            let needs = (f?.approvals ?? 0) + (f?.mention == true ? 1 : 0)
            let state: MenuBarRowState = needs > 0 ? .needsYou(needs) : f?.working == true ? .working : .idle
            return Row(item: .room(room.roomId), title: room.name, state: state)
        }
        let pending = chats.values.reduce(0) { $0 + $1.waiting } + roomFacts.values.reduce(0) { $0 + $1.approvals }
        return MenuBarStatus(bots: stable(botRows), rooms: stable(roomRows), pending: pending)
    }

    private static func stable(_ rows: [Row]) -> [Row] {
        rows.enumerated().sorted { a, b in a.element.state == b.element.state ? a.offset < b.offset : a.element.state < b.element.state }
            .map(\.element)
    }

    /// The menu bar icon's count: nil when nothing waits.
    var badge: String? { pending > 0 ? "\(pending)" : nil }
}

extension AppModel {
    /// The menu bar extra's current status from the live models.
    var menuBarStatus: MenuBarStatus {
        let chats = self.chats.mapValues { MenuBarStatus.ChatFacts(waiting: DockBadge.waiting($0.requests), busy: $0.busy) }
        let approvals = notifications.rooms.approvalCounts
        var facts: [String: MenuBarStatus.RoomFacts] = [:]
        for room in rooms {
            let id = room.roomId
            let onScreen = roomModels[id]?.isOnScreen ?? false
            let mention = roomDigests.needsYou(id, onScreen: onScreen) == .mention
            let working = roomModels[id]?.active ?? (roomDigests.digests[id]?.awaiting ?? false)
            facts[id] = .init(approvals: approvals[id] ?? 0, mention: mention, working: working)
        }
        let hidden = Set(bots.map(\.name).filter { botMeta[$0].hidden })
        return MenuBarStatus.make(bots: bots, hidden: hidden, chats: chats, rooms: groupsAvailable ? rooms : [], roomFacts: facts)
    }
}

/// The menu bar extra's scene: one line in `HermesBotApp.body`.
struct MenuBarScene: Scene {
    static let settingKey = "hba.menuBarExtra"
    @AppStorage(MenuBarScene.settingKey) private var shown = true

    var body: some Scene {
        // Not `$shown`: AppKit writes `isInserted` back on every menu bar update, and each write to the
        // @AppStorage key re-evaluates the App body, which updates the menu bar extras again: a main-thread
        // loop at 100% CPU that kept the app from ever connecting. Only a real change is stored.
        MenuBarExtra(isInserted: Self.insertion(get: { shown }, set: { shown = $0 })) {
            MenuBarContent(app: AppModel.shared)
        } label: {
            MenuBarLabel(badge: MenuBarBadge.shared)
        }
        .menuBarExtraStyle(.window)
    }

    /// A binding that forwards only changed values, so repeated same-value writes from AppKit never touch the
    /// stored setting (and never re-render the scene).
    static func insertion(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { value in if value != get() { set(value) } })
    }
}

/// The status item's count, refreshed every 2 s from the live models (chat and room states live in several
/// models, none of which the status item could observe on its own). Started by `MacIntegration.install`.
@MainActor
final class MenuBarBadge: ObservableObject {
    static let shared = MenuBarBadge()
    @Published private(set) var badge: String?
    private var loop: Task<Void, Never>?

    func start(every seconds: Double = 2, _ status: @escaping @MainActor () -> MenuBarStatus) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.update(status().badge)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func update(_ badge: String?) { if badge != self.badge { self.badge = badge } }
}

/// The status item: the app's symbol, plus the count of things waiting on the user.
struct MenuBarLabel: View {
    @ObservedObject var badge: MenuBarBadge

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: badge.badge == nil ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
            if let count = badge.badge { Text(count) }
        }
        .accessibilityLabel(badge.badge.map { "Hermes Bot, \($0) waiting on you" } ?? "Hermes Bot")
    }
}

/// The window the status item opens.
struct MenuBarContent: View {
    @ObservedObject var app: AppModel
    @StateObject private var quick = MenuBarQuickSend()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = app.menuBarStatus
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                header(status)
                if app.phase.isConnected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            section("Bots", status.bots)
                            if !status.rooms.isEmpty { section("Group Chats", status.rooms) }
                        }
                    }
                    .frame(maxHeight: 280)
                    Hairline()
                    quickSend
                }
                Hairline()
                footer
            }
            .padding(DS.Space.s3)
            .frame(width: 320)
        }
        .onAppear { quick.pickDefault(app.bots) }
    }

    private func header(_ status: MenuBarStatus) -> some View {
        HStack {
            Text("Hermes Bot").font(DS.Typeface.bodyStrong)
            Spacer()
            switch app.phase {
            case .connecting: Text("Connecting…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            case .failed: Text("Not connected").font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            case .connected:
                Text(status.pending == 0 ? "Nothing waiting" : "\(status.pending) waiting on you")
                    .font(DS.Typeface.meta)
                    .foregroundStyle(status.pending == 0 ? DS.Palette.muted : DS.Palette.attention)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [MenuBarStatus.Row]) -> some View {
        Text(title).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted).padding(.top, DS.Space.s1)
        ForEach(rows) { row in
            Button { app.openFromIntegration(row.item) } label: {
                HStack(spacing: DS.Space.s2) {
                    MenuBarStateDot(state: row.state)
                    Text(row.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    Spacer(minLength: DS.Space.s2)
                    Text(row.state.label).font(DS.Typeface.meta)
                        .foregroundStyle(row.state == .idle ? DS.Palette.muted : DS.Palette.ink)
                }
                .contentShape(Rectangle())
                .padding(.vertical, DS.Space.s0)
            }
            .buttonStyle(.plain)
            .help("Open \(row.title)")
            .accessibilityLabel("\(row.title), \(row.state.label)")
        }
    }

    private var quickSend: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Quick send").font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
            HStack(spacing: DS.Space.s2) {
                Picker("Bot", selection: $quick.bot) {
                    ForEach(app.bots) { bot in Text(bot.title).tag(Optional(bot.name)) }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
                TextField("Message", text: $quick.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await quick.send(app.quickSender) } }
                Button("Send") { Task { await quick.send(app.quickSender) } }
                    .disabled(!quick.canSend)
            }
            if let note = quick.note {
                HStack {
                    Text(note.text).font(DS.Typeface.meta)
                        .foregroundStyle(note.failed ? DS.Palette.danger : DS.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !note.failed, let bot = note.bot {
                        Button("Open") { app.openFromIntegration(.bot(bot)) }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Hermes Bot") {
                NSApp.activate(ignoringOtherApps: true)
                AppModel.mainWindowsFront()
            }
            Spacer()
            Button("Quick Ask") { QuickAskPanelController.shared.show() }
                .help("Ask a bot from anywhere (\(MacIntegration.shared.hotKey.shortcut.display))")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(DS.Typeface.meta)
    }
}

private struct MenuBarStateDot: View {
    let state: MenuBarRowState
    var body: some View {
        switch state {
        case .needsYou: StatusDot(color: DS.Palette.attention)
        case .working: StatusDot(color: DS.Palette.primary, live: true)
        case .idle: StatusDot(color: DS.Palette.hairline)
        }
    }
}

/// The menu bar's quick-send field (headless: MenuBarStatusTests).
@MainActor
final class MenuBarQuickSend: ObservableObject {
    struct Note: Equatable {
        let text: String
        let failed: Bool
        let bot: String?
    }

    @Published var bot: String?
    @Published var text = ""
    @Published private(set) var sending = false
    @Published private(set) var note: Note?

    var canSend: Bool { bot != nil && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func pickDefault(_ bots: [Bot]) {
        if let bot, bots.contains(where: { $0.name == bot }) { return }
        bot = bots.first?.name
    }

    /// Sends to the bot's Bot Chat; the reply lands there (Open shows it).
    func send(_ sender: QuickSender) async {
        guard canSend, let bot else { return }
        sending = true
        defer { sending = false }
        do {
            let turn = try await sender.send(text, toBot: bot)
            text = ""
            note = Note(text: "Sent to \(turn.chat.bot.title). The reply arrives in its Bot Chat.", failed: false, bot: bot)
        } catch {
            note = Note(text: (error as? QuickSendError)?.description ?? Redaction.describe(error), failed: true, bot: bot)
        }
    }
}
