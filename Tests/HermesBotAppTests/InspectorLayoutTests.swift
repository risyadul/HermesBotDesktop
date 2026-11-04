import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Bot Chat at the 820 pt minimum window with the inspector shown: the inspector split was laid out
/// 864 pt wide inside the 820 pt window, so the inspector sat at x 624…864 and its About text ran 44 pt
/// past the window edge. The chat column's intrinsic minimum width was inflated by the inspector split.
///
/// These tests host the real `RootView` (sidebar, detail, toolbar, inspector) on a real window with no
/// backend (empty lock dir, spawn off) and assert rendered geometry: every split view, the inspector
/// column and its text, the sidebar rows and the composer lie inside the window.
@MainActor
final class InspectorLayoutTests: XCTestCase {
    private static let longDescription = "Thief: explorer dan tester yang gesit di semua platform (mobile, web, desktop, "
        + "backend/API) pada environment DEV/staging; menjalankan login/auth (lp-dev-login atau kredensial DEV), uji "
        + "runtime, reproduksi bug, dan probe edge case tanpa banyak gate. Batas: bukan production, tanpa aksi "
        + "destruktif di akun DEV bersama, tanpa commit/push/Jira."
    private static let botNames = ["default", "android-implementer", "code-reviewer", "generalist", "orchestrator", "hba-layout"]
    private static let minimum = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
    /// A composer field narrower than this would not show a typed word next to the placeholder.
    private static let composerFieldFloor: CGFloat = 120

