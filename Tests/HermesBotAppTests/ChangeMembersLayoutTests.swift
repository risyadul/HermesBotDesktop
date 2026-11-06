import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// The Change Members sheet (C2.2) on a real window: the prefilled form with many bots and the old room's
/// choice with long names, a failed carry-over and a failed disband stay inside the sheet width and the
/// 520 pt window minimum. Opt-in (`WindowTestGate`); `FakeRoomActions`, no backend.
@MainActor
final class ChangeMembersLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var rooms: [RoomModel] = []

    override func setUp() async throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        rooms.forEach { $0.shutdown() }
        rooms = []
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host<V: View>(_ view: V) -> NSSize {
        let controller = NSHostingController(rootView: view.environment(\.motionEnabled, false))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.orderFrontRegardless()
        windows.append(window)
        spin(0.6)
        return controller.view.fittingSize
    }

    private let longName = String(repeating: "Release planning crew ", count: 9).trimmingCharacters(in: .whitespaces)
    private var bots: [Bot] {
        (1...8).map { Bot(["name": .string("bot\($0)"), "display_name": .string("A rather long bot title number \($0)")])! }
    }

    private func change(api: FakeRoomActions) -> RoomMemberChange {
        let old = RoomModel(room: RoomFixtures.room(name: longName), api: api)
        rooms.append(old)
        return RoomMemberChange(old: old, mintId: { "hba-layout00001" })
    }

    func testFormFitsTheMinimumWindow() {
        let c = change(api: FakeRoomActions(rooms: []))
        let size = host(ChangeMembersSheet(change: c, bots: bots, onClose: {}))
        XCTAssertLessThanOrEqual(size.width, DS.Size.sheetWidth + 0.5, "\(size)")
        XCTAssertLessThanOrEqual(size.height, DS.Size.windowMinHeight, "\(size)")
    }

    func testOldRoomChoiceWithErrorsFitsTheMinimumWindow() async {
        let api = FakeRoomActions(rooms: [])
        api.failSend(GatewayClient.RPCError(code: 5112, message: String(repeating: "send refused ", count: 12), data: nil))
        api.failDisband(GatewayClient.RPCError(code: 5114, message: "room work is still stopping; try again in a moment", data: nil))
        let c = change(api: api)
        let members = bots.prefix(6).map { RoomMember.forBot($0)! }
        let error = await c.create(name: longName, members: Array(members))
        XCTAssertNil(error)
        c.choice = .disband
        let finished = await c.finish()
        XCTAssertFalse(finished)
        XCTAssertNotNil(c.finishError)
        let size = host(ChangeMembersSheet(change: c, bots: bots, onClose: {}))
        XCTAssertLessThanOrEqual(size.width, DS.Size.sheetWidth + 0.5, "\(size)")
        XCTAssertLessThanOrEqual(size.height, DS.Size.windowMinHeight, "\(size)")

        c.choice = .keep
        c.renameOld = true
        let keep = host(ChangeMembersSheet(change: c, bots: bots, onClose: {}))
        XCTAssertLessThanOrEqual(keep.width, DS.Size.sheetWidth + 0.5, "\(keep)")
        XCTAssertLessThanOrEqual(keep.height, DS.Size.windowMinHeight, "\(keep)")
    }
}
