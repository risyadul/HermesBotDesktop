import AppKit
import Carbon.HIToolbox
import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D3 menu bar status + quick send, D4 Quick Ask (shortcut, panel model), D6 Services input + chooser, D7
/// intents' runner. Headless: recorders stand in for the hot key and Services registrars (no real global
/// hot key or service is ever registered), and every send goes to `QuickSendFixture`'s fakes.
@MainActor
final class MacIntegrationTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    /// Regression: binding the menu bar extra's `isInserted` straight to @AppStorage looped at 100% CPU,
    /// because AppKit writes the same value back on every menu bar update. Only real changes may be stored.
    func testMenuBarInsertionStoresOnlyRealChanges() {
        var stored = true
        var writes = 0
        let binding = MenuBarScene.insertion(get: { stored }, set: { stored = $0; writes += 1 })
        for _ in 0..<5 { binding.wrappedValue = true }
        XCTAssertEqual(writes, 0, "same-value writes from AppKit must not touch the setting")
        binding.wrappedValue = false
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(stored)
        binding.wrappedValue = false
        XCTAssertEqual(writes, 1)
    }

    override func setUp() async throws {
        suite = "hba-macint-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: D3 menu bar status

    private let bots = [Bot(["name": "alpha", "display_name": "Alpha"])!, Bot(["name": "beta"])!, Bot(["name": "gamma"])!]

    func testMenuBarRowsListNeedsYouThenWorkingThenIdle() {
        let rooms = [RoomFixtures.room("r1", name: "Ops"), RoomFixtures.room("r2", name: "Design"), RoomFixtures.room("r3", name: "Ask")]
        let status = MenuBarStatus.make(
            bots: bots, hidden: [],
            chats: ["beta": .init(waiting: 0, busy: true), "gamma": .init(waiting: 2, busy: true)],
            rooms: rooms,
            roomFacts: ["r2": .init(approvals: 0, mention: false, working: true),
                        "r3": .init(approvals: 1, mention: true, working: true)])
        XCTAssertEqual(status.bots.map(\.title), ["gamma", "beta", "Alpha"])
        XCTAssertEqual(status.bots.map(\.state), [.needsYou(2), .working, .idle])
        XCTAssertEqual(status.rooms.map(\.item), [.room("r3"), .room("r2"), .room("r1")])
        XCTAssertEqual(status.rooms.first?.state, .needsYou(2), "an approval and an unseen @user")
        XCTAssertEqual(status.pending, 3, "Bot Chat requests + room approvals, as the Dock badge")
        XCTAssertEqual(status.badge, "3")
        XCTAssertEqual(MenuBarRowState.needsYou(1).label, "Needs you")
    }

    func testMenuBarLeavesHiddenBotsOutAndIsQuietWhenNothingWaits() {
        let status = MenuBarStatus.make(bots: bots, hidden: ["beta"], chats: [:], rooms: [], roomFacts: [:])
        XCTAssertEqual(status.bots.map(\.item), [.bot("alpha"), .bot("gamma")])
        XCTAssertTrue(status.bots.allSatisfy { $0.state == .idle })
        XCTAssertNil(status.badge)
    }

    func testMenuBarBadgeFollowsTheStatus() async {
        let badge = MenuBarBadge()
        var pending = 0
        badge.start(every: 0.01) {
            MenuBarStatus.make(bots: [], hidden: [], chats: ["a": .init(waiting: pending, busy: false)], rooms: [], roomFacts: [:])
        }
        defer { badge.stop() }
        await eventually { badge.badge == nil }
        pending = 2
        await eventually { badge.badge == "2" }
    }

    func testMenuBarQuickSendSendsToTheBotChatAndReportsRefusals() async throws {
        let f = QuickSendFixture()
        let quick = MenuBarQuickSend()
        quick.pickDefault(f.bots)
        XCTAssertEqual(quick.bot, "alpha")
        XCTAssertFalse(quick.canSend, "nothing typed")
        quick.text = "ping"
        await quick.send(f.sender)
        XCTAssertEqual(quick.text, "")
        XCTAssertEqual(quick.note?.failed, false)
        await eventually { f.sent("alpha") == ["send:ping|"] }
        quick.text = "again"
        await quick.send(f.sender)
        XCTAssertEqual(quick.note?.failed, true, "Alpha is still replying")
        XCTAssertEqual(quick.text, "again", "a refused message stays in the field")
    }

    // MARK: D4 shortcut

    func testShortcutDisplayAndRecording() {
        XCTAssertEqual(HotKeyShortcut.default.display, "⌃⌥Space")
        let k = HotKeyShortcut.recorded(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift], characters: "k")
        XCTAssertEqual(k?.display, "⇧⌘K")
        XCTAssertEqual(k?.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertNil(HotKeyShortcut.recorded(keyCode: UInt16(kVK_ANSI_K), flags: [.shift], characters: "k"),
                     "Shift alone would swallow typing")
        XCTAssertNil(HotKeyShortcut.recorded(keyCode: UInt16(kVK_ANSI_K), flags: [], characters: "k"))
        XCTAssertNil(HotKeyShortcut.recorded(keyCode: UInt16(kVK_Option), flags: [.option], characters: ""), "a bare modifier")
        XCTAssertNil(HotKeyShortcut.recorded(keyCode: UInt16(kVK_Escape), flags: [.control], characters: "\u{1b}"))
        XCTAssertEqual(HotKeyShortcut.recorded(keyCode: UInt16(kVK_F5), flags: [.control], characters: nil)?.display, "⌃F5")
    }

    func testHotKeyRegistersTheDefaultAndFollowsTheSetting() {
        let registrar = RecordingHotKeys()
        var fired = 0
        let hotKey = QuickAskHotKey(registrar: registrar, defaults: defaults, action: { fired += 1 })
        hotKey.apply()
        XCTAssertEqual(registrar.registered, [.default])
        XCTAssertTrue(hotKey.registered)
        registrar.press()
        XCTAssertEqual(fired, 1, "the press runs the action (toggles the panel)")

        hotKey.setEnabled(false)
        XCTAssertNil(registrar.current, "off: nothing stays registered")
        XCTAssertFalse(hotKey.registered)

        hotKey.setEnabled(true)
        let k = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey), key: "K")
        hotKey.setShortcut(k)
        XCTAssertEqual(registrar.current, k)
        let relaunched = QuickAskHotKey(registrar: RecordingHotKeys(), defaults: defaults, action: {})
        XCTAssertEqual(relaunched.shortcut, k, "the shortcut is kept")
        XCTAssertTrue(relaunched.enabled)
        hotKey.resetShortcut()
        XCTAssertEqual(registrar.current, .default)
    }

    func testHotKeyTakenByAnotherAppIsReported() {
        let registrar = RecordingHotKeys()
        registrar.refuse = true
        let hotKey = QuickAskHotKey(registrar: registrar, defaults: defaults, action: {})
        hotKey.apply()
        XCTAssertFalse(hotKey.registered)
        XCTAssertEqual(hotKey.problem, "⌃⌥Space is in use by another app. Pick another shortcut.")
        hotKey.setEnabled(false)
        XCTAssertNil(hotKey.problem)
    }

    func testInstallRegistersOnceWithInjectedRegistrars() {
        let hotKeys = RecordingHotKeys(), services = RecordingServices()
        var badgeStarts = 0
        let integration = MacIntegration(hotKeys: hotKeys, services: services, defaults: defaults,
                                         toggleQuickAsk: {}, presentChooser: { _ in }, startBadge: { badgeStarts += 1 })
        integration.install()
        integration.install()
        XCTAssertEqual(hotKeys.registered, [.default])
        XCTAssertEqual(services.installed.count, 1)
        XCTAssertEqual(badgeStarts, 1)
        XCTAssertTrue(services.installed.first === integration.provider)
        integration.uninstall()
        XCTAssertNil(hotKeys.current)
    }

    // MARK: D4 Quick Ask panel model

    func testQuickAskSendsAndFollowsTheReply() async throws {
        let f = QuickSendFixture()
        let model = QuickAskModel(sender: { f.sender })
        model.didShow()
        XCTAssertEqual(model.bot, "alpha")
        XCTAssertEqual(model.shown, 1, "each showing refocuses the field")
        model.bot = "beta"
        model.text = "summarize my day"
        await model.send()
        XCTAssertEqual(model.text, "", "sent: the field clears")
        let turn = try XCTUnwrap(model.turn)
        XCTAssertEqual(turn.chat.bot.name, "beta")
        await eventually { !f.sent("beta").isEmpty }
        f.reply("beta", "busy day")
        await eventually { QuickReply.state(lines: turn.chat.lines, after: turn.userLine, busy: turn.chat.busy) == .done("busy day") }

        model.botChanged()
        XCTAssertNil(model.turn)
    }

    func testQuickAskKeepsTheTextWhenRefused() async throws {
        let f = QuickSendFixture()
        f.connected = false
        let model = QuickAskModel(sender: { f.sender })
        model.bot = "alpha"
        model.text = "hello"
        await model.send()
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(model.error, QuickSendError.notConnected.description)
        XCTAssertNil(model.turn)
    }

    // MARK: D6 Services

    func testServiceInputKeepsRegularFilesOnceAndDropsPathOnlyText() {
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/b.pdf"), dir = URL(fileURLWithPath: "/tmp/dir")
        let input = ServiceInput.make(text: "/tmp/a.txt\n/tmp/b.pdf", fileURLs: [a, dir, a], filenames: ["/tmp/b.pdf", "/tmp/a.txt"],
                                      isRegularFile: { $0 != dir })
        XCTAssertEqual(input.files, [a, b])
        XCTAssertEqual(input.text, "", "text that only repeats the file paths is dropped")

        let text = ServiceInput.make(text: "a quote", fileURLs: [], filenames: [], isRegularFile: { _ in true })
        XCTAssertEqual(text, ServiceInput(text: "a quote", files: []))
        let long = ServiceInput.make(text: String(repeating: "x", count: ServiceInput.textLimit + 50), fileURLs: [], filenames: [])
        XCTAssertEqual(long.text.count, ServiceInput.textLimit)
        let many = (0..<15).map { URL(fileURLWithPath: "/tmp/f\($0)") }
        XCTAssertEqual(ServiceInput.make(text: nil, fileURLs: many, filenames: [], isRegularFile: { _ in true }).files.count,
                       ServiceInput.fileLimit)
        XCTAssertTrue(ServiceInput.make(text: "  ", fileURLs: [], filenames: []).isEmpty)
    }

    func testServiceProviderPresentsTheChooserAndRefusesEmptySelections() throws {
        var presented: [ServiceInput] = []
        let provider = HermesServicesProvider(present: { presented.append($0) })
        let pboard = NSPasteboard(name: NSPasteboard.Name("hba-test-\(UUID().uuidString)"))
        defer { pboard.releaseGlobally() }
        var error: NSString?
        pboard.clearContents()
        provider.sendToHermesBot(pboard, userData: nil, error: &error)
        XCTAssertNotNil(error, "nothing selected")
        XCTAssertTrue(presented.isEmpty)

        error = nil
        pboard.clearContents()
        pboard.setString("selected words", forType: .string)
        provider.sendToHermesBot(pboard, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(presented, [ServiceInput(text: "selected words", files: [])], "the chooser opens; nothing is sent")
    }

    func testChooserSendsOnlyOnTheUsersSendAndFilesGoToTheComposer() async throws {
        let f = QuickSendFixture()
        var opened: [SidebarItem] = []
        let room = RoomModel(room: RoomFixtures.room(), api: f.rooms)
        let model = SendChooserModel(input: ServiceInput(text: "from Safari", files: []), sender: { f.sender },
                                     roomModel: { _ in room }, open: { opened.append($0) })
        model.pickDefault()
        XCTAssertEqual(model.target, .bot("alpha"))
        XCTAssertTrue(f.sent("alpha").isEmpty && f.rooms.sends.isEmpty, "opening the chooser sends nothing")
        model.target = .room("hba-test-0")
        await model.send()
        XCTAssertEqual(f.rooms.sends.map(\.text), ["from Safari"])
        XCTAssertEqual(opened, [.room("hba-test-0")])
        XCTAssertTrue(model.finished)

        let withFile = SendChooserModel(input: ServiceInput(text: "see file", files: [URL(fileURLWithPath: "/tmp/x.txt")]),
                                        sender: { f.sender }, roomModel: { _ in room }, open: { opened.append($0) })
        withFile.target = .room("hba-test-0")
        XCTAssertFalse(withFile.canSend, "files are not sent from the chooser")
        XCTAssertTrue(withFile.canPrefill)
        await withFile.prefill()
        XCTAssertEqual(room.drafts[RoomThreads.main], "see file")
        XCTAssertEqual(f.rooms.sends.count, 1, "prefill sends nothing")
        withFile.removeFile(URL(fileURLWithPath: "/tmp/x.txt"))
        XCTAssertTrue(withFile.files.isEmpty)
    }

    // MARK: D7 intents

    func testAskIntentReturnsTheReply() async throws {
        let f = QuickSendFixture()
        let runner = IntentRunner(sender: { f.sender }, connectWait: 1, step: 5_000_000)
        let task = Task { try await runner.ask(bot: "alpha", prompt: "2+2?", timeout: 30) }
        await eventually { f.sent("alpha") == ["send:2+2?|"] }
        f.reply("alpha", "4")
        let reply = try await task.value
        XCTAssertEqual(reply, "4")
    }

    func testIntentsWaitForTheConnectionThenGiveUp() async throws {
        let f = QuickSendFixture()
        f.connected = false
        let runner = IntentRunner(sender: { f.sender }, connectWait: 2, step: 5_000_000)
        let post = Task { try await runner.post(room: "hba-test-0", message: "standup in 5") }
        try await Task.sleep(nanoseconds: 50_000_000)
        f.connected = true  // the app finished connecting (a launch by Shortcuts)
        try await post.value
        XCTAssertEqual(f.rooms.sends.map(\.text), ["standup in 5"])

        f.connected = false
        let impatient = IntentRunner(sender: { f.sender }, connectWait: 0.05, step: 5_000_000)
        await XCTAssertThrowsQuick(.notConnected) { _ = try await impatient.ask(bot: "alpha", prompt: "hi", timeout: 5) }
        XCTAssertTrue(f.sent("alpha").isEmpty)
        let bots = await impatient.bots()
        XCTAssertTrue(bots.isEmpty)
    }

    func testAskIntentTimesOutAndClampsTheTimeout() async throws {
        let f = QuickSendFixture()
        var runner = IntentRunner(sender: { f.sender }, connectWait: 1, step: 5_000_000)
        runner.sender = {
            var s = f.sender
            s.step = 5_000_000
            return s
        }
        let started = Date()
        // 0 s is clamped up to the 5 s minimum; the fake never answers.
        let task = Task { try await runner.ask(bot: "alpha", prompt: "slow", timeout: 0) }
        await XCTAssertThrowsQuick(.timedOut("Alpha")) { _ = try await task.value }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), Double(IntentRunner.timeoutRange.lowerBound) - 0.5)
    }
}

/// Records hot key registrations instead of calling RegisterEventHotKey.
@MainActor
final class RecordingHotKeys: HotKeyRegistering {
    var registered: [HotKeyShortcut] = []
    var current: HotKeyShortcut?
    var refuse = false
    private var action: (@MainActor () -> Void)?

    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        guard !refuse else { return false }
        registered.append(shortcut)
        current = shortcut
        self.action = action
        return true
    }

    func unregister() { current = nil; action = nil }
    func press() { action?() }
}

/// Records the Services provider instead of setting `NSApp.servicesProvider`.
@MainActor
final class RecordingServices: ServicesRegistering {
    var installed: [NSObject] = []
    func install(_ provider: NSObject) { installed.append(provider) }
}
