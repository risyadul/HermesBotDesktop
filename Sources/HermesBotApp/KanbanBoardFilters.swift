import HermesGatewayKit
import SwiftUI

// Kanban filters (roadmap K4), as Hermes Desktop's board filter menu (`plugins/kanban/board.tsx` `FilterMenu`):
// one profile (assignee) at a time, "Show archived" (`include_archived`, KanbanBoardModel.setIncludeArchived)
// and "Group Running by profile" (Desktop's persisted `lanesByProfile`). The profile filter is client-side,
// like Desktop's: `GET /board` has no assignee parameter.

enum KanbanProfileFilter {
    /// Desktop's lane label for running cards without an assignee (`UNASSIGNED_LANE`).
    static let unassigned = "unassigned"

    /// Only the cards assigned to `assignee` (nil = every card).
    static func apply(_ lanes: [KanbanLane], assignee: String?) -> [KanbanLane] {
        guard let assignee else { return lanes }
        return lanes.map { KanbanLane(name: $0.name, tasks: $0.tasks.filter { $0.assignee == assignee }) }
    }

    /// The Running lane split by assignee, groups sorted by name (Desktop: `localeCompare`), cards in lane order.
    static func groups(_ tasks: [KanbanTask]) -> [(name: String, tasks: [KanbanTask])] {
        var order: [String] = []
        var byName: [String: [KanbanTask]] = [:]
        for t in tasks {
            let key = t.assignee ?? unassigned
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(t)
        }
        return order.sorted { $0.localizedCompare($1) == .orderedAscending }.map { ($0, byName[$0] ?? []) }
    }

    /// Whether `lane` is drawn in profile groups.
    static func groupsLane(_ lane: KanbanLane, enabled: Bool) -> Bool {
        enabled && lane.name == "running" && !lane.tasks.isEmpty
    }

    /// The filter button reads as on while any filter narrows or widens the board (Desktop's `active`).
    static func isActive(assignee: String?, archived: Bool) -> Bool { assignee != nil || archived }
}

/// The board header's filter menu: All profiles / one profile, Show archived, Group Running by profile.
struct KanbanFilterMenu: View {
    @Binding var assignee: String?
    let profiles: [String]
    let archived: Bool
    let onArchived: (Bool) -> Void
    @Binding var groupRunning: Bool

    var body: some View {
        Menu {
            Section("Profile") {
                Button { assignee = nil } label: { check("All profiles", assignee == nil) }
                ForEach(profiles, id: \.self) { name in
                    Button { assignee = name } label: { check("@\(name)", assignee == name) }
                }
            }
            Divider()
            Button { onArchived(!archived) } label: { check("Show archived", archived) }
            Button { groupRunning.toggle() } label: { check("Group Running by profile", groupRunning) }
        } label: {
            Label(assignee.map { "@\($0)" } ?? "Filters",
                  systemImage: KanbanProfileFilter.isActive(assignee: assignee, archived: archived)
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by profile, show archived cards, group Running by profile")
        .accessibilityLabel("Filters")
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// A profile group's caption inside the Running lane: avatar, @name (or "unassigned"), count.
struct KanbanLaneGroupHeader: View {
    let name: String
    let count: Int
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        HStack(spacing: DS.Space.s1 + DS.Space.s0) {
            if name != KanbanProfileFilter.unassigned {
                AvatarView(identity: avatars.identity(profile: name), size: DS.Size.avatarPass)
            }
            Text(name == KanbanProfileFilter.unassigned ? name : "@\(name)")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
            Text("\(count)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s1).padding(.top, DS.Space.s1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
