import Foundation
import HermesGatewayKit
import SwiftUI

// K9: Kanban integrations.
// - Create Task from Message: Group Chat and Bot Chat message menus call `KanbanHub.composeTask(from:)` (via
//   `AppModel.composeTask`) with a `KanbanTaskSeed`; `KanbanComposePresenter` shows the New Task sheet
//   prefilled (message text as the description, its author as the suggested assignee) with a board picker.
// - Watching: cards created from the app are watched, and any card can be watched from its menu
//   (`KanbanWatchList`, kept in UserDefaults). `KanbanCardWatcher` polls the boards holding watched cards
//   (`GET /board`, its own slow loop, running while the app is in the background too) and reports a card
//   that moved into Done or Blocked; `NotificationCoordinator.kanbanCard` posts it (D1 policy: only while the
//   app is not frontmost). The first sighting of a card is its baseline, never a notification.
// - Open Bot Chat: a card's assignee opens its Bot Chat (`AppModel.openBotChat`).

/// What a message hands to the New Task sheet.
struct KanbanTaskSeed: Equatable {
    let text: String
    /// The bot that wrote the message (or, for the user's own Bot Chat message, the chat's bot).
    let suggestedAssignee: String?
    /// "From @alice in Planning", shown under the sheet title.
    let source: String

    static let titleLimit = 80

    /// The first non-empty line, Markdown heading / list / quote marks dropped, cut at `titleLimit`.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var s = Substring(line)
        while let c = s.first, "#>*-+ ".contains(c) { s = s.dropFirst() }
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > Self.titleLimit else { return flat }
        return String(flat.prefix(Self.titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A Bot Chat line: a bot reply suggests that bot; the user's own message suggests the chat's bot too.
    static func botChat(text: String, fromUser: Bool, bot: String, botTitle: String) -> KanbanTaskSeed {
        KanbanTaskSeed(text: text.trimmingCharacters(in: .whitespacesAndNewlines), suggestedAssignee: bot,
                       source: fromUser ? "From your message to \(botTitle)" : "From \(botTitle) in Bot Chat")
    }

    /// A Group Chat row: a member's message suggests that member's profile; the user's own suggests nobody.
    static func room(text: String, member: RoomMember?, roomName: String) -> KanbanTaskSeed {
        KanbanTaskSeed(text: text.trimmingCharacters(in: .whitespacesAndNewlines), suggestedAssignee: member?.profile,
                       source: member.map { "From \($0.title) in \(roomName)" } ?? "From your message in \(roomName)")
    }
}

/// A New Task sheet asked for from a message.
struct KanbanComposeRequest: Identifiable, Equatable {
    let id = UUID()
    let seed: KanbanTaskSeed
    /// The board it starts on (the user can pick another); nil when no board is listed.
    let board: String?
}

// MARK: - watched cards

/// Cards that notify when they finish or become blocked: `[board slug: card ids]`, saved in UserDefaults
/// (`defaults: nil` keeps them in memory, for tests and bare hubs).
@MainActor
final class KanbanWatchList: ObservableObject {
    static let defaultsKey = "hba.kanbanWatchedCards"
    /// Oldest entries go beyond this many per board (finished cards leave on their own).
    static let maxPerBoard = 200

    @Published private(set) var cards: [String: [String]] = [:]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let saved = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: [String]] {
            cards = saved.filter { !$0.value.isEmpty }
        }
    }

    var isEmpty: Bool { cards.values.allSatisfy(\.isEmpty) }
    func contains(_ slug: String, _ id: String) -> Bool { cards[slug]?.contains(id) ?? false }
    func ids(_ slug: String) -> Set<String> { Set(cards[slug] ?? []) }

    func watch(_ slug: String, _ id: String) {
        guard !contains(slug, id) else { return }
        var list = cards[slug] ?? []
        list.append(id)
        if list.count > Self.maxPerBoard { list.removeFirst(list.count - Self.maxPerBoard) }
        cards[slug] = list
        save()
    }

    func unwatch(_ slug: String, _ id: String) {
        guard contains(slug, id) else { return }
        cards[slug]?.removeAll { $0 == id }
        if cards[slug]?.isEmpty == true { cards[slug] = nil }
        save()
    }

    func set(_ slug: String, _ id: String, watching: Bool) {
        if watching { watch(slug, id) } else { unwatch(slug, id) }
    }

