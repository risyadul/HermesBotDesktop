import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp

/// SwiftUI's `.sheet` kept its slide and dimmer fade with the motion gate
/// closed. The create-room sheet now goes through `motionSheet`, which runs the AppKit sheet itself.
/// These tests present a real sheet on a real window and sample the sheet window's on-screen bounds and
/// alpha from the window server while it opens and closes.
@MainActor
final class MotionSheetTests: XCTestCase {
    override func setUp() async throws { try WindowTestGate.requirePixelExactWindows() }

    private final class Box: ObservableObject { @Published var show = false }

    private struct Host: View {
        @ObservedObject var box: Box
        let motion: Bool
        var body: some View {
            Color.gray.frame(width: 700, height: 480)
                .motionSheet(isPresented: $box.show, motion: motion) {
                    VStack { Text("Sheet"); Button("Close") { box.show = false } }
                        .frame(width: 460, height: 240)
                }
        }
    }

    /// Distinct (bounds, alpha) states of this process's sheet windows, polled every 4 ms off the main thread.
    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String] = []
        private var running = true
        private let parent: Int
        init(parent: Int) {
            self.parent = parent
            let pid = ProcessInfo.processInfo.processIdentifier
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    let state = list.filter {
                        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                            && ($0[kCGWindowNumber as String] as? Int) != self.parent
                            && ($0[kCGWindowLayer as String] as? Int) == 0
                    }.map { w -> String in
                        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
                        let a = w[kCGWindowAlpha as String] as? Double ?? -1
                        return "y=\(Int(b["Y"] ?? -1)) a=\(String(format: "%.2f", a))"
                    }.sorted().joined(separator: "|")
                    lock.withLock { if states.last != state { states.append(state) } }
                    usleep(4000)
                }
            }
        }
        func stop() -> [String] { lock.withLock { running = false; return states } }
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Opens and closes the sheet; returns the distinct sheet-window states seen during each transition.
    private func transitions(motion: Bool) throws -> (open: [String], close: [String]) {
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 700, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(box: box, motion: motion))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.5)

        let opening = Sampler(parent: window.windowNumber)
        box.show = true
        spin(1.0)
        let open = opening.stop()
        XCTAssertNotNil(window.attachedSheet, "the sheet is attached once the binding is true")

        let closing = Sampler(parent: window.windowNumber)
        box.show = false
        spin(1.0)
        let close = closing.stop()
        XCTAssertNil(window.attachedSheet, "the sheet is gone once the binding is false")
        return (open, close)
    }

    func testMotionOffSheetOpensAndClosesInOneStep() throws {
        let (open, close) = try transitions(motion: false)
        // Only "no sheet" and the final frame at full alpha: no slide, no fade.
        XCTAssertEqual(open.count, 2, "open states: \(open)")
        XCTAssertEqual(open.first, "")
        XCTAssertTrue(open.last?.hasSuffix("a=1.00") == true, "open states: \(open)")
        XCTAssertEqual(close.count, 2, "close states: \(close)")
        XCTAssertEqual(close.last, "")
    }

    func testMotionOnSheetKeepsTheSystemTransition() throws {
        let (open, close) = try transitions(motion: true)
        XCTAssertGreaterThan(open.count, 4, "the native slide/fade has intermediate frames: \(open)")
        XCTAssertGreaterThan(close.count, 4, "the native slide/fade has intermediate frames: \(close)")
    }

    func testBindingFollowsASheetEndedOutsideTheBinding() throws {
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 700, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(box: box, motion: false))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.4)
        box.show = true
        spin(0.8)
        let sheet = try XCTUnwrap(window.attachedSheet)
        SheetTransition.run(motion: false) { window.endSheet(sheet) }  // e.g. AppKit closing it
        spin(0.4)
        XCTAssertFalse(box.show, "the binding resets when the sheet ends another way")
        box.show = true
        spin(0.8)
        XCTAssertNotNil(window.attachedSheet, "and the sheet can open again")
        box.show = false
        spin(0.8)
    }

    func testTransitionDurationFollowsTheGate() {
        var off: TimeInterval = -1, on: TimeInterval = -1
        SheetTransition.run(motion: false) { off = NSAnimationContext.current.duration }
        SheetTransition.run(motion: true) { on = NSAnimationContext.current.duration }
        XCTAssertEqual(off, 0)
        XCTAssertGreaterThan(on, 0, "motion on leaves the system duration alone")
    }
}
