import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// The composer with everything on (B7-B9): a long model name, the effort menu, the context gauge, a busy
/// turn with the steer hint, and a queue panel, at the 820 × 520 minimum with the inspector shown. The
/// controls must give way (truncate, drop the key hints) instead of widening the chat column past the
/// window, and the text field must stay on screen. Real window: opt-in (`HERMES_BOT_APP_WINDOW_TESTS=1`).
@MainActor
final class BotChatComposerLayoutTests: XCTestCase {
    private struct Host: View {
        let chat: ChatModel
        var body: some View {
            NavigationSplitView {
                List { Text("hba-layout sidebar row") }
                    .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarWidth, max: DS.Size.sidebarMax)
            } detail: {
                BotChatView(chat: chat)
                    .frame(minWidth: DS.Size.detailMin, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: DS.Size.windowMinWidth, minHeight: DS.Size.windowMinHeight)
        }
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    func testFullComposerFitsTheMinimumWindowWithTheInspector() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let key = "hba.botInspector"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }

        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "hello"),
                                          ChatHistoryMessage(role: .assistant, text: "Hi! How can I help?")])
        link.openInfo = SessionInfoSnapshot(model: "an-extremely-long-model-name-for-layout-checks-2026-preview",
                                            provider: "openrouter", reasoningEffort: "ultra", reasoningEffortWire: "max",
                                            usage: ContextUsage(used: 126_000, max: 200_000, percent: 63, estimated: true))
        link.catalog = ModelCatalog(providers: [.init(slug: "openrouter", name: "OpenRouter", models: ["a"])])
        let bot = try XCTUnwrap(Bot(["name": "hba-layout", "model": "test-model"]))
        let chat = ChatModel(bot: bot, opener: { _ in link })
        chat.log = { _ in }
        let size = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(chat: chat))
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.8)

        XCTAssertTrue(chat.isReady)
        chat.draft = "go"
        XCTAssertTrue(chat.submit())
        chat.apply(.delta("Working on it"))
        chat.draft = "a queued follow-up message that is long enough to wrap onto a second line in the panel"
        chat.queueOrSend()
        chat.draft = "second"
        chat.queueOrSend()
        chat.draft = "steer me"
        spin(0.8)

        let content = try XCTUnwrap(window.contentView)
        let views = all(content)
        for split in views.compactMap({ $0 as? NSSplitView }) {
            let f = split.convert(split.bounds, to: nil)
            XCTAssertLessThanOrEqual(f.maxX, content.bounds.width + 1, "a split view runs past the window: \(f)")
        }
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let frame = field.convert(field.bounds, to: nil)
        XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "composer field \(frame) is off screen")
        XCTAssertGreaterThanOrEqual(frame.width, 60, "the field keeps room to type")
    }

    /// Live UI test 2026-11-06 (round 2) flagged unlabeled tiny AX buttons. The ⌘Return "Queue message" button
    /// that keeps the shortcut working while a reply runs is `accessibilityHidden` and stays so; this pins
    /// that the shortcut still queues from the window. (The four 6 × 4.5 pt buttons in the report are the
    /// sidebar scroll bar's arrow and page parts, `AXScrollBar` children, not app buttons.)
    func testCommandReturnQueuesWhileAReplyRuns() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "hello")])
        let bot = try XCTUnwrap(Bot(["name": "hba-layout", "model": "test-model"]))
        let chat = ChatModel(bot: bot, opener: { _ in link })
        chat.log = { _ in }
        let size = NSSize(width: DS.Size.windowMinWidth, height: DS.Size.windowMinHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(chat: chat))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.8)
        XCTAssertTrue(chat.isReady)
        chat.draft = "go"
        XCTAssertTrue(chat.submit())
        chat.apply(.delta("Working on it"))
        chat.draft = "a follow-up"
        spin(0.4)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "⌘Return was not handled")
        spin(0.3)
        XCTAssertEqual(chat.queue.map(\.text), ["a follow-up"], "⌘Return queues the draft while the reply runs")
    }
}
