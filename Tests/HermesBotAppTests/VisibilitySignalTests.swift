import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// One visibility signal (`AppModel.mainWindowOnScreen`): while no main window shows, the open room's poller
/// pauses and its pane counts nothing as seen, the shown bot is not marked read, and Kanban pauses; it all
/// resumes when a window is back. Headless: the signal is driven directly, no window is opened.
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
        m.setWindowOnScreen(false)
        XCTAssertFalse(m.isPolling, "hidden / minimised / covered: no room polling")
        XCTAssertFalse(m.isOnScreen, "and nothing the pane shows counts as seen")
        m.start(viewer: ObjectIdentifier(self))
        XCTAssertFalse(m.isPolling, "a second viewer does not restart it while off screen")
        m.setWindowOnScreen(true)
        XCTAssertTrue(m.isPolling, "back on screen: polling resumes for the viewers still there")
        XCTAssertTrue(m.isOnScreen)
        m.stopPolling()
        m.stopPolling(viewer: ObjectIdentifier(self))
        m.setWindowOnScreen(false)
        m.setWindowOnScreen(true)
        XCTAssertFalse(m.isPolling, "no viewer: coming back on screen starts nothing")
    }

    func testAppModelFansTheSignalOut() {
        let app = AppModel()
        let m = room()
        app.roomModels[m.id] = m
        m.start()
        app.selection = .bot("alice")
        XCTAssertEqual(app.botActivity.onScreen(), "alice")
        XCTAssertTrue(app.kanban.isActive)

        app.setMainWindowOnScreen(false)
        XCTAssertFalse(app.mainWindowOnScreen)
        XCTAssertFalse(m.isPolling)
        XCTAssertFalse(m.isOnScreen)
        XCTAssertNil(app.botActivity.onScreen(), "the selected bot's chat is not on screen: nothing is marked read")
        XCTAssertFalse(app.kanban.isActive, "Kanban pauses on the same signal")

        app.setMainWindowOnScreen(true)
        XCTAssertTrue(m.isPolling)
        XCTAssertEqual(app.botActivity.onScreen(), "alice")
        XCTAssertTrue(app.kanban.isActive)
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
