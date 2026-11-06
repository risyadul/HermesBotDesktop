import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Native-window coverage for long histories. All data comes from fakes; these tests never connect to
/// Hermes. Opt in with HERMES_BOT_APP_WINDOW_TESTS=1. Timings are evidence, not machine-speed assertions.
@MainActor
final class LongTranscriptWindowTests: XCTestCase {
    private static let botEnd = "HBA long Bot Chat history ends here"
    private static let roomEnd = "HBA long Group Chat history ends here"
    private static let roomLatest = "HBA newest appended Group Chat reply ends here"
    private static let roomAfterJump = "HBA reply after returning to the latest messages"
    private let defaultsKeys = ["hba.botInspector", "hba.roomActivity"]
    private var savedDefaults: [Any?] = []
    private var savedSplitFrames: [String: Any] = [:]
    private var didPrepare = false
    private var windows: [NSWindow] = []
    private var chats: [ChatModel] = []
    private var rooms: [RoomModel] = []

    override func setUp() async throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
        savedSplitFrames = UserDefaults.standard.dictionaryRepresentation().filter {
            $0.key.hasPrefix("NSSplitView Subview Frames")
        }
        didPrepare = true
        // Keep the transcript viewport comparable across developer machines and CI.
        defaultsKeys.forEach { UserDefaults.standard.set(false, forKey: $0) }
    }

    override func tearDown() async throws {
        for (index, window) in windows.enumerated() {
            dumpGeometry(window, stage: "teardown")
            capture(window, name: "\(name.replacingOccurrences(of: "/", with: "-"))-\(index)")
        }
        windows.forEach { $0.contentViewController = nil; $0.orderOut(nil); $0.close() }
        windows = []
        chats.forEach { $0.close() }; chats = []
        rooms.forEach { $0.shutdown() }; rooms = []
        guard didPrepare else { return }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        savedSplitFrames.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        for (key, value) in zip(defaultsKeys, savedDefaults) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private final class Columns: ObservableObject {
        @Published var visibility: NavigationSplitViewVisibility = .all
    }

    private struct Host<Detail: View>: View {
        @ObservedObject var columns: Columns
        let detail: Detail

        var body: some View {
            NavigationSplitView(columnVisibility: $columns.visibility) {
                List {
                    Text("Long history fixture")
                    Text("Alpha")
                    Text("Beta")
                }
                .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarWidth, max: DS.Size.sidebarMax)
            } detail: {
                detail.frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.motionEnabled, true)
        }
    }

    private func host<Detail: View>(_ detail: Detail, columns: Columns) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Herald long transcript test · \(name)"
        window.contentViewController = NSHostingController(rootView: Host(columns: columns, detail: detail))
        // NSHostingController can resize a freshly attached window to its fitting size.
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    private static func message(_ index: Int) -> String {
        switch index % 4 {
        case 0:
            return "History \(index): inspect the reconnect path and preserve the user's current scroll position. "
                + String(repeating: "The next poll may add another answer while this message is being read. ", count: 5)
        case 1:
            return """
            ### Measurements for turn \(index)

            | Component | Result | Notes |
            | --- | --- | --- |
            | Gateway | ready | Reused the existing connection |
            | Transcript | retained | Older rows remain available |
            | Sidebar | visible | Width changes reflow these cells |

            The table is followed by **ordinary prose**, an `inline value`, and a second paragraph.
            """
        case 2:
            return """
            Turn \(index) checks:
            - Keep the current conversation.
            - Read earlier tool output.
            - Return to the latest reply when ready.

            ```swift
            let revision = \(index)
            print("history revision", revision)
            ```
            """
        default:
            return "History \(index): checked the worker log.\n\n> Earlier findings still apply.\n\nThe connection remains idle."
        }
    }

    private func makeChat(tall: Bool = false) throws -> ChatModel {
        // 600 persisted rows including settled tools, reasoning, tables and wrapped paragraphs.
        var history = (0..<600).map { index -> ChatHistoryMessage in
            if index % 5 == 0 {
                return ChatHistoryMessage(role: .user, text: "Review iteration \(index). " + Self.message(index), rowId: index + 1)
            }
            if index % 5 == 2 {
                return ChatHistoryMessage(role: .tool, text: "Inspection complete", toolName: "read_file",
                                          toolContext: "Sources/Transcript.swift · iteration \(index)", rowId: index + 1)
            }
            return ChatHistoryMessage(role: .assistant, text: Self.message(index) + (tall && index > 570 ? Self.tallReply : ""),
                                      reasoning: index % 11 == 0 ? "Compare the log with the earlier result." : nil,
                                      rowId: index + 1)
        }
        history.append(ChatHistoryMessage(role: .assistant, text: Self.botEnd, rowId: 601))
        let link = FakeChatLink(history: history)
        let bot = try XCTUnwrap(Bot(["name": "hba-long-transcript", "display_name": "Long history bot"]))
        let chat = ChatModel(bot: bot, opener: { _ in link })
        chat.log = { _ in }
        chats.append(chat)
        return chat
    }

    private func makeRoom(tall: Bool = false) -> (RoomModel, FakeRoomActions, [RoomEvent]) {
        let room = RoomFixtures.room("hba-long-transcript", name: "Long history room")
        let api = FakeRoomActions(rooms: [room])
        var events = (1...600).map { index -> RoomEvent in
            index % 5 == 1
                ? RoomFixtures.user(index, Self.message(index))
                : RoomFixtures.member(index, index.isMultiple(of: 2) ? "alpha" : "beta",
                                      Self.message(index) + (tall && index > 570 ? Self.tallReply : ""))
        }
        events.append(RoomFixtures.member(601, "alpha", Self.roomEnd))
        api.setEvents(room.roomId, events)
        let model = RoomModel(room: room, api: api)
        rooms.append(model)
        return (model, api, events)
    }

    private static var tallReply: String {
        let paragraphs = (1...24).map { i in
            "\n\n### Detailed finding \(i)\n\n" + String(repeating: "Preserve the reader's position while comparing the active turn with earlier findings. ", count: 12)
        }.joined()
        let table = "\n\n| Component | Result | Detail |\n| --- | --- | --- |\n"
            + (1...50).map { "| Component \($0) | Checked | A wrapping measurement that must stay aligned when the sidebar changes width |" }.joined(separator: "\n")
        return paragraphs + table + "\n\n```swift\n" + String(repeating: "let retained = history.last // no lost updates\n", count: 80) + "```"
    }

    func testTallBotRepliesStayVisibleWhileScrollingAndResizing() async throws {
        let chat = try makeChat(tall: true), columns = Columns()
        let window = host(BotChatView(chat: chat), columns: columns)
        try await waitUntil { chat.isReady && self.visibleMarker(Self.botEnd, in: window) }
        try await exerciseTallRows(window)
        if !visibleMarker(Self.botEnd, in: window) {
            try clickJumpToLatest(window)
            try await waitUntil { self.visibleMarker(Self.botEnd, in: window) }
        }
        try await exerciseColumns(window, columns: columns, marker: Self.botEnd) {}
    }

    func testTallRoomRepliesStayVisibleWhileScrollingAndResizing() async throws {
        let (model, _, _) = makeRoom(tall: true), columns = Columns()
        let window = host(RoomView(model: model, activity: nil), columns: columns)
        try await waitUntil { model.timeline.cursor == 601 && self.visibleMarker(Self.roomEnd, in: window) }
        try await exerciseTallRows(window)
        if !visibleMarker(Self.roomEnd, in: window) {
            try clickJumpToLatest(window)
            try await waitUntil { self.visibleMarker(Self.roomEnd, in: window) }
        }
        try await exerciseColumns(window, columns: columns, marker: Self.roomEnd) {}
    }

    private func exerciseTallRows(_ window: NSWindow) async throws {
        let scroll = try transcriptScroll(window)
        try await settle(scroll)
        let step = Int32(effectiveViewport(scroll).height / 2)
        // Sample during a gesture across several multi-screen messages, not only after settling.
        for direction: Int32 in [1, -1] {
            try sendWheel(to: scroll, pixels: direction * step)
            for _ in 0..<14 {
                try sendWheel(to: scroll, pixels: direction * step)
                try await Task.sleep(for: .milliseconds(35))
                try assertUsable(window)
            }
            try sendWheel(to: scroll, pixels: 0)
        }
        try await settle(scroll)
    }

    func testLongBotChatOpensAtTheEndAndSurvivesSidebarAndWidthChanges() async throws {
        let chat = try makeChat(), columns = Columns()
        let started = Date()
        let window = host(BotChatView(chat: chat), columns: columns)
        try await waitUntil { chat.isReady && self.visibleMarker(Self.botEnd, in: window) }
        try await settle(try transcriptScroll(window))
        print("[long-transcript] Bot Chat open \(Date().timeIntervalSince(started))s; \(chat.lines.count) lines")
        XCTAssertGreaterThanOrEqual(chat.presentation.items.count, 500)
        let snapshot = chat.presentation
        try assertUsable(window)
        try await exerciseColumns(window, columns: columns, marker: Self.botEnd) {
            XCTAssertTrue(chat.presentation === snapshot, "sidebar/width changes must reuse the history snapshot")
        }
        capture(window, name: "bot-long-history")
    }

    func testLongRoomOpensAtTheEndAndSurvivesSidebarAndWidthChanges() async throws {
        let (model, _, _) = makeRoom()
        let columns = Columns(), started = Date()
        let window = host(RoomView(model: model, activity: nil), columns: columns)
        try await waitUntil { model.timeline.cursor == 601 && self.visibleMarker(Self.roomEnd, in: window) }
        try await settle(try transcriptScroll(window))
        print("[long-transcript] Group Chat open \(Date().timeIntervalSince(started))s; \(model.lines.count) lines")
        XCTAssertGreaterThanOrEqual(model.presentation.rows.count, 500)
        let snapshot = model.presentation
        try assertUsable(window)
        try await exerciseColumns(window, columns: columns, marker: Self.roomEnd) {
            XCTAssertTrue(model.presentation === snapshot, "sidebar/width changes must reuse the room snapshot")
        }
        capture(window, name: "room-long-history")
    }

    func testLongRoomKeepsTheReadersHistoryPositionWhenAnotherReplyArrives() async throws {
        let (model, api, events) = makeRoom()
        let columns = Columns()
        let window = host(RoomView(model: model, activity: nil), columns: columns)
        try await waitUntil { model.timeline.cursor == 601 && self.visibleMarker(Self.roomEnd, in: window) }
        let scroll = try transcriptScroll(window)
        try await settle(scroll)
        let clip = scroll.contentView
        try await scrollBack(scroll)
        let before = try readingLandmark(window)
        let oldTail = model.presentation.tailStart
        XCTAssertFalse(visibleMarker(Self.roomEnd, in: window), "the fixture must actually be reading older messages")
        let started = Date()
        // More than one eager-tail step forces existing rows to move between the eager and lazy
        // parents. A single short append can miss that identity/estimated-height boundary entirely.
        let additions = (602...(602 + EagerTail.step)).map { seq in
            let text = Self.message(seq)
                + String(repeating: "\nAnother measured detail for this turn.", count: seq % 4 * 4)
                + (seq == 602 + EagerTail.step ? "\n\n" + Self.roomLatest : "")
            return RoomFixtures.member(seq, seq.isMultiple(of: 2) ? "beta" : "alpha", text)
        }
        api.setEvents(model.id, events + additions)
        model.nudge()
        try await waitUntil { model.timeline.cursor == additions.last?.seq }
        try await settle(scroll)
        XCTAssertGreaterThan(model.presentation.tailStart, oldTail, "the fixture must cross the eager/lazy parent boundary")
        print("[long-transcript] Group Chat \(additions.count)-message append while reading \(Date().timeIntervalSince(started))s; tail \(oldTail) → \(model.presentation.tailStart); anchor \(before.label.prefix(75))")
        XCTAssertGreaterThan(distanceToBottom(scroll), clip.bounds.height,
                             "a background room reply must not pull the reader to the bottom")
        let viewport = screenViewport(scroll, window: window)
        let matching = accessibilityElements(try XCTUnwrap(scroll.documentView)).filter { accessibilityText($0) == before.label }
        let retained = matching.first { $0.accessibilityFrame().intersects(viewport) }
        let retainedFrame = try XCTUnwrap(retained, "the same history message must remain visible after rows migrate between eager and lazy parents")
            .accessibilityFrame()
        XCTAssertLessThan(abs((retainedFrame.midY - viewport.minY) - before.offset), viewport.height / 2,
                          "appended replies must preserve the visible message's position, even when numeric document estimates change")
        let snapshot = model.presentation
        try await exerciseReadingColumns(window, columns: columns) {
            XCTAssertTrue(model.presentation === snapshot, "reading/sidebar changes must reuse the room snapshot")
        }
        try assertUsable(window)
        capture(window, name: "room-history-after-append")
        try clickJumpToLatest(window)
        try await waitUntil { self.visibleMarker(Self.roomLatest, in: window) }
        try await settle(try transcriptScroll(window))
        capture(window, name: "room-after-jump-to-latest")
        // A jump resumes following, rather than merely scrolling once while leaving the reader paused.
        let next = RoomFixtures.member(613, "beta", Self.roomAfterJump)
        api.setEvents(model.id, events + additions + [next])
        model.nudge()
        try await waitUntil { model.timeline.cursor == 613 && self.visibleMarker(Self.roomAfterJump, in: window) }
        try await settle(try transcriptScroll(window))
        XCTAssertLessThanOrEqual(distanceToBottom(try transcriptScroll(window)), TranscriptFollow.slack + 2)
        capture(window, name: "room-auto-follow-after-jump")
    }

    func testLongBotChatKeepsTheReadersHistoryVisibleAcrossSidebarAndWidthChanges() async throws {
        let chat = try makeChat(), columns = Columns()
        let window = host(BotChatView(chat: chat), columns: columns)
        try await waitUntil { chat.isReady && self.visibleMarker(Self.botEnd, in: window) }
        let scroll = try transcriptScroll(window)
        try await settle(scroll)
        try await scrollBack(scroll)
        XCTAssertFalse(visibleMarker(Self.botEnd, in: window), "the fixture must be reading older Bot Chat messages")
        let snapshot = chat.presentation
        try await exerciseReadingColumns(window, columns: columns) {
            XCTAssertTrue(chat.presentation === snapshot, "reading/sidebar changes must reuse the Bot Chat snapshot")
        }
        capture(window, name: "bot-history-after-sidebar")
        try clickJumpToLatest(window)
        try await waitUntil { self.visibleMarker(Self.botEnd, in: window) }
        try await settle(try transcriptScroll(window))
        capture(window, name: "bot-after-jump-to-latest")
    }

    @MainActor private final class GestureEvents {
        var began = 0
        var changed = 0
        var ended = 0
    }

    private func scrollBack(_ scroll: NSScrollView) async throws {
        let clip = scroll.contentView
        if let window = scroll.window { dumpGeometry(window, stage: "before-scroll-back") }
        let counts = GestureEvents(), center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { counts.began += 1 }
            },
            center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { counts.changed += 1 }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { counts.ended += 1 }
            },
        ]
        defer { tokens.forEach { center.removeObserver($0) } }
        // Mutating NSClipView.bounds alone can leave SwiftUI's scroll-position binding and rendered
        // rows unchanged. Deliver a real phased wheel gesture to this scroll view, inside this process.
        // No event is posted to the system event stream or to another application.
        try sendWheel(to: scroll, pixels: 0)
        let step = Int32(ceil(clip.bounds.height * 6 / 18))
        for _ in 0..<18 {
            try sendWheel(to: scroll, pixels: step)
            try await Task.sleep(for: .milliseconds(16))
        }
        try sendWheel(to: scroll, pixels: 0)
        print("[long-transcript] scoped native wheel notifications began=\(counts.began) changed=\(counts.changed) ended=\(counts.ended)")
        try await waitUntil { self.distanceToBottom(scroll) > clip.bounds.height * 2 }
        try await settle(scroll)
        if let window = scroll.window {
            dumpGeometry(window, stage: "after-scroll-back")
            capture(window, name: "\(name)-reading-history")
        }
    }

    private func sendWheel(to scroll: NSScrollView, pixels: Int32) throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: pixels, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Unphased mouse-wheel events return synchronously. AppKit List can enter a native tracking
        // loop for a phased begin and wait for subsequent system events; directly invoking that loop
        // from an async XCTest would block delivery of its synthetic end event.
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        if let window = scroll.window {
            let viewport = screenViewport(scroll, window: window)
            // CGEvent uses a top-left screen origin, whereas AppKit screen rectangles are bottom-left.
            event.location = CGPoint(x: viewport.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - viewport.midY)
        }
        let native = try XCTUnwrap(NSEvent(cgEvent: event))
        scroll.scrollWheel(with: native)
    }

    private struct Landmark {
        let label: String
        let offset: CGFloat
    }

    private func readingLandmark(_ window: NSWindow) throws -> Landmark {
        let scroll = try transcriptScroll(window)
        let viewport = screenViewport(scroll, window: window)
        let candidates = accessibilityElements(try XCTUnwrap(scroll.documentView)).compactMap { element -> Landmark? in
            let label = accessibilityText(element), frame = element.accessibilityFrame()
            guard label.contains("History "), frame.intersects(viewport), frame.height < viewport.height else { return nil }
            return Landmark(label: label, offset: frame.midY - viewport.minY)
        }
        return try XCTUnwrap(candidates.min { abs($0.offset - viewport.height / 2) < abs($1.offset - viewport.height / 2) },
                             "an identifiable history message must be visible before changing the transcript")
    }

    /// Resizing rewraps prose, so exact pixels need not stay fixed. The same message must remain near the
    /// viewport, and the reader must remain in history rather than being anchored to the latest reply.
    private func exerciseReadingColumns(_ window: NSWindow, columns: Columns, checkCache: () -> Void) async throws {
        let anchor = try readingLandmark(window)
        let started = Date()
        func checkReading() throws {
            let current = try transcriptScroll(window)
            let viewport = screenViewport(current, window: window)
            XCTAssertGreaterThan(distanceToBottom(current), current.contentView.bounds.height,
                                 "sidebar/width changes must not jump a reader to the latest reply")
            let matching = accessibilityElements(try XCTUnwrap(current.documentView)).filter { accessibilityText($0) == anchor.label }
            XCTAssertTrue(matching.contains { $0.accessibilityFrame().intersects(viewport.insetBy(dx: 0, dy: -viewport.height / 2)) },
                          "the message being read must remain within half a viewport of the visible history")
            checkCache()
            try assertUsable(window)
        }
        withAnimation(DS.Motion.ease) { columns.visibility = .detailOnly }
        dumpGeometry(window, stage: "before-hide-sidebar-reading")
        try await waitUntil { self.sidebarHidden(window) == true }
        try await settle(try transcriptScroll(window))
        try checkReading()
        withAnimation(DS.Motion.ease) { columns.visibility = .all }
        try await waitUntil { self.sidebarHidden(window) == false }
        try await settle(try transcriptScroll(window))
        try checkReading()
        window.setContentSize(NSSize(width: 1040, height: 680))
        try await settle(try transcriptScroll(window))
        try checkReading()
        print("[long-transcript] sidebar/resize while reading history \(Date().timeIntervalSince(started))s; anchor \(anchor.label.prefix(75))")
    }

    private func exerciseColumns(_ window: NSWindow, columns: Columns, marker: String,
                                 checkCache: () -> Void) async throws {
        let started = Date()
        withAnimation(DS.Motion.ease) { columns.visibility = .detailOnly }
        dumpGeometry(window, stage: "before-hide-sidebar-bottom")
        try await waitUntil { self.sidebarHidden(window) == true }
        try await waitUntil { self.visibleMarker(marker, in: window) }
        try await settle(try transcriptScroll(window))
        checkCache()
        try assertUsable(window)
        withAnimation(DS.Motion.ease) { columns.visibility = .all }
        try await waitUntil { self.sidebarHidden(window) == false }
        window.setContentSize(NSSize(width: 940, height: 680))
        try await waitUntil { self.visibleMarker(marker, in: window) }
        try await settle(try transcriptScroll(window))
        checkCache()
        try assertUsable(window)
        print("[long-transcript] hide/show sidebar and resize \(Date().timeIntervalSince(started))s")
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func transcriptScroll(_ window: NSWindow) throws -> NSScrollView {
        try XCTUnwrap(findTranscriptScroll(window), "the transcript observer must be hosted in a native scroll view")
    }

    /// Polling must not call XCTest assertions: a view can legitimately be absent during its first layout.
    private func findTranscriptScroll(_ window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        return allViews(content).compactMap { $0 as? TranscriptTableScrollView }.first
    }

    private func distanceToBottom(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        let visible = document.convert(effectiveViewport(scroll), from: scroll).intersection(document.bounds)
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    private func assertUsable(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        let field = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.isEditable },
                                 "composer must remain available", file: file, line: line)
        let frame = field.convert(field.bounds, to: content)
        XCTAssertTrue(content.bounds.insetBy(dx: -2, dy: -2).contains(frame), "composer clipped: \(frame)", file: file, line: line)
        XCTAssertGreaterThan(frame.width, 120, file: file, line: line)
        let scroll = try transcriptScroll(window)
        XCTAssertGreaterThan(effectiveViewport(scroll).width, 300, file: file, line: line)
        XCTAssertGreaterThan(effectiveViewport(scroll).height, 150, file: file, line: line)
        let table = try XCTUnwrap(scroll as? TranscriptTableScrollView, file: file, line: line)
        XCTAssertTrue(table.tracker.nativeAttached, "the native coordinator must own this viewport", file: file, line: line)
        XCTAssertLessThan(table.createdCellCount, 160,
                          "long histories must reuse a small pool of visible cells", file: file, line: line)
        // Use the composited content view: caching a tall hosted cell through its scroll view can
        // return only background even while the actual window visibly contains text.
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds), file: file, line: line)
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let screenContent = window.convertToScreen(content.convert(content.bounds, to: nil))
        let viewport = screenViewport(scroll, window: window).intersection(screenContent)
        let composerTop = field.accessibilityFrame().maxY + DS.Size.fieldInset + DS.Space.s2 * 2
        // Exclude the entire jump overlay too: its text must not make an empty transcript pass.
        let lower = max(viewport.minY + 24, composerTop + DS.Space.s3 + DS.Size.controlHeight + 24)
        let upper = min(viewport.maxY - 24, screenContent.maxY - 80)
        let screenRegion = CGRect(x: viewport.minX + 24, y: lower,
                                  width: max(0, viewport.width - 48), height: max(0, upper - lower))
        XCTAssertGreaterThan(screenRegion.height, 100, "the sampled region must exclude chrome", file: file, line: line)
        let region = TranscriptViewportPixels.pixelRect(screenRegion: screenRegion, screenContent: screenContent, bitmap: bitmap)
        XCTAssertGreaterThan(TranscriptViewportPixels.contrast(bitmap, in: region), 0.15,
                             "the actual transcript viewport must draw content, not a blank surface", file: file, line: line)
    }

    /// A laid-out accessibility element for the final message must intersect the actual viewport. A row
    /// merely existing somewhere in the lazy document is not evidence that opening it drew the bottom.
    private func visibleMarker(_ marker: String, in window: NSWindow) -> Bool {
        guard let scroll = findTranscriptScroll(window), let document = scroll.documentView else { return false }
        let viewport = screenViewport(scroll, window: window)
        return accessibilityElements(document).contains {
            let frame = $0.accessibilityFrame()
            // Container AX labels may aggregate the entire history. Only a concrete message/text frame
            // smaller than the viewport can prove that its final row is actually on screen.
            return accessibilityText($0).contains(marker) && frame.height > 0 && frame.height < viewport.height
                && frame.width > 0 && frame.intersects(viewport)
        }
    }

    /// SwiftUI overlay buttons are rendered in this xctest host but do not expose actionable in-process
    /// AX objects. Click the visible overlay through the test window's normal event dispatch, then verify
    /// the actual latest row and subsequent auto-follow. Events never enter the global input stream.
    private func clickJumpToLatest(_ window: NSWindow) throws {
        let scroll = try transcriptScroll(window)
        let viewport = screenViewport(scroll, window: window)
        let content = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let fieldFrame = field.accessibilityFrame()
        // The native scroll wrapper can be translated vertically by SwiftUI while retaining y=0.
        // The real text field's AX frame supplies the rendered composer position. Both empty fixture
        // composers have fieldInset, the surface's s2 padding and the composer's top s2 above the field.
        let composerTop = fieldFrame.maxY + DS.Size.fieldInset + DS.Space.s2 * 2
        let screenPoint = NSPoint(x: viewport.midX, y: composerTop + DS.Space.s3 + DS.Size.controlHeight / 2)
        let point = window.convertPoint(fromScreen: screenPoint)
        print("[long-transcript] jump click windowPoint=\(point) screenPoint=\(screenPoint) composerFieldAX=\(fieldFrame) nativeViewport=\(viewport)")
        window.makeKeyAndOrderFront(nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // A native control may enter a synchronous tracking loop from mouseDown. Queue its release
        // inside this application first, as existing split-divider gesture tests do.
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        // SwiftUI can also return from mouseDown without a native tracking loop. XCTest does not run
        // NSApplication's ordinary event pump, so deliver an unconsumed release to this window now.
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if queued.windowNumber == window.windowNumber { window.sendEvent(queued) }
            else { NSApp.postEvent(queued, atStart: true) }
        }
    }

    private func screenViewport(_ scroll: NSScrollView, window: NSWindow) -> NSRect {
        window.convertToScreen(scroll.convert(effectiveViewport(scroll), to: nil))
    }

    /// SwiftUI's underlying NSScrollView can span the hosting view while its rendered content is clipped
    /// to the detail column. Intersect native ancestor clipping and the actual split-view detail column.
    private func effectiveViewport(_ scroll: NSScrollView) -> NSRect {
        guard let window = scroll.window, let content = window.contentView else { return scroll.visibleRect }
        var frame = scroll.convert(scroll.visibleRect, to: nil)
        frame = frame.intersection(content.convert(content.bounds, to: nil))
        if let split = allViews(content).compactMap({ $0 as? NSSplitView }).first,
           let sidebar = split.arrangedSubviews.first, !sidebar.isHidden {
            // SwiftUI can translate the detail visually without moving its native bounds. The visible
            // sidebar still occupies the leading part of the hosting view even in that arrangement.
            let contentFrame = content.convert(content.bounds, to: nil)
            let detailFrame = NSRect(x: contentFrame.minX + sidebar.frame.width,
                                     y: contentFrame.minY,
                                     width: max(0, contentFrame.width - sidebar.frame.width),
                                     height: contentFrame.height)
            frame = frame.intersection(detailFrame)
        }
        return scroll.convert(frame, from: nil)
    }

    private func sidebarHidden(_ window: NSWindow) -> Bool? {
        guard let content = window.contentView else { return nil }
        return allViews(content).compactMap { $0 as? NSSplitView }.first?.arrangedSubviews.first?.isHidden
    }

    private func accessibilityText(_ element: NSAccessibilityProtocol) -> String {
        [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func accessibilityElements(_ root: Any) -> [NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSAccessibilityProtocol] = []
        func visit(_ node: Any, depth: Int) {
            guard depth < 70, seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            if let element = node as? NSAccessibilityProtocol {
                result.append(element)
                (element.accessibilityChildren() ?? []).forEach { visit($0, depth: depth + 1) }
            }
            // A hosting/layout wrapper can be non-accessible while its descendants expose SwiftUI
            // controls. Native recursion must continue independently of protocol conformance.
            ((node as? NSView)?.subviews ?? []).forEach { visit($0, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }

    private enum WaitFailure: Error { case timeout, invalidWheelPhase }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else {
                for window in windows {
                    dumpGeometry(window, stage: "timeout")
                    capture(window, name: "\(name)-timeout")
                }
                XCTFail("long transcript condition did not settle", file: file, line: line)
                throw WaitFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle(_ scroll: NSScrollView) async throws {
        var previous = CGRect.null, consecutive = 0
        try await waitUntil {
            let current = scroll.documentView?.convert(effectiveViewport(scroll), from: scroll) ?? scroll.documentVisibleRect
            consecutive = current.equalTo(previous) ? consecutive + 1 : 0
            previous = current
            return consecutive >= 5
        }
    }

    /// Optional artifacts for an explicitly authorized window run, never written by a headless run.
    private func capture(_ window: NSWindow, name: String) {
        let path = ProcessInfo.processInfo.environment["HERMES_BOT_APP_LONG_TRANSCRIPT_EVIDENCE"] ?? "/tmp/herald-long-transcript-evidence"
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func dumpGeometry(_ window: NSWindow, stage: String) {
        guard let content = window.contentView else { return }
        print("[long-transcript] \(stage) window=\(content.bounds) observerScroll=\(findTranscriptScroll(window).map { String(describing: ObjectIdentifier($0)) } ?? "nil")")
        for field in allViews(content).compactMap({ $0 as? NSTextField }).filter(\.isEditable) {
            print("[long-transcript] composer field AX=\(field.accessibilityFrame()) nativeFrame=\(field.convert(field.bounds, to: nil))")
        }
        for split in allViews(content).compactMap({ $0 as? NSSplitView }) {
            print("[long-transcript] split columns=\(split.arrangedSubviews.map { "\($0.frame); hidden=\($0.isHidden)" })")
        }
        for scroll in allViews(content).compactMap({ $0 as? NSScrollView }) {
            print("[long-transcript] scroll=\(ObjectIdentifier(scroll)) frame=\(scroll.frame) bounds=\(scroll.bounds) clip=\(scroll.contentView.bounds) documentFrame=\(String(describing: scroll.documentView?.frame)) documentBounds=\(String(describing: scroll.documentView?.bounds)) visible=\(scroll.documentVisibleRect) effective=\(effectiveViewport(scroll)) flipped=\(String(describing: scroll.documentView?.isFlipped))")
            if let document = scroll.documentView {
                for element in accessibilityElements(document).filter({
                    accessibilityText($0).contains(Self.botEnd) || accessibilityText($0).contains(Self.roomEnd)
                }).prefix(4) {
                    print("[long-transcript] endMarker role=\(String(describing: element.accessibilityRole())) frame=\(element.accessibilityFrame()) label=\(accessibilityText(element).prefix(100))")
                }
            }
        }
    }
}
