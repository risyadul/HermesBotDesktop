import Foundation
import HermesGatewayKit
import SwiftUI

// C1.4: pin and reorder rooms in the sidebar. Local to this Mac (UserDefaults), never sent to Hermes: hosted
// rooms have no per-user ordering field. Pinned rooms come first; inside each group (pinned, unpinned) the
// user's order applies. Rooms the user never moved keep the backend order (`groups.list`: most recently
// updated first) and sit at the top of their group, so a new room is seen.

/// The saved order: pure value, every operation takes the order the sidebar shows right now.
struct RoomOrder: Equatable {
    /// Pinned room ids.
    var pinned: Set<String> = []
    /// Room ids in the order the user arranged them (pinned and unpinned alike); empty until the first move.
    var arranged: [String] = []

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// `rooms` (backend order) as the sidebar shows them.
    func sorted(_ rooms: [RoomSummary]) -> [RoomSummary] {
        let rank = Dictionary(arranged.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return rooms.enumerated().sorted { a, b in
            key(a.element.roomId, backend: a.offset, rank: rank) < key(b.element.roomId, backend: b.offset, rank: rank)
        }.map(\.element)
    }

    /// (group, never-arranged first, position): tuples compare left to right.
    private func key(_ id: String, backend: Int, rank: [String: Int]) -> (Int, Int, Int) {
        let group = pinned.contains(id) ? 0 : 1
        if let r = rank[id] { return (group, 1, r) }
        return (group, 0, backend)
    }

    /// Pins (at the end of the pinned rooms) or unpins (at the top of the others) `id`.
    func settingPinned(_ id: String, _ pin: Bool, shown: [String]) -> RoomOrder {
        guard shown.contains(id), pinned.contains(id) != pin else { return self }
        var next = RoomOrder(pinned: pinned, arranged: shown)
        next.arranged.removeAll { $0 == id }
        let lastPinned = next.arranged.lastIndex { pinned.contains($0) }.map { $0 + 1 } ?? 0
        next.arranged.insert(id, at: lastPinned)
        if pin { next.pinned.insert(id) } else { next.pinned.remove(id) }
        return next
    }

    enum Direction { case up, down }

    /// The neighbour `id` would swap with, within its own group; nil at the group's edge.
    func neighbour(of id: String, _ direction: Direction, shown: [String]) -> String? {
        guard let i = shown.firstIndex(of: id) else { return nil }
        let j = direction == .up ? i - 1 : i + 1
        guard shown.indices.contains(j), pinned.contains(shown[j]) == pinned.contains(id) else { return nil }
        return shown[j]
    }

    /// Move Up / Move Down in the room menu.
    func moving(_ id: String, _ direction: Direction, shown: [String]) -> RoomOrder {
        guard let other = neighbour(of: id, direction, shown: shown) else { return self }
        return moving(id, onto: other, shown: shown)
    }

    /// Drag and drop: `id` takes `target`'s place (after it when dragged down, before it when dragged up).
    /// Only inside one group: a pinned room cannot be dropped among the others, nor the other way round.
    func moving(_ id: String, onto target: String, shown: [String]) -> RoomOrder {
        guard id != target, canDrop(id, onto: target),
              let from = shown.firstIndex(of: id), let to = shown.firstIndex(of: target) else { return self }
        var list = shown
        list.remove(at: from)
        list.insert(id, at: to)
        return RoomOrder(pinned: pinned, arranged: list)
    }

    func canDrop(_ id: String, onto target: String) -> Bool { pinned.contains(id) == pinned.contains(target) }

    /// A disbanded room leaves the saved order.
    func forgetting(_ id: String) -> RoomOrder {
        var next = self
        next.pinned.remove(id)
        next.arranged.removeAll { $0 == id }
        return next
    }
}

/// The saved `RoomOrder`, observed by the sidebar. Tests pass their own `UserDefaults` suite.
@MainActor
final class RoomOrderStore: ObservableObject {
    static let shared = RoomOrderStore()