    /// A board that is gone: its watches go too.
    func forget(board slug: String) {
        guard cards[slug] != nil else { return }
        cards[slug] = nil
        save()
    }

    private func save() { defaults?.set(cards, forKey: Self.defaultsKey) }
}

enum KanbanCardChange: String, Equatable { case finished, blocked }

struct KanbanCardEvent: Equatable {
    let board: String
    let boardName: String
    let task: KanbanTask
    let change: KanbanCardChange
}

/// Follows the watched cards of every board with a slow `GET /board` loop of its own (it keeps running while
/// the app's windows are hidden: that is when a notification matters).
@MainActor
final class KanbanCardWatcher {
    static let interval: TimeInterval = 15

    let watches: KanbanWatchList
    /// Last status seen per board and card. A card's first sighting only records it.
    private(set) var known: [String: [String: String]] = [:]
    var onEvent: ((KanbanCardEvent) -> Void)?
    var boardName: (String) -> String = { $0 }
    private var api: (any KanbanService)?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(watches: KanbanWatchList,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.watches = watches
        self.sleep = sleep
    }

    var isRunning: Bool { loop != nil }

    /// A card the app just created: watched from its created status, so an early finish is not missed.
    func watch(_ slug: String, _ task: KanbanTask) {
        watches.watch(slug, task.id)
        known[slug, default: [:]][task.id] = task.status
    }

    /// Compares one board answer with the last one; returns the cards that moved into Done or Blocked. A
    /// finished card stops being watched; a watched card no longer on the board (archived, deleted) too.
    func observe(_ slug: String, board: KanbanBoard) -> [KanbanCardEvent] {
        let watched = watches.ids(slug)
        guard !watched.isEmpty else {
            known[slug] = nil
            return []
        }
        var statuses = known[slug] ?? [:]
        var events: [KanbanCardEvent] = []
        for id in watched.sorted() {
            guard let t = board.task(id: id) else {
                watches.unwatch(slug, id)
                statuses[id] = nil
                continue
            }
            let before = statuses[id]
            statuses[id] = t.status
            guard let before, before != t.status else { continue }
            if t.status == "done" {
                events.append(KanbanCardEvent(board: slug, boardName: boardName(slug), task: t, change: .finished))
                watches.unwatch(slug, id)
                statuses[id] = nil
            } else if t.status == "blocked" {
                events.append(KanbanCardEvent(board: slug, boardName: boardName(slug), task: t, change: .blocked))
            }
        }
        known[slug] = statuses.filter { watches.contains(slug, $0.key) }
        return events
    }

    func start(api: any KanbanService) {
        stop()
        self.api = api
        generation += 1
        let gen = generation, sleep = self.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                await self.pollOnce()
                do { try await sleep(Self.interval) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        api = nil
        known = [:]
    }

    /// One pass over every board with watched cards. A board that is gone drops its watches; other errors
    /// wait for the next pass.
    func pollOnce() async {
        guard let api else { return }
        let gen = generation
        for slug in watches.cards.keys.sorted() where !watches.ids(slug).isEmpty {
            do {
                let board = try await api.board(slug, includeArchived: false, tenant: nil)
                guard gen == generation else { return }
                for e in observe(slug, board: board) { onEvent?(e) }
            } catch {
                guard gen == generation else { return }
                if KanbanBoardModel.isBoardGone(error) {
                    watches.forget(board: slug)
                    known[slug] = nil
                }
            }
        }
    }
}

/// The notification of a watched card (posted through NotificationCoordinator.kanbanCard).
enum KanbanCardNotice {
    static let boardKey = "kanbanBoard"
    static let taskKey = "kanbanTask"

    static func content(_ e: KanbanCardEvent) -> NotificationContent {
        let title = e.task.title.isEmpty ? e.task.id : e.task.title
        let heading: String
        let detail: String?
        switch e.change {
        case .finished:
            heading = "Done: \(title)"
            detail = e.task.latestSummary ?? e.task.result
        case .blocked:
            heading = e.task.blockKind == "needs_input" ? "Needs your input: \(title)" : "Blocked: \(title)"
            detail = e.task.latestSummary
        }
        let who = e.task.assignee.map { "@\($0)" }
        let body = ([e.boardName, who].compactMap { $0 }.joined(separator: " · ")) + (detail.map { ": \($0)" } ?? "")
        return NotificationContent(id: "kanban.\(e.board).\(e.task.id).\(e.change.rawValue)", title: NotificationContent.clip(heading),
                                   body: NotificationContent.clip(body), category: nil,
                                   userInfo: [NotificationRoute.targetKey: "board:\(e.board)", boardKey: e.board, taskKey: e.task.id])
    }

