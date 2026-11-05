import HermesGatewayKit
import SwiftUI

// C2.2 Change Members: the app's side of `RoomMemberChange` (the sidebar row of the new room, then the
// selection hand-over). The flow itself lives in RoomMemberChange.swift.

extension AppModel {
    /// A room `groups.create` just made goes to the top of the sidebar (New Group Chat selects it after;
    /// Change Members only once the old room's choice is made). Debug builds record it for scripted runs
    /// (`roomCreated`, EvidenceDriver.swift).
    func roomAdded(_ room: RoomSummary) {
#if DEBUG
        roomCreated(room)
#endif
        log("groups.create → \(room.roomId) members=\(room.members.map(\.handle))")
        rooms.removeAll { $0.roomId == room.roomId }
        rooms.insert(room, at: 0)
        notifications.rooms.setRooms(rooms)
    }

    /// The Change Members flow for `room` (room menu → Change Members…).
    func memberChange(for room: RoomModel) -> RoomMemberChange {
        let change = RoomMemberChange(old: room)
        change.onCreated = { [weak self] created in self?.roomAdded(created) }
        change.onFinished = { [weak self] created, note in
            guard let self else { return }
            withTransaction(SidebarView.selectionTransaction) { self.selection = .room(created.roomId) }
            if let note { roomModel(created.roomId)?.note(note) }
        }
        return change
    }
}
