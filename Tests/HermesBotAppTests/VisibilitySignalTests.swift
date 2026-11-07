import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Visibility: the main-window signal (`AppModel.mainWindowOnScreen`) pauses what only the main window shows
/// (Kanban, the selected Bot Chat's read mark); rooms and detached Bot Chats follow their OWN windows, so a
/// room or bot in a detached window stays live while the main window is hidden. Headless: the signals are
/// driven directly, no window is opened.
@MainActor
final class VisibilitySignalTests: XCTestCase {
    private var models: [RoomModel] = []

    override func tearDown() async throws {
        models.forEach { $0.shutdown() }
    }

    private func room() -> RoomModel {
        let m = RoomModel(room: RoomFixtures.room(), api: FakeRoomActions(rooms: [RoomFixtures.room()]))
        models.append(m)
        return m
    }

    func testAnOffScreenWindowPausesTheRoomPollerAndSeesNothing() {
        let m = room()
        m.start()
        XCTAssertTrue(m.isPolling)
        XCTAssertTrue(m.isOnScreen)
        m.setVisible(false)
        XCTAssertFalse(m.isPolling, "hidden / minimised / covered: no room polling")
        XCTAssertFalse(m.isOnScreen, "and nothing the pane shows counts as seen")
        let other = ObjectIdentifier(self)
        m.setVisible(false, viewer: other)  // its window reports before the pane appears
        m.start(viewer: other)
        XCTAssertFalse(m.isPolling, "a second viewer in a hidden window does not restart it")
        m.setVisible(true)
        XCTAssertTrue(m.isPolling, "back on screen: polling resumes for the viewers still there")
        XCTAssertTrue(m.isOnScreen)
        m.stopPolling()
        XCTAssertFalse(m.isPolling, "the only visible view left: the hidden one does not keep it polling")
        m.stopPolling(viewer: other)
        m.setVisible(false)
        m.setVisible(true)
        XCTAssertFalse(m.isPolling, "no viewer: coming back on screen starts nothing")
    }

    /// Review BLOCK-001: a room in its own window keeps polling while the main window is off screen.
    func testADetachedRoomKeepsPollingWhileTheMainWindowIsHidden() {
        let m = room()
        let main = PaneViewer(), detached = PaneViewer()
        m.start(viewer: main.id)
        m.start(viewer: detached.id)
        m.setVisible(false, viewer: main.id)
        XCTAssertTrue(m.isPolling, "main hidden, detached visible: still polling")
        XCTAssertTrue(m.isOnScreen)
        m.setVisible(false, viewer: detached.id)
        XCTAssertFalse(m.isPolling, "every window showing the room is hidden")
        XCTAssertFalse(m.isOnScreen)
        m.setVisible(true, viewer: main.id)
        XCTAssertTrue(m.isPolling, "main back, detached hidden")
        m.setVisible(true, viewer: detached.id)
        m.stopPolling(viewer: detached.id)
        XCTAssertTrue(m.isPolling, "closing the detached window keeps the main window's view live")
        m.setVisible(false, viewer: main.id)
        XCTAssertFalse(m.isPolling)
        m.start(viewer: detached.id)
        XCTAssertTrue(m.isPolling, "reopened detached window (not reported hidden): polls again")
    }

    func testTheMainWindowSignalLeavesRoomsToTheirOwnWindows() {
        let app = AppModel()
        let m = room()
        app.roomModels[m.id] = m
        let detached = PaneViewer()
        m.start(viewer: detached.id)
        app.selection = .bot("alice")
        XCTAssertEqual(app.botActivity.onScreen(), ["alice"])
        XCTAssertTrue(app.kanban.isActive)

        app.setMainWindowOnScreen(false)
        XCTAssertFalse(app.mainWindowOnScreen)
        XCTAssertTrue(m.isPolling, "the room's own (detached) window is still on screen")
        XCTAssertTrue(m.isOnScreen)
        XCTAssertEqual(app.botActivity.onScreen(), [], "the selected bot's chat is not on screen: nothing is marked read")
        XCTAssertFalse(app.kanban.isActive, "Kanban pauses on the main-window signal")

        app.setMainWindowOnScreen(true)
        XCTAssertTrue(m.isPolling)
        XCTAssertEqual(app.botActivity.onScreen(), ["alice"])
        XCTAssertTrue(app.kanban.isActive)
    }

    /// A Bot Chat in its own window counts as on screen (read as it happens) by that window's visibility.
    func testADetachedBotChatIsOnScreenByItsOwnWindow() {
        let app = AppModel()
        let pane = PaneViewer()
        app.setMainWindowOnScreen(false)
        app.botPaneAppeared("bob", viewer: pane.id)
        XCTAssertEqual(app.botsOnScreen, ["bob"], "main hidden, bob's window shows")
        app.setBotPaneVisible(false, bot: "bob", viewer: pane.id)
        XCTAssertEqual(app.botsOnScreen, [])
        app.setBotPaneVisible(true, bot: "bob", viewer: pane.id)
        app.selection = .bot("alice")
        app.setMainWindowOnScreen(true)
        XCTAssertEqual(app.botsOnScreen, ["alice", "bob"])
        app.botPaneDisappeared("bob", viewer: pane.id)
        XCTAssertEqual(app.botsOnScreen, ["alice"])
        XCTAssertNil(app.botPanes["bob"], "a closed window leaves nothing behind")
    }

    func testADisbandedRoomModelIsShutDown() {
        let app = AppModel()
        let m = room()
        app.rooms = [m.room]
        app.roomModels[m.id] = m
        m.start()
        XCTAssertTrue(m.isPolling)
        app.roomDisbanded(m.id)
        XCTAssertNil(app.roomModels[m.id])
        XCTAssertFalse(m.isPolling)
        m.start()
        XCTAssertFalse(m.isPolling, "shut down for good: a late view appearance does not restart it")
    }
}