    static let pinnedKey = "hba.rooms.pinned"
    static let arrangedKey = "hba.rooms.arranged"
    /// What a drag carries: the room id behind a prefix, so text dragged in from elsewhere is never a move.
    static let dragPrefix = "hba-room-order:"

    @Published private(set) var order: RoomOrder
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = RoomOrder(pinned: Set(defaults.stringArray(forKey: Self.pinnedKey) ?? []),
                          arranged: defaults.stringArray(forKey: Self.arrangedKey) ?? [])
    }

    func sorted(_ rooms: [RoomSummary]) -> [RoomSummary] { order.sorted(rooms) }

    func isPinned(_ id: String) -> Bool { order.isPinned(id) }

    func setPinned(_ id: String, _ pin: Bool, rooms: [RoomSummary]) {
        save(order.settingPinned(id, pin, shown: shown(rooms)))
    }

    func canMove(_ id: String, _ direction: RoomOrder.Direction, rooms: [RoomSummary]) -> Bool {
        order.neighbour(of: id, direction, shown: shown(rooms)) != nil
    }

    func move(_ id: String, _ direction: RoomOrder.Direction, rooms: [RoomSummary]) {
        save(order.moving(id, direction, shown: shown(rooms)))
    }

    /// A drop of `payload` (a dragged room row) on `target`. False when it is not a room of this list or
    /// crosses the pinned / unpinned line.
    @discardableResult
    func drop(_ payload: String, onto target: String, rooms: [RoomSummary]) -> Bool {
        guard let id = Self.roomId(fromDrag: payload), rooms.contains(where: { $0.roomId == id }),
              id != target, order.canDrop(id, onto: target) else { return false }
        save(order.moving(id, onto: target, shown: shown(rooms)))
        return true
    }

    func forget(_ id: String) { save(order.forgetting(id)) }

    static func dragPayload(_ id: String) -> String { dragPrefix + id }

    static func roomId(fromDrag payload: String) -> String? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        let id = String(payload.dropFirst(dragPrefix.count))
        return id.isEmpty ? nil : id
    }

    private func shown(_ rooms: [RoomSummary]) -> [String] { order.sorted(rooms).map(\.roomId) }

    private func save(_ next: RoomOrder) {
        guard next != order else { return }
        order = next
        defaults.set(next.pinned.sorted(), forKey: Self.pinnedKey)
        defaults.set(next.arranged, forKey: Self.arrangedKey)
    }
}

// MARK: - sidebar row

extension View {
    /// A room row's ordering: the context menu (Open, Pin to Top / Unpin, Move Up, Move Down) and drag to
    /// reorder within its group.
    func roomOrdering(_ room: RoomSummary, rooms: [RoomSummary], store: RoomOrderStore,
                      onOpen: @escaping () -> Void) -> some View {
        modifier(RoomOrderingModifier(room: room, rooms: rooms, store: store, onOpen: onOpen))
    }
}

private struct RoomOrderingModifier: ViewModifier {
    let room: RoomSummary
    let rooms: [RoomSummary]
    @ObservedObject var store: RoomOrderStore
    let onOpen: () -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        let id = room.roomId, pinned = store.isPinned(id)
        content
            .overlay {
                // Where a dragged room lands: this row's place.
                if targeted {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.ring, lineWidth: DS.Stroke.keyboardFocus)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                Button("Open") { onOpen() }
                Divider()
                Button(pinned ? "Unpin" : "Pin to Top") { store.setPinned(id, !pinned, rooms: rooms) }
                Button("Move Up") { store.move(id, .up, rooms: rooms) }
                    .disabled(!store.canMove(id, .up, rooms: rooms))
                Button("Move Down") { store.move(id, .down, rooms: rooms) }
                    .disabled(!store.canMove(id, .down, rooms: rooms))
            }
            .draggable(RoomOrderStore.dragPayload(id))
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                return store.drop(payload, onto: id, rooms: rooms)
            } isTargeted: { over in
                targeted = over
            }
    }
}
