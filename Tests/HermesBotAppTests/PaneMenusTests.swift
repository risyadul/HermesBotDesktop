import XCTest
@testable import HermesBotApp

/// Room and bot actions are not sidebar-only: the room toolbar's Room menu carries the row's Open in New
/// Window / Save as Template / Mute, and the Bot Chat toolbar has a Bot menu with Edit / Duplicate / Delete /
/// Open in New Window / Mute. Both build from the same menu views as the sidebar rows, so they cannot drift.
/// A toolbar is not rendered headless, so this checks the wiring in the sources.
final class PaneMenusTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/HermesBotApp/\(file)"), encoding: .utf8)
    }

    func testTheRoomToolbarMenuHasTheRowActions() throws {
        let room = try source("RoomView.swift")
        let menu = try XCTUnwrap(room.range(of: "label: { Label(\"Room\""), "the Room toolbar menu")
        let body = room[..<menu.lowerBound]
        XCTAssertTrue(body.contains("SidebarItemMenu(item: .room(model.room.roomId)"), "Open in New Window, Save as Template, Mute")
    }

    func testTheBotChatToolbarHasABotMenuSharedWithTheSidebarRow() throws {
        let chat = try source("BotChatView.swift")
        XCTAssertTrue(chat.contains("Menu { BotManageMenu(bot: chat.bot"), "a Bot menu in the Bot Chat toolbar")
        XCTAssertTrue(chat.contains("Label(\"Bot\""))
        XCTAssertTrue(try source("SidebarView.swift").contains("BotManageMenu(bot: bot, model: model)"), "the row menu is the same view")
        let menus = try source("AppCommands.swift")
        let manage = try XCTUnwrap(menus.range(of: "struct BotManageMenu"))
        let rest = menus[manage.lowerBound...]
        for piece in ["model.editBot(", "model.duplicateBot(", "model.deleteBot(", "SidebarItemMenu(item: .bot("] {
            XCTAssertTrue(rest.contains(piece), piece)
        }
    }

    func testTheRowMenuOffersWindowTemplateAndMute() throws {
        let menus = try source("AppCommands.swift")
        for piece in ["Button(\"Open in New Window\")", "Button(\"Save as Template…\")", "NotificationMutes.menuTitle("] {
            XCTAssertTrue(menus.contains(piece), piece)
        }
    }
}