    /// The click on a card notification opens that card.
    static func route(_ userInfo: [String: String]) -> NotificationRoute? {
        guard let board = userInfo[boardKey], !board.isEmpty, let task = userInfo[taskKey], !task.isEmpty else { return nil }
        return .openCard(board: board, task: task)
    }
}

// MARK: - hub API

extension KanbanHub {
    /// "Create Task from Message": shows the prefilled New Task sheet (KanbanComposePresenter).
    func composeTask(from seed: KanbanTaskSeed) {
        compose = KanbanComposeRequest(seed: seed, board: Self.composeBoard(rows: rows, boards: boards, last: lastBoard))
    }

    /// The board a composed task starts on: the last board opened, else Hermes' current one, else the first.
    static func composeBoard(rows: [KanbanSidebarRow], boards: [KanbanBoardSummary], last: String?) -> String? {
        let listed = Set(rows.map(\.slug))
        if let last, listed.contains(last) { return last }
        if let current = boards.first(where: { $0.isCurrent && listed.contains($0.slug) }) { return current.slug }
        return rows.first?.slug
    }
}

// MARK: - views

/// "Notify When Done or Blocked" as a toggle (card menu, inspector menu).
struct KanbanWatchToggle: View {
    @ObservedObject var watches: KanbanWatchList
    let slug: String
    let task: KanbanTask
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle("Notify When Done or Blocked", isOn: Binding(get: { watches.contains(slug, task.id) }, set: { onChange($0) }))
    }
}

/// Presents the composed New Task sheet; attached to the root view (it observes the hub, which the root view
/// does not).
struct KanbanComposePresenter: ViewModifier {
    @ObservedObject var hub: KanbanHub
    let bots: [String]
    let motion: Bool

    func body(content: Content) -> some View {
        content.motionSheet(isPresented: Binding(get: { hub.compose != nil }, set: { if !$0 { hub.compose = nil } }), motion: motion) {
            if let request = hub.compose {
                KanbanComposeSheet(hub: hub, request: request, bots: bots, onClose: { hub.compose = nil })
            }
        }
    }
}

/// The New Task sheet for a message, with a board picker.
struct KanbanComposeSheet: View {
    @ObservedObject var hub: KanbanHub
    let request: KanbanComposeRequest
    let bots: [String]
    let onClose: () -> Void
    @State private var board = ""

    static let defaultLanes = ["triage", "todo", "ready"]

    var body: some View {
        let slug = board.isEmpty ? (request.board ?? "") : board
        Group {
            if let model = slug.isEmpty ? nil : hub.model(for: slug) {
                KanbanComposeBody(model: model, request: request, bots: bots, rows: hub.rows,
                                  board: Binding(get: { slug }, set: { board = $0 }), onClose: onClose)
            } else {
                KanbanNewTaskSheet(lanes: Self.defaultLanes, assignees: bots, onCreate: { _, _ in
                    "No board to add it to. Turn on Kanban in Hermes or create a board first."
                }, onClose: onClose, initialTitle: request.seed.title, initialDetails: request.seed.text,
                   initialAssignee: request.seed.suggestedAssignee ?? "", subtitle: request.seed.source)
            }
        }
    }
}

private struct KanbanComposeBody: View {
    @ObservedObject var model: KanbanBoardModel
    let request: KanbanComposeRequest
    let bots: [String]
    let rows: [KanbanSidebarRow]
    @Binding var board: String
    let onClose: () -> Void

    var body: some View {
        let lanes = model.serverLanes.isEmpty ? KanbanComposeSheet.defaultLanes : model.serverLanes.map(\.name)
        let suggested = request.seed.suggestedAssignee ?? ""
        let names = Set(model.assigneeNames + bots + (suggested.isEmpty ? [] : [suggested])).sorted()
        KanbanNewTaskSheet(lanes: lanes, assignees: names,
                           onCreate: { draft, column in await model.create(draft, column: column) },
                           onClose: onClose, initialTitle: request.seed.title, initialDetails: request.seed.text,
                           initialAssignee: suggested, subtitle: request.seed.source, boards: rows, board: $board)
            .task(id: model.slug) { if model.assignees.isEmpty { await model.loadAssignees() } }
    }
}
