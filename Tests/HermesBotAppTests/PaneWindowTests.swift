import Foundation
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D9: a Bot Chat or a room in its own window. The scene value round-trips (window restoration), the window's
/// content follows the app's models, and a room shown in two windows keeps ONE poller that stops only when the
/// last view leaves. Headless over `FakeRoomActions`.
@MainActor
final class PaneWindowTests: XCTestCase {
    private func bot(_ name: String) -> Bot { Bot(["name": .string(name)])! }

    // MARK: scene value

    func testSidebarItemTokensRoundTripThroughCodable() throws {
        let items: [SidebarItem] = [.bot("alpha"), .room("hba-123"), .board("default"), .archive("desk:1"), .bot("a:b")]
        for item in items {
            XCTAssertEqual(SidebarItem(token: item.token), item)
            let data = try JSONEncoder().encode(item)
            XCTAssertEqual(try JSONDecoder().decode(SidebarItem.self, from: data), item)
        }
        XCTAssertEqual(String(data: try JSONEncoder().encode([SidebarItem.room("r1")]), encoding: .utf8), #"["room:r1"]"#)
        XCTAssertNil(SidebarItem(token: "bot:"))
        XCTAssertNil(SidebarItem(token: "window:x"))
        XCTAssertThrowsError(try JSONDecoder().decode(SidebarItem.self, from: Data(#""nope""#.utf8)))
    }

    func testOnlyBotChatsAndRoomsOpenInAWindow() {
        XCTAssertTrue(SidebarItem.bot("a").opensInWindow)
        XCTAssertTrue(SidebarItem.room("r").opensInWindow)
        XCTAssertFalse(SidebarItem.board("b").opensInWindow)
        XCTAssertFalse(SidebarItem.archive("k").opensInWindow)
    }

    // MARK: window content

    func testWindowContentFollowsTheAppsBotsAndRooms() {
        let bots = [bot("alpha")], rooms = [RoomFixtures.room("hba-1")]
        XCTAssertEqual(DetachedPane.content(.bot("alpha"), connected: true, bots: bots, rooms: rooms), .bot(bots[0]))
        XCTAssertEqual(DetachedPane.content(.room("hba-1"), connected: true, bots: bots, rooms: rooms), .room("hba-1"))
        XCTAssertEqual(DetachedPane.content(.bot("alpha"), connected: false, bots: [], rooms: []), .waiting,
                       "a window restored at launch waits for the connection")
        guard case .gone = DetachedPane.content(.bot("gone"), connected: true, bots: bots, rooms: rooms) else {
            return XCTFail("a deleted bot says so")
        }
        guard case .gone = DetachedPane.content(.room("hba-2"), connected: true, bots: bots, rooms: rooms) else {
            return XCTFail("a disbanded room says so")
        }
        guard case .gone = DetachedPane.content(.board("default"), connected: true, bots: bots, rooms: rooms) else {
            return XCTFail("boards stay in the main window")
        }
        guard case .gone = DetachedPane.content(nil, connected: true, bots: bots, rooms: rooms) else {
            return XCTFail("no value")
        }
    }

    func testWindowUsesTheSameModelsAsTheMainWindow() {
        let app = AppModel()
        let alpha = bot("alpha")
        app.bots = [alpha]
        let main = app.chat(for: alpha)
        XCTAssertTrue(app.chat(for: alpha) === main, "a second window gets the same Bot Chat model (no second session)")
        app.chats = [:]
    }

    // MARK: viewers

    func testViewersCountOncePerViewerAndHiddenOnesAreNotOnScreen() {
        var v = PaneViewers()
        let a = PaneViewer(), b = PaneViewer()
        XCTAssertTrue(v.anyVisible, "nothing reported: on screen")
        v.add(a.id); v.add(a.id)
        v.remove(a.id)
        XCTAssertTrue(v.isEmpty, "registering twice is one viewer")
        v.add(a.id); v.add(b.id)
        v.setVisible(false, a.id)
        XCTAssertTrue(v.anyVisible, "b is still on screen")
        v.setVisible(false, b.id)
        XCTAssertFalse(v.anyVisible)
        v.remove(b.id)
        XCTAssertFalse(v.anyVisible)
        v.setVisible(true, a.id)
        XCTAssertTrue(v.anyVisible)
        v.removeAll()
        XCTAssertTrue(v.isEmpty)
    }

    func testRoomInTwoWindowsKeepsOnePollerUntilTheLastViewLeaves() async {
        let api = FakeRoomActions(rooms: [RoomFixtures.room()])
        let model = RoomModel(room: RoomFixtures.room(), api: api)
        defer { model.shutdown() }
        let main = PaneViewer(), window = PaneViewer()
        model.start(viewer: main.id)
        let generation = model.pollGeneration
        model.start(viewer: window.id)
        XCTAssertEqual(model.pollGeneration, generation, "the second window does not start a second poller")
        XCTAssertTrue(model.isOnScreen)
        model.stopPolling(viewer: main.id)
        XCTAssertTrue(model.isPolling, "closing the main window's pane keeps the other window live")
        XCTAssertTrue(model.isOnScreen)
        model.stopPolling(viewer: window.id)
        XCTAssertFalse(model.isPolling)
        XCTAssertFalse(model.isOnScreen)
        model.start(viewer: main.id)
        model.start(viewer: main.id)  // an extra onAppear
        model.stopPolling(viewer: main.id)
        XCTAssertFalse(model.isPolling, "a repeated appear cannot keep polling alive")
    }

    func testShutdownStopsEveryViewer() {
        let api = FakeRoomActions(rooms: [RoomFixtures.room()])
        let model = RoomModel(room: RoomFixtures.room(), api: api)
        model.start(viewer: PaneViewer().id)
        model.start()
        model.shutdown()
        XCTAssertFalse(model.isPolling)
        XCTAssertFalse(model.isOnScreen)
        model.start()
        XCTAssertFalse(model.isPolling, "never again after quit")
    }
}

/// D9 window test, local opt-in only (`HERMES_BOT_APP_WINDOW_TESTS=1`; not yet run on a CI runner): two real
/// windows show the same room model; closing one keeps polling for the other.
@MainActor
final class PaneWindowLiveTests: XCTestCase {
    func testTwoHostedRoomViewsShareOnePoller() async throws {
        try WindowTestGate.requirePixelExactWindows()
        let api = FakeRoomActions(rooms: [RoomFixtures.room()])
        let model = RoomModel(room: RoomFixtures.room(), api: api)
        defer { model.shutdown() }
        func host() -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: RoomView(model: model, activity: nil))
            w.orderFront(nil)
            return w
        }
        let first = host(), second = host()
        await eventually { model.isPolling && model.lastSync != nil }
        let generation = model.pollGeneration
        first.contentViewController = nil
        first.close()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.isPolling, "the other window still shows the room")
        XCTAssertEqual(model.pollGeneration, generation, "no restart, no second loop")
        second.contentViewController = nil
        second.close()
        await eventually { !model.isPolling }
    }
}
