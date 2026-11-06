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

    /// Live UI test 2026-11-06 (round 5): the board header's actions menu was a bare `ellipsis.circle` at
    /// header size, read as ⊖ ("remove"), placed between the board switcher and the filter. It is titled
    /// "Board" with the symbol, like the Room and Bot menus, and is the header's trailing control.
    func testTheBoardMenuIsTitledAndTrailing() throws {
        let menu = try source("KanbanBoardManagement.swift")
        let start = try XCTUnwrap(menu.range(of: "struct KanbanBoardMenu"))
        let body = menu[start.lowerBound...]
        XCTAssertTrue(body.contains("Label(\"Board\", systemImage: \"ellipsis.circle\")"), "the symbol pane menus use, titled")
        XCTAssertFalse(body.prefix(1500).contains("minus.circle"))
        XCTAssertTrue(body.contains(".accessibilityLabel(\"Board actions\")"))

        let board = try source("KanbanBoardView.swift")
        let header = try XCTUnwrap(board.range(of: "private var header: some View {"))
        let end = try XCTUnwrap(board.range(of: "@ViewBuilder private var noteBar", range: header.upperBound..<board.endIndex))
        let headerBody = board[header.upperBound..<end.lowerBound]
        let menuAt = try XCTUnwrap(headerBody.range(of: "KanbanBoardMenu("), "the Board menu is in the header")
        for control in ["TextField(\"Filter", "KanbanFilterMenu(", "Label(\"Workers\"", "DispatcherChipView("] {
            let at = try XCTUnwrap(headerBody.range(of: control), control)
            XCTAssertLessThan(at.lowerBound, menuAt.lowerBound, "\(control) comes before the trailing Board menu")
        }
    }

    func testTheRowMenuOffersWindowTemplateAndMute() throws {
        let menus = try source("AppCommands.swift")
        for piece in ["Button(\"Open in New Window\")", "Button(\"Save as Template…\")", "NotificationMutes.menuTitle("] {
            XCTAssertTrue(menus.contains(piece), piece)
        }
    }
}
