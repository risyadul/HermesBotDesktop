import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Live UI test 2026-11-06 (round 2): the Routines toolbar button did not open its sheet, by AX press or a real
/// click. The sheet was a `motionSheet` anchored inside the ToolbarItem content. The button now only sets
/// `ChatModel.routinesShown` and `BotChatView` presents the sheet from the pane. The headless test pins the
/// state; the window test (opt-in, `WindowTestGate`) proves the pane really attaches the sheet. No backend:
/// the sheet's Routines calls fail with "not connected", nothing touches cron.
@MainActor
final class RoutinesSheetPresentationTests: XCTestCase {
    private let bot = Bot(["name": "hba-routines", "display_name": "Routines Bot"])!

    func testTheToolbarButtonOpensAndDoneClosesTheSheet() {
        let chat = ChatModel(bot: bot, opener: { _ in throw GatewayClient.ClientError.notConnected })
        chat.log = { _ in }
        XCTAssertFalse(chat.routinesShown, "closed until the button is pressed")
        var pressed = false
        let button = RoutinesToolbarButton(bot: bot) { pressed = true; chat.showRoutines() }
        button.action()
        XCTAssertTrue(pressed)
        XCTAssertTrue(chat.routinesShown, "the button sets the presentation state the pane presents from")
        chat.showRoutines()
        XCTAssertTrue(chat.routinesShown, "pressing it again leaves the sheet open")
        chat.routinesShown = false  // the sheet's Done (`onClose`)
        XCTAssertFalse(chat.routinesShown)
    }

    func testThePaneAttachesTheSheetToItsWindow() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let chat = ChatModel(bot: bot, opener: { _ in throw GatewayClient.ClientError.notConnected })
        chat.log = { _ in }
        let size = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BotChatView(chat: chat).environment(\.motionEnabled, false))
        window.orderFrontRegardless()
        defer {
            chat.routinesShown = false
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.orderOut(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(window.attachedSheet)

        chat.showRoutines()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let sheet = try XCTUnwrap(window.attachedSheet, "the Routines sheet is attached to the chat's window")
        XCTAssertEqual(sheet.frame.width, DS.Routines.sheetWidth, accuracy: 1)

        chat.routinesShown = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(window.attachedSheet, "Done closes it")
    }
}
