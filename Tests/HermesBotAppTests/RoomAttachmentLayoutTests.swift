import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// C2.1 / C1.8 on a real window: a deleted copy's chip (long name, the plain-words note) stays within the chip
/// width, and a room picture draws at the row avatar size in place of the stacked avatars. Opt-in
/// (`WindowTestGate`); temp files only, nothing in Application Support.
@MainActor
final class RoomAttachmentLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var root: URL!

    override func setUp() async throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoomAttachmentLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func host<V: View>(_ view: V) -> NSSize {
        let controller = NSHostingController(rootView: view.environment(\.motionEnabled, false))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.orderFrontRegardless()
        windows.append(window)
        spin(0.8)
        return controller.view.fittingSize
    }

    func testDeletedCopyChipStaysWithinTheChipWidth() {
        let name = String(repeating: "quarterly-report-final-", count: 6) + "v2.pdf"
        let ref = MediaRef(path: root.appendingPathComponent("hba-x/0000/\(name)").path, kind: .pdf)
        let size = host(RoomAttachmentView(ref: ref, ownCopy: true).padding(1))
        XCTAssertLessThanOrEqual(size.width, DS.Size.mediaChipMax + 2.5, "\(size)")
        XCTAssertGreaterThan(size.height, 0)
    }

    func testRoomPictureReplacesTheStackedAvatars() throws {
        let pictures = RoomPictureStore(root: root.appendingPathComponent("pictures"))
        let png = root.appendingPathComponent("pic.png")
        try RoomPictureTests.pngData().write(to: png)
        try pictures.setPicture(room: "hba-1", from: png)
        let size = host(RoomAvatar(roomId: "hba-1", identities: [], pictures: pictures))
        XCTAssertEqual(size.width, DS.Size.avatarRow, accuracy: 0.5)
        XCTAssertEqual(size.height, DS.Size.avatarRow, accuracy: 0.5)
    }
}
