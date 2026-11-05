import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// E2 first-run onboarding: which state the app is in (from the connect error, `setup.runtime_check`, the
/// roster) and which screen shows. Headless and pure, except the window-gated layout check at the end; no
/// hermes CLI is run.
@MainActor
final class OnboardingTests: XCTestCase {
    private func bot(_ name: String, title: String? = nil) -> Bot {
        var row: [String: JSONValue] = ["name": .string(name)]
        if let title { row["display_name"] = .string(title) }
        return Bot(.object(row))!
    }

    // MARK: detection

    func testMissingHermesIsDetectedFromTheSpawnError() {
        let notFound = ServeProcess.ServeError.binaryNotFound(tried: ["/a/hermes", "/b/hermes"], log: "/l")
        XCTAssertEqual(Onboarding.issue(for: notFound), .hermesMissing(tried: ["/a/hermes", "/b/hermes"], problem: nil))
        let bad = ServeProcess.ServeError.invalidBinary(path: "/x/hermes", reason: "it is not a regular executable file", log: "/l")
        XCTAssertEqual(Onboarding.issue(for: bad),
                       .hermesMissing(tried: ["/x/hermes"], problem: "/x/hermes: it is not a regular executable file"))
    }

    func testOtherConnectErrorsKeepTheGenericScreen() {
        XCTAssertNil(Onboarding.issue(for: ServeProcess.ServeError.readyTimeout(log: "/l")))
        XCTAssertNil(Onboarding.issue(for: ServeProcess.ServeError.untrustedBinary(path: "/x", reason: "writable", log: "/l")))
        XCTAssertNil(Onboarding.issue(for: Backend.Failure.noBackend([])))
        XCTAssertNil(Onboarding.issue(for: GatewayClient.ClientError.notConnected))
    }

    func testRuntimeCheckMapsToNoModelOnlyWhenClear() {
        XCTAssertEqual(Onboarding.issue(for: SetupReadiness.noModel(provider: "p", model: "m", reason: "r")),
                       .noModel(provider: "p", model: "m", reason: "r"))
        XCTAssertNil(Onboarding.issue(for: SetupReadiness.ready))
        XCTAssertNil(Onboarding.issue(for: SetupReadiness.unknown))
    }

    // MARK: screen choice

    func testHermesMissingShowsOnlyWhileTheConnectFailed() {
        let issue = SetupIssue.hermesMissing(tried: ["/a"], problem: nil)
        XCTAssertEqual(Onboarding.screen(phase: .failed("x"), issue: issue, bots: [], groupsAvailable: true),
                       .hermesMissing(tried: ["/a"], problem: nil))
        XCTAssertNil(Onboarding.screen(phase: .connecting, issue: issue, bots: [], groupsAvailable: true))
        XCTAssertNil(Onboarding.screen(phase: .failed("Lost the connection"), issue: nil, bots: [], groupsAvailable: true),
                     "every other failure keeps \"Can't reach Hermes\"")
    }

    func testNoModelWinsOverTheOneBotScreen() {
        let issue = SetupIssue.noModel(provider: "openrouter", model: nil, reason: "No usable credentials found for openrouter.")
        XCTAssertEqual(Onboarding.screen(phase: .connected, issue: issue, bots: [bot("default")], groupsAvailable: true),
                       .noModel(provider: "openrouter", model: nil, reason: "No usable credentials found for openrouter."))
        XCTAssertNil(Onboarding.screen(phase: .failed("x"), issue: issue, bots: [], groupsAvailable: true))
    }

    func testOneBotScreenOnlyWithExactlyOneBotAndGroupChatAvailable() {
        XCTAssertEqual(Onboarding.screen(phase: .connected, issue: nil, bots: [bot("default", title: "Main")], groupsAvailable: true),
                       .oneBot(name: "default", title: "Main"))
        XCTAssertNil(Onboarding.screen(phase: .connected, issue: nil, bots: [bot("default")], groupsAvailable: false),
                     "without groups.* the usual note explains Group Chat")
        XCTAssertNil(Onboarding.screen(phase: .connected, issue: nil, bots: [bot("a"), bot("b")], groupsAvailable: true))
        XCTAssertNil(Onboarding.screen(phase: .connected, issue: nil, bots: [], groupsAvailable: true))
        XCTAssertNil(Onboarding.screen(phase: .connecting, issue: nil, bots: [bot("a")], groupsAvailable: true))
    }

    // MARK: commands

    func testNewBotCommandsForValidNamesOnly() {
        XCTAssertEqual(Onboarding.newBotCommands(name: "reviewer"), ["hermes profile create reviewer", "hermes -p reviewer setup"])
        XCTAssertEqual(Onboarding.newBotCommands(name: "  writer-2 "), ["hermes profile create writer-2", "hermes -p writer-2 setup"])
        for bad in ["", "Reviewer", "default", "a b", "x;rm -rf ~", "$(id)", "-p", String(repeating: "a", count: 65)] {
            XCTAssertNil(Onboarding.newBotCommands(name: bad), bad)
        }
    }

    func testFixedCommandsAndLinks() {
        XCTAssertEqual(Onboarding.modelCommands, ["hermes setup", "hermes model"])
        XCTAssertTrue(Onboarding.overrideExample.contains("HERMES_BOT_APP_HERMES_BIN="))
        XCTAssertEqual(Onboarding.docsURL.host, "hermes-agent.nousresearch.com")
        XCTAssertNotNil(Onboarding.newBotCommands(name: Onboarding.suggestedBotName))
    }

    // MARK: app model

    func testSetupCheckWithoutABackendLeavesNothingSet() async {
        let app = AppModel()
        await app.checkSetup()
        XCTAssertNil(app.setupIssue)
    }

    // MARK: layout (window-gated)

    /// Every screen fits the detail pane's minimum width (no clipped commands or buttons).
    func testEveryScreenFitsTheNarrowestDetailPane() throws {
        try WindowTestGate.requireWindows()
        guard NSScreen.main != nil else { throw XCTSkip("no window server session") }
        let screens: [OnboardingScreen] = [
            .hermesMissing(tried: ["/Users/me/.local/bin/hermes", "/opt/homebrew/bin/hermes"], problem: nil),
            .hermesMissing(tried: ["/x"], problem: "/x: it is not a regular executable file"),
            .noModel(provider: "openrouter", model: "anthropic/claude-sonnet", reason: "No usable credentials found for openrouter."),
            .oneBot(name: "default", title: "Default"),
        ]
        for screen in screens {
            let host = NSHostingView(rootView: OnboardingView(screen: screen))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.Size.detailMin, height: DS.Size.windowMinHeight),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertLessThanOrEqual(host.fittingSize.width, DS.Size.detailMin + 0.5, "\(screen)")
            window.orderOut(nil)
        }
    }
}
