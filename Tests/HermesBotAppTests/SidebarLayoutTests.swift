import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// The sidebar divider at the 820 pt minimum window. With `sidebarMax` 320 the sidebar column could be
/// dragged to 328 pt; 328 + `detailMin` 540 = 868 > 820, so the outer split was laid out 868 pt wide and
/// centred, pushing the sidebar 24 pt past the window's leading edge (inspector shown or hidden), and a
/// window shrunk to the minimum with a wide sidebar did the same without any drag.
///
/// These tests host the real `RootView` on a real window with no backend and drag the dividers with
/// in-process mouse events, then assert rendered geometry: every split view, the sidebar, the composer
/// and the inspector column with its text lie inside the window.
@MainActor
final class SidebarLayoutTests: XCTestCase {
    private static let botNames = ["default", "android-implementer", "code-reviewer", "generalist", "orchestrator", "hba-layout"]
    private static let description = "Thief: explorer dan tester yang gesit di semua platform (mobile, web, desktop, "
        + "backend/API) pada environment DEV/staging; tanpa commit/push/Jira."
    /// The two window sizes the divider probes use. 520 is the window's minimum height; the content's
    /// own minimum height may make the actual window taller, and tags carry the actual height.
    private static let minimumSizes = [NSSize(width: DS.Size.windowMinWidth, height: 572),
                                       NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)]
    /// The sidebar column is the sidebar setting + 8 (measured).
    private static let widestSidebarColumn = DS.Size.sidebarMax + 8

    private let defaultsKeys = ["hba.botInspector", DS.Motion.settingKey]
    private let envKeys = ["HERMES_BOT_APP_LOCK_DIR", "HERMES_BOT_APP_NO_SPAWN"]
    private static let splitFramesPrefix = "NSSplitView Subview Frames"
    private var savedDefaults: [Any?] = []
    private var savedSplitFrames: [String: Any] = [:]
    private var savedEnv: [String?] = []
    private var lockDir: URL?
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
        savedSplitFrames = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.splitFramesPrefix) }
        savedEnv = envKeys.map { ProcessInfo.processInfo.environment[$0] }
        // No real backend: an empty lock dir and no spawn fallback.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-sidebar-locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lockDir = dir
        setenv("HERMES_BOT_APP_LOCK_DIR", dir.path, 1)
        setenv("HERMES_BOT_APP_NO_SPAWN", "1", 1)
        clearSplitFrames()
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        clearSplitFrames()
        savedSplitFrames.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        for (key, value) in zip(defaultsKeys, savedDefaults) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for (key, value) in zip(envKeys, savedEnv) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if let lockDir { try? FileManager.default.removeItem(at: lockDir) }
    }

    /// Split views autosave their column widths; a dragged sidebar must not leak between cases.
    private func clearSplitFrames() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Self.splitFramesPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - host

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func axElements(_ root: Any) -> [NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSAccessibilityProtocol] = []
        func visit(_ node: Any, _ depth: Int) {
            guard depth < 60, let element = node as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            result.append(element)
            (element.accessibilityChildren() ?? []).forEach { visit($0, depth + 1) }
            (node as? NSView)?.subviews.forEach { visit($0, depth + 1) }
        }
        visit(root, 0)
        return result
    }

    private func axLabel(_ e: NSAccessibilityProtocol) -> String {
        [e.accessibilityLabel(), e.accessibilityTitle(), e.accessibilityValue() as? String].compactMap { $0 }.joined(separator: " ")
    }

    private func host(size: NSSize, inspector: Bool) throws -> NSWindow {
        clearSplitFrames()
        UserDefaults.standard.set(inspector, forKey: "hba.botInspector")
        UserDefaults.standard.set(false, forKey: DS.Motion.settingKey)
        let model = AppModel()
        model.bots = try Self.botNames.map { name in
            var json: [String: JSONValue] = ["name": .string(name), "model": "gemini-3.8-flash-high",
                                             "provider": "antigravity", "skill_count": 97]
            if name == "hba-layout" { json["description"] = .string(Self.description) }
            return try XCTUnwrap(Bot(.object(json)))
        }
        model.selection = .bot(try XCTUnwrap(model.bots.last).name)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: model).modifier(MotionGate()))
        window.setContentSize(size)
        window.orderFrontRegardless()
        windows.append(window)
        spin(1.2)
        return window
    }

    private func resize(_ window: NSWindow, _ size: NSSize) {
        window.setContentSize(size)
        spin(0.6)
    }

    /// ⌥⌘I, the inspector toggle, delivered like a key press (motion off: one frame).
    private func toggleInspector(_ window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        XCTAssertTrue(window.performKeyEquivalent(with: event), "⌥⌘I was not handled")
        spin(0.5)
    }

    private func splitViews(_ window: NSWindow) -> [NSSplitView] {
        window.contentView.map { views($0).compactMap { $0 as? NSSplitView } } ?? []
    }

    private func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// A divider drag as in-process mouse events: down on `from`, two drags, up on `to`.
    private func drag(_ window: NSWindow, from: NSPoint, to: NSPoint) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The split view tracks the drag in a local loop entered from mouseDown: queue the rest first.
        NSApp.postEvent(event(.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: from.y)), atStart: false)
        NSApp.postEvent(event(.leftMouseDragged, to), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, to), atStart: false)
        window.sendEvent(event(.leftMouseDown, from))
        spin(0.8)
    }

    private func sidebarColumn(_ window: NSWindow) throws -> NSRect {
        frameInWindow(try XCTUnwrap(splitViews(window).first?.arrangedSubviews.first))
    }

    /// The sidebar divider dragged 200 pt right, well past any maximum.
    private func widenSidebar(_ window: NSWindow) throws -> NSRect {
        let f = try sidebarColumn(window)
        drag(window, from: NSPoint(x: f.maxX, y: f.midY), to: NSPoint(x: f.maxX + 200, y: f.midY))
        return try sidebarColumn(window)
    }

    /// The inspector's leading edge dragged 200 pt left, past its maximum.
    private func widenInspector(_ window: NSWindow) throws -> NSRect {
        let column = try XCTUnwrap(splitViews(window).dropFirst().first?.arrangedSubviews.last)
        let f = frameInWindow(column)
        drag(window, from: NSPoint(x: f.minX, y: f.midY), to: NSPoint(x: f.minX - 200, y: f.midY))
        return frameInWindow(try XCTUnwrap(splitViews(window).dropFirst().first?.arrangedSubviews.last))
    }

    private func record(_ line: String) {
        guard let dir = ProcessInfo.processInfo.environment["HBA_LAYOUT_EVIDENCE"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/sidebar-geometry.txt"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    private func screenshot(_ window: NSWindow, _ tag: String) {
        guard let dir = ProcessInfo.processInfo.environment["HBA_LAYOUT_EVIDENCE"], !dir.isEmpty else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", dir + "/sidebar-\(tag).png"]
        try? capture.run()
        capture.waitUntilExit()
    }

    private func heightTag(_ window: NSWindow) -> String { "\(Int(window.contentView?.bounds.width ?? 0))x\(Int(window.contentView?.bounds.height ?? 0))" }

    // MARK: - geometry

    /// Every split view, the sidebar column (not shifted), the composer and, when `inspector`, the
    /// inspector column and its text lie inside the window, measured at `width`.
    private func assertFits(_ window: NSWindow, inspector: Bool, width: CGFloat, tag: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        XCTAssertEqual(content.bounds.width, width, accuracy: 0.5, "\(tag): measured at the wrong window width", file: file, line: line)
        let bounds = content.bounds.insetBy(dx: -1, dy: -1)
        let all = views(content)
        let splits = all.compactMap { $0 as? NSSplitView }
        XCTAssertGreaterThanOrEqual(splits.count, 2, "\(tag): expected the sidebar split and the inspector split", file: file, line: line)
        var report = ["window \(content.bounds.size)"]
        for (i, split) in splits.enumerated() {
            let frame = frameInWindow(split)
            report.append("split\(i) \(frame)")
            XCTAssertTrue(bounds.contains(frame), "\(tag): split \(i) \(frame) overflows the window \(content.bounds)", file: file, line: line)
        }

        let sidebar = try XCTUnwrap(splits.first?.arrangedSubviews.first, file: file, line: line)
        let sidebarFrame = frameInWindow(sidebar)
        report.append("sidebar \(sidebarFrame)")
        XCTAssertFalse(sidebar.isHidden, "\(tag): sidebar hidden", file: file, line: line)
        XCTAssertEqual(sidebarFrame.minX, 0, accuracy: 0.5, "\(tag): sidebar \(sidebarFrame) shifted off the leading edge", file: file, line: line)
        XCTAssertTrue(bounds.contains(sidebarFrame), "\(tag): sidebar \(sidebarFrame) outside the window", file: file, line: line)
        let rows = views(sidebar).filter { abs($0.frame.height - DS.Size.rowHeight) < 0.5 && $0.frame.width > DS.Size.sidebarMin / 2 }
        XCTAssertGreaterThanOrEqual(rows.count, Self.botNames.count, "\(tag): \(rows.count) sidebar rows", file: file, line: line)
        for row in rows {
            let f = frameInWindow(row)
            XCTAssertTrue(bounds.contains(f), "\(tag): sidebar row \(f) clipped", file: file, line: line)
        }

        let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.isEditable }, "\(tag): no composer field", file: file, line: line)
        let fieldFrame = frameInWindow(field)
        report.append("composer \(fieldFrame)")
        XCTAssertTrue(bounds.contains(fieldFrame), "\(tag): composer field \(fieldFrame) outside the window", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, sidebarFrame.maxX, "\(tag): composer under the sidebar", file: file, line: line)

        let column = try XCTUnwrap(splits.dropFirst().first?.arrangedSubviews.last, file: file, line: line)
        if inspector {
            XCTAssertFalse(column.isHidden, "\(tag): inspector hidden", file: file, line: line)
            let columnFrame = frameInWindow(column)
            report.append("inspector \(columnFrame)")
            XCTAssertTrue(bounds.contains(columnFrame), "\(tag): inspector \(columnFrame) outside the window", file: file, line: line)
            func frame(_ e: NSAccessibilityProtocol) -> NSRect { window.convertFromScreen(e.accessibilityFrame()) }
            let texts = axElements(content).filter {
                $0.accessibilityRole() == .staticText && !frame($0).isEmpty && columnFrame.intersects(frame($0))
            }
            XCTAssertTrue(texts.contains { axLabel($0).hasPrefix("Thief: explorer") }, "\(tag): inspector About missing", file: file, line: line)
            for text in texts {
                XCTAssertTrue(columnFrame.insetBy(dx: -1, dy: -1).contains(frame(text)) && bounds.contains(frame(text)),
                              "\(tag): inspector text \(frame(text)) '\(axLabel(text).prefix(30))' clipped", file: file, line: line)
            }
        } else {
            XCTAssertTrue(column.isHidden, "\(tag): inspector still shown", file: file, line: line)
        }
        let summary = "SIDEBAR \(tag): " + report.joined(separator: " | ")
        print(summary)
        record(summary)
        screenshot(window, tag)
    }

    // MARK: - cases

    /// The sidebar dragged past its maximum at the minimum window, inspector shown and hidden, both sizes;
    /// with the inspector shown it is then dragged to its maximum too, and hidden and shown again.
    func testMinimumWindowSidebarDraggedToMaximum() throws {
        for size in Self.minimumSizes {
            for inspector in [true, false] {
                let window = try host(size: size, inspector: inspector)
                let tag = "\(heightTag(window))-req\(Int(size.height))-sidebar-max-inspector-\(inspector ? "on" : "hidden")"
                let sidebar = try widenSidebar(window)
                // The drag must reach the maximum, or the case proves nothing.
                XCTAssertEqual(sidebar.width, Self.widestSidebarColumn, accuracy: 1, "\(tag): sidebar \(sidebar) after the drag")
                try assertFits(window, inspector: inspector, width: size.width, tag: tag)
                if inspector {
                    let column = try widenInspector(window)
                    XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "\(tag): inspector \(column) after the drag")
                    try assertFits(window, inspector: true, width: size.width, tag: tag + "-inspector-max")
                }
                toggleInspector(window)
                resize(window, size)
                try assertFits(window, inspector: !inspector, width: size.width, tag: tag + "-toggled")
                toggleInspector(window)
                resize(window, size)
                try assertFits(window, inspector: inspector, width: size.width, tag: tag + "-toggled-back")
                window.orderOut(nil)
            }
        }
    }

    /// Sidebar (and inspector) widened in the default window, the window shrunk to the minimum and grown
    /// back: the shrink alone must not push the sidebar off the leading edge.
    func testDefaultWideSidebarResizedToMinimum() throws {
        for size in Self.minimumSizes {
            for inspector in [true, false] {
                let window = try host(size: DS.Size.windowDefault, inspector: inspector)
                let sidebar = try widenSidebar(window)
                XCTAssertEqual(sidebar.width, Self.widestSidebarColumn, accuracy: 1, "default: sidebar \(sidebar) after the drag")
                if inspector {
                    let column = try widenInspector(window)
                    XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "default: inspector \(column) after the drag")
                }
                let m = inspector ? "on" : "hidden"
                try assertFits(window, inspector: inspector, width: DS.Size.windowDefault.width, tag: "default-wide-inspector-\(m)")
                resize(window, size)
                try assertFits(window, inspector: inspector, width: size.width,
                               tag: "default-wide-to-\(heightTag(window))-req\(Int(size.height))-inspector-\(m)")
                resize(window, DS.Size.windowDefault)
                try assertFits(window, inspector: inspector, width: DS.Size.windowDefault.width, tag: "back-to-default-inspector-\(m)")
                window.orderOut(nil)
            }
        }
    }

    /// The sidebar's range is the token range: the drag stops at the maximum, also in a wide window.
    func testSidebarMaximumIsTheTokenInADefaultWindow() throws {
        let window = try host(size: DS.Size.windowDefault, inspector: true)
        let sidebar = try widenSidebar(window)
        XCTAssertEqual(sidebar.width, Self.widestSidebarColumn, accuracy: 1, "sidebar \(sidebar) after the drag")
        XCTAssertLessThanOrEqual(Self.widestSidebarColumn + DS.Size.detailMin, DS.Size.windowMinWidth,
                                 "the widest sidebar column and the detail minimum must fit the minimum window")
    }
}