    private let defaultsKeys = ["hba.botInspector", DS.Motion.settingKey]
    private let envKeys = ["HERMES_BOT_APP_LOCK_DIR", "HERMES_BOT_APP_NO_SPAWN"]
    private var savedDefaults: [Any?] = []
    /// Split views autosave their column widths; a dragged sidebar must not leak into later tests.
    private var savedSplitFrames: [String: Any] = [:]
    private static let splitFramesPrefix = "NSSplitView Subview Frames"
    private var savedEnv: [String?] = []
    private var lockDir: URL?
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
        savedSplitFrames = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.splitFramesPrefix) }
        savedEnv = envKeys.map { ProcessInfo.processInfo.environment[$0] }
        // `RootView` connects on appear: point discovery at an empty lock dir and forbid the spawn
        // fallback, so the test never attaches to or starts a real backend.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-layout-locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lockDir = dir
        setenv("HERMES_BOT_APP_LOCK_DIR", dir.path, 1)
        setenv("HERMES_BOT_APP_NO_SPAWN", "1", 1)
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Self.splitFramesPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        savedSplitFrames.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        for (key, value) in zip(defaultsKeys, savedDefaults) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for (key, value) in zip(envKeys, savedEnv) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if let lockDir { try? FileManager.default.removeItem(at: lockDir) }
    }

    // MARK: - host

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// Accessibility elements under `root` (AX children and subviews), each once.
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

    private struct Hosted {
        let window: NSWindow
        let model: AppModel
    }

    private func host(size: NSSize, inspector: Bool, motion: Bool, description: String? = longDescription,
                      transcript: Bool = false) throws -> Hosted {
        UserDefaults.standard.set(inspector, forKey: "hba.botInspector")
        UserDefaults.standard.set(motion, forKey: DS.Motion.settingKey)
        let model = AppModel()
        model.bots = try Self.botNames.map { name in
            var json: [String: JSONValue] = ["name": .string(name), "model": "gemini-3.8-flash-high",
                                             "provider": "antigravity", "skill_count": 97]
            if name == "hba-layout", let description { json["description"] = .string(description) }
            return try XCTUnwrap(Bot(.object(json)))
        }
        let bot = try XCTUnwrap(model.bots.last)
        model.selection = .bot(bot.name)
        if transcript {
            // A never-connected client: the submit adds the user line, the session open fails fast and
            // adds an error line. Nothing leaves the process.
            let backend = Backend(mode: .spawned(pid: 0, port: 9), client: GatewayClient(url: URL(string: "ws://127.0.0.1:9")!),
                                  ready: .null, verdicts: [], owned: nil)
            XCTAssertTrue(model.chat(for: bot).submit(String(repeating: "A long message that wraps in the chat column. ", count: 6),
                                                      backend: backend, title: "hba-layout"))
        }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: model).modifier(MotionGate()))
        window.setContentSize(size)
        window.orderFrontRegardless()
        windows.append(window)
        spin(1.2)
        return Hosted(window: window, model: model)
    }

    /// ⌥⌘I, the inspector toggle's keyboard shortcut, delivered to the window like a key press.
    private func toggleInspector(_ window: NSWindow, motion: Bool) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        XCTAssertTrue(window.performKeyEquivalent(with: event), "⌥⌘I was not handled")
        spin(motion ? 1.0 : 0.5)
    }

    private func splitViews(_ window: NSWindow) -> [NSSplitView] {
        window.contentView.map { views($0).compactMap { $0 as? NSSplitView } } ?? []
    }

    private func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// A divider drag delivered as in-process mouse events: down on `from`, two drags, up on `to`.
    private func drag(_ window: NSWindow, from: NSPoint, to: NSPoint) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The split view tracks the drag in a local event loop entered from mouseDown, so the rest of
        // the gesture is queued first.
        NSApp.postEvent(event(.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: from.y)), atStart: false)
        NSApp.postEvent(event(.leftMouseDragged, to), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, to), atStart: false)
        window.sendEvent(event(.leftMouseDown, from))
        spin(0.8)
    }

    /// The inspector column's leading edge dragged far left: the inspector grows to its maximum.
    private func widenInspector(_ window: NSWindow) throws -> NSRect {
        let column = try XCTUnwrap(splitViews(window).dropFirst().first?.arrangedSubviews.last)
        let f = frameInWindow(column)
        drag(window, from: NSPoint(x: f.minX, y: f.midY), to: NSPoint(x: f.minX - 200, y: f.midY))
        return frameInWindow(try XCTUnwrap(splitViews(window).dropFirst().first?.arrangedSubviews.last))
    }

    /// The sidebar divider dragged to `x`; returns the sidebar column frame afterwards.
    private func dragSidebar(_ window: NSWindow, to x: CGFloat) throws -> NSRect {
        let sidebar = try XCTUnwrap(splitViews(window).first?.arrangedSubviews.first)
        let f = frameInWindow(sidebar)
        drag(window, from: NSPoint(x: f.maxX, y: f.midY), to: NSPoint(x: x, y: f.midY))
        return frameInWindow(try XCTUnwrap(splitViews(window).first?.arrangedSubviews.first))
    }

    private func screenshot(_ window: NSWindow, _ tag: String) {
        guard let dir = ProcessInfo.processInfo.environment["HBA_LAYOUT_EVIDENCE"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", dir + "/\(tag).png"]
        try? capture.run()
        capture.waitUntilExit()
    }

    // MARK: - geometry

    /// Asserts that the window shows the sidebar, the composer and (when `inspector`) the whole inspector.
    private func assertFits(_ hosted: Hosted, inspector: Bool, tag: String, width: CGFloat? = nil,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let window = hosted.window
        screenshot(window, tag)
        let content = try XCTUnwrap(window.contentView)
        if let width {
            XCTAssertEqual(content.bounds.width, width, accuracy: 0.5, "\(tag): measured at the wrong window width", file: file, line: line)
        }
        let bounds = content.bounds.insetBy(dx: -1, dy: -1)
        let all = views(content)
        let splits = all.compactMap { $0 as? NSSplitView }
        XCTAssertGreaterThanOrEqual(splits.count, 2, "\(tag): expected the sidebar split and the inspector split", file: file, line: line)

        var report: [String] = ["window \(content.bounds.size)"]
        for (i, split) in splits.enumerated() {
            let frame = split.convert(split.bounds, to: nil)
            report.append("split\(i) \(frame) columns \(split.arrangedSubviews.map { "\($0.isHidden ? "hidden" : "\($0.convert($0.bounds, to: nil))")" })")
            XCTAssertTrue(bounds.contains(frame), "\(tag): split \(i) \(frame) overflows the window \(content.bounds)", file: file, line: line)
        }

        // Sidebar: the leading column of the outer split, at least its minimum width, rows inside it.
        let outer = splits[0]
        let sidebar = try XCTUnwrap(outer.arrangedSubviews.first, file: file, line: line)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        XCTAssertFalse(sidebar.isHidden, "\(tag): sidebar hidden", file: file, line: line)
        XCTAssertGreaterThanOrEqual(sidebarFrame.width, DS.Size.sidebarMin, "\(tag): sidebar \(sidebarFrame)", file: file, line: line)
        XCTAssertTrue(bounds.contains(sidebarFrame), "\(tag): sidebar \(sidebarFrame) outside the window", file: file, line: line)

        // Sidebar rows (one 44 pt button per bot; SwiftUI exposes them in-process as unlabeled views).
        let rows = views(sidebar).filter { abs($0.frame.height - DS.Size.rowHeight) < 0.5 && $0.frame.width > DS.Size.sidebarMin / 2 }
        XCTAssertGreaterThanOrEqual(rows.count, Self.botNames.count, "\(tag): \(rows.count) sidebar rows", file: file, line: line)
        for row in rows {
            let f = row.convert(row.bounds, to: nil)
            XCTAssertTrue(bounds.contains(f) && sidebarFrame.insetBy(dx: -1, dy: -1).contains(f), "\(tag): sidebar row \(f) clipped", file: file, line: line)
        }

        // Composer: editable field and the Send button inside the window, wide enough to type into.
        let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.isEditable }, "\(tag): no composer field", file: file, line: line)
        let fieldFrame = field.convert(field.bounds, to: nil)
        XCTAssertTrue(bounds.contains(fieldFrame), "\(tag): composer field \(fieldFrame) outside the window", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fieldFrame.width, Self.composerFieldFloor, "\(tag): composer field \(fieldFrame) too narrow", file: file, line: line)
        let sendSize = NSSize(width: DS.Size.buttonMinWidth, height: DS.Size.controlHeight)
        let send = all.map { $0.convert($0.bounds, to: nil) }.first {
            abs($0.width - sendSize.width) < 0.5 && abs($0.height - sendSize.height) < 0.5 && $0.minX >= fieldFrame.maxX && abs($0.midY - fieldFrame.midY) < sendSize.height
        }
        let sendFrame = try XCTUnwrap(send, "\(tag): no Send button beside the composer field", file: file, line: line)
        XCTAssertTrue(bounds.contains(sendFrame), "\(tag): Send \(sendFrame) outside the window", file: file, line: line)

        let elements = axElements(content)
        func frame(_ e: NSAccessibilityProtocol) -> NSRect { window.convertFromScreen(e.accessibilityFrame()) }
        // SwiftUI vends a fresh proxy per parent, so the same text can be reached more than once.
        var textKeys = Set<String>()
        let texts = elements.filter {
            $0.accessibilityRole() == .staticText && !frame($0).isEmpty && textKeys.insert("\(frame($0))|\(axLabel($0))").inserted
        }

        // Inspector: the trailing column of the inner split; its text stays inside it and the window.
        let inner = splits[1]
        let column = try XCTUnwrap(inner.arrangedSubviews.last, file: file, line: line)
        let about = texts.first { axLabel($0).hasPrefix("Thief: explorer") && !sidebarFrame.contains(frame($0)) }
        if inspector {
            XCTAssertFalse(column.isHidden, "\(tag): inspector hidden", file: file, line: line)
            let columnFrame = column.convert(column.bounds, to: nil)
            XCTAssertTrue(bounds.contains(columnFrame), "\(tag): inspector \(columnFrame) outside the window \(content.bounds)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(columnFrame.width, DS.Size.inspectorMin - 1, "\(tag): inspector \(columnFrame)", file: file, line: line)
            XCTAssertLessThanOrEqual(sendFrame.maxX, columnFrame.minX, "\(tag): composer runs under the inspector", file: file, line: line)
            for scroll in views(column).compactMap({ $0 as? NSScrollView }) {
                let doc = scroll.documentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
                XCTAssertLessThanOrEqual(doc.width, columnFrame.width + 1, "\(tag): inspector content \(doc) wider than its column", file: file, line: line)
            }
            let inspectorTexts = texts.filter { columnFrame.intersects(frame($0)) }
            for label in ["Thief: explorer", "gemini-3.8-flash-high", "antigravity", "97"] {
                XCTAssertTrue(inspectorTexts.contains { axLabel($0).contains(label) }, "\(tag): inspector field \(label) missing", file: file, line: line)
            }
            for text in inspectorTexts {
                XCTAssertTrue(columnFrame.insetBy(dx: -1, dy: -1).contains(frame(text)) && bounds.contains(frame(text)),
                              "\(tag): inspector text \(frame(text)) '\(axLabel(text).prefix(30))' clipped by \(columnFrame) / window \(content.bounds)",
                              file: file, line: line)
            }
            if let about {
                XCTAssertTrue(columnFrame.insetBy(dx: -1, dy: -1).contains(frame(about)), "\(tag): About \(frame(about)) clipped by \(columnFrame)", file: file, line: line)
            } else {
                XCTFail("\(tag): inspector About text missing", file: file, line: line)
            }
        } else {
            XCTAssertTrue(column.isHidden, "\(tag): inspector still shown", file: file, line: line)
        }
        report.append("composer field \(fieldFrame) send \(sendFrame) sidebar \(sidebarFrame) rows \(rows.count)")
        if inspector, let about { report.append("about \(frame(about))") }
        let summary = "geometry \(tag):\n  " + report.joined(separator: "\n  ") + "\n"
        if testRun?.failureCount ?? 0 > 0 { print(summary) }
        if let dir = ProcessInfo.processInfo.environment["HBA_LAYOUT_EVIDENCE"], !dir.isEmpty,
           let handle = FileHandle(forWritingAtPath: dir + "/geometry.txt") ?? {
               FileManager.default.createFile(atPath: dir + "/geometry.txt", contents: nil)
               return FileHandle(forWritingAtPath: dir + "/geometry.txt")
           }() {
            handle.seekToEndOfFile()
            handle.write(Data(summary.utf8))
            try? handle.close()
        }
    }

    // MARK: - cases

    func testMinimumWindowInspectorShownMotionOff() throws {
        let h = try host(size: Self.minimum, inspector: true, motion: false)
        try assertFits(h, inspector: true, tag: "min-inspector-on-motion-off")
    }

    func testMinimumWindowInspectorShownMotionOn() throws {
        let h = try host(size: Self.minimum, inspector: true, motion: true)
        try assertFits(h, inspector: true, tag: "min-inspector-on-motion-on")
    }

    /// Opened with the inspector hidden, then shown and hidden with ⌥⌘I, motion off and on. Showing the
    /// inspector may grow the window natively (motion off: 820 → 1060); the window is put back to the
    /// minimum before measuring, so every check below is at 820 pt.
    func testMinimumWindowInspectorToggle() throws {
        for motion in [false, true] {
            let h = try host(size: Self.minimum, inspector: false, motion: motion)
            let m = motion ? "on" : "off"
            let width = Self.minimum.width
            try assertFits(h, inspector: false, tag: "min-inspector-off-motion-\(m)", width: width)
            toggleInspector(h.window, motion: motion)
            let grown = try XCTUnwrap(h.window.contentView).bounds.width
            if grown > width {
                try assertFits(h, inspector: true, tag: "min-toggled-on-motion-\(m)-native-\(Int(grown))", width: grown)
                h.window.setContentSize(Self.minimum)
                spin(0.6)
            }
            try assertFits(h, inspector: true, tag: "min-toggled-on-motion-\(m)", width: width)
            toggleInspector(h.window, motion: motion)
            h.window.setContentSize(Self.minimum)
            spin(0.6)
            try assertFits(h, inspector: false, tag: "min-toggled-off-motion-\(m)", width: width)
            h.window.orderOut(nil)
        }
    }

    func testDefaultWindowInspectorShownAndToggled() throws {
        let h = try host(size: DS.Size.windowDefault, inspector: true, motion: true)
        try assertFits(h, inspector: true, tag: "default-inspector-on-motion-on")
        toggleInspector(h.window, motion: true)
        try assertFits(h, inspector: false, tag: "default-toggled-off-motion-on")
        toggleInspector(h.window, motion: true)
        try assertFits(h, inspector: true, tag: "default-toggled-on-motion-on")
    }

    func testDefaultWindowInspectorShownMotionOff() throws {
        let h = try host(size: DS.Size.windowDefault, inspector: true, motion: false)
        try assertFits(h, inspector: true, tag: "default-inspector-on-motion-off")
    }

    /// A chat with messages (transcript instead of the empty state) at the minimum size.
    func testMinimumWindowTranscriptInspectorShown() throws {
        let h = try host(size: Self.minimum, inspector: true, motion: false, transcript: true)
        let chat = try XCTUnwrap(h.model.chats["hba-layout"])
        XCTAssertFalse(chat.lines.isEmpty)
        try assertFits(h, inspector: true, tag: "min-transcript-inspector-on")
    }

    /// The window grown from the minimum back to the default keeps everything inside.
    func testResizeMinimumToDefault() throws {
        let h = try host(size: Self.minimum, inspector: true, motion: false)
        h.window.setContentSize(DS.Size.windowDefault)
        spin(0.6)
        try assertFits(h, inspector: true, tag: "resized-min-to-default")
        h.window.setContentSize(Self.minimum)
        spin(0.6)
        try assertFits(h, inspector: true, tag: "resized-back-to-min")
    }

    // MARK: - divider drags and resize at the minimum

    /// The window is asked for 820 × 520; the content's own minimum height (toolbar, composer) makes the
    /// actual window 820 × 572. Tags carry the actual height.
    private func heightTag(_ h: Hosted) -> String { "min\(Int(h.window.contentView?.bounds.height ?? 0))" }
    /// The widest sidebar column that still fits beside `DS.Size.detailMin` at the minimum width.
    private static let widestFittingSidebar = DS.Size.windowMinWidth - DS.Size.detailMin

    /// The inspector dragged to its maximum at the minimum window, motion off and on, both heights.
    func testMinimumWindowInspectorDraggedToMaximum() throws {
        for motion in [false, true] {
            let h = try host(size: Self.minimum, inspector: true, motion: motion)
            let tag = "\(heightTag(h))-inspector-max-motion-\(motion ? "on" : "off")"
            let column = try widenInspector(h.window)
            // The drag must have reached the maximum, or the case proves nothing.
            XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "\(tag): inspector \(column) after the drag")
            try assertFits(h, inspector: true, tag: tag, width: Self.minimum.width)
            h.window.orderOut(nil)
        }
    }

    /// The widest sidebar column that fits (280) plus the inspector at its maximum: the tightest case.
    func testMinimumWindowWidestSidebarAndInspectorMaximum() throws {
        for motion in [false, true] {
            let size = Self.minimum
            let h = try host(size: size, inspector: true, motion: motion)
            let tag = "\(heightTag(h))-sidebar280-inspector-max-motion-\(motion ? "on" : "off")"
            let sidebar = try dragSidebar(h.window, to: Self.widestFittingSidebar)
            XCTAssertEqual(sidebar.width, Self.widestFittingSidebar, accuracy: 1, "\(tag): sidebar \(sidebar) after the drag")
            try assertFits(h, inspector: true, tag: tag + "-before", width: size.width)
            let column = try widenInspector(h.window)
            XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "\(tag): inspector \(column) after the drag")
            try assertFits(h, inspector: true, tag: tag, width: size.width)
            // Hidden and shown again at that width.
            toggleInspector(h.window, motion: motion)
            h.window.setContentSize(size)
            spin(0.6)
            try assertFits(h, inspector: false, tag: tag + "-hidden", width: size.width)
            toggleInspector(h.window, motion: motion)
            h.window.setContentSize(size)
            spin(0.6)
            try assertFits(h, inspector: true, tag: tag + "-shown-again", width: size.width)
            h.window.orderOut(nil)
        }
    }

    /// Inspector widened in the default window, then the window shrunk to the minimum and grown back.
    func testDefaultWideInspectorResizedToMinimum() throws {
        for motion in [false, true] {
            let h = try host(size: DS.Size.windowDefault, inspector: true, motion: motion)
            let m = motion ? "on" : "off"
            let column = try widenInspector(h.window)
            XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "default: inspector \(column) after the drag")
            try assertFits(h, inspector: true, tag: "default-inspector-max-motion-\(m)", width: DS.Size.windowDefault.width)
            h.window.setContentSize(Self.minimum)
            spin(0.6)
            try assertFits(h, inspector: true, tag: "default-wide-to-\(heightTag(h))-motion-\(m)", width: Self.minimum.width)
            h.window.setContentSize(DS.Size.windowDefault)
            spin(0.6)
            try assertFits(h, inspector: true, tag: "default-wide-min-back-to-default-motion-\(m)", width: DS.Size.windowDefault.width)
            h.window.orderOut(nil)
        }
    }

    /// Widest fitting sidebar in the default window with the inspector at its maximum, then shrunk.
    func testDefaultWideColumnsResizedToMinimum() throws {
        let h = try host(size: DS.Size.windowDefault, inspector: true, motion: false)
        let sidebar = try dragSidebar(h.window, to: Self.widestFittingSidebar)
        XCTAssertEqual(sidebar.width, Self.widestFittingSidebar, accuracy: 1, "sidebar \(sidebar) after the drag")
        let column = try widenInspector(h.window)
        XCTAssertEqual(column.width, DS.Size.inspectorMax, accuracy: 1, "inspector \(column) after the drag")
        h.window.setContentSize(Self.minimum)
        spin(0.6)
        try assertFits(h, inspector: true, tag: "default-sidebar280-inspector-max-to-\(heightTag(h))", width: Self.minimum.width)
    }
}
