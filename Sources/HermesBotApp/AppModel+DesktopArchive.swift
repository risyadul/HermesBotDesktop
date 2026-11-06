import Foundation
import HermesGatewayKit

/// E4 / D17: the Desktop archive's app-level actions (DesktopArchiveModel.swift holds the archive itself).
extension AppModel {
    /// File → Import from Hermes Desktop…: opens the sheet and reads Desktop's rooms (read-only).
    func openDesktopImport() {
        showDesktopImport = true
        let call: DesktopGroupArchive.Call? = backend.map { b in
            let client = b.client
            return { method, params in try await client.call(method, params) }
        }
        Task { await desktopArchive.list(call: call) }
    }

    func closeDesktopImport() {
        showDesktopImport = false
        desktopArchive.resetListing()
    }

    /// Imports the chosen rooms and shows the first of them. Returns an error text, or nil.
    func importDesktopRooms(_ chosen: [DesktopArchiveRoom]) -> String? {
        let error = desktopArchive.importRooms(chosen)
        if let first = chosen.first { selection = .archive(first.id) }
        log("desktop archive: imported \(chosen.count) room(s)")
        return error
    }

    func removeArchivedRoom(_ id: String) {
        if selection == .archive(id) { selection = nil }
        if let error = desktopArchive.remove(id) { log(error) }
    }

    /// "Continue in a New Room": the New Group Chat sheet, prefilled (name, members, a carry-over draft).
    func continueArchivedRoom(_ room: DesktopArchiveRoom) {
        createRoomPrefill = DesktopArchivePresentation.prefill(room, bots: bots)
        showCreateRoom = true
    }

    /// The New Group Chat sheet's Create: a prefilled carry-over lands in the new room's composer (not sent).
    func createRoomFromSheet(name: String, members: [RoomMember]) async -> String? {
        let draft = createRoomPrefill?.draft
        let error = await createRoom(name: name, members: members)
        if error == nil, let draft, case .room(let id)? = selection {
            roomModel(id)?.setDraft(draft, thread: RoomThreads.main)
        }
        return error
    }

    func closeCreateRoom() {
        showCreateRoom = false
        createRoomPrefill = nil
    }
}
