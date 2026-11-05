import AppKit
import HermesGatewayKit
import QuickLookUI
import SwiftUI

// The application delegate: launch wiring (notifications, Quick Look, updates, Mac integration, signals,
// the visibility signal's observers), the quit cleanup with its deadline, and the Quick Look panel control.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var visibilityObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Pasted images left behind by a crash or a kill (no quit purge ran): nothing can reference them.
        PasteboardAttachments.purge()
        // Notifications (D1): the UserNotifications delegate must be in place before a click that launched the
        // app is delivered. Nothing is requested from the user until the first notification (lazy authorization).
        MainActor.assumeIsolated {
            _ = AppModel.shared.notifications
            QuickLookController.shared.installKeyMonitor()  // D8: Space previews the file under the pointer
            UpdateChecker.shared.startSchedule()  // E3: daily update check (packaged builds, Settings switch)
        }
        // D4 Quick Ask shortcut + D6 Services provider (MacIntegration/MacIntegration.swift).
        MainActor.assumeIsolated { MacIntegration.shared.install() }
        // `swift run` launches a bare executable: make it a regular foreground app with a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        switch ProcessInfo.processInfo.environment["HERMES_BOT_APP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // SIGTERM and SIGINT (Ctrl+C in the launching terminal) → the same graceful path as Quit
        // (detach chats, stop only an owned backend). A repeated signal while cleanup runs is a
        // no-op (`cleanupStarted`). An owned backend is spawned in its own process group, so the
        // terminal's SIGINT does not reach it before cleanup has used it.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        // Kanban polling pauses while no main window is on screen (hidden app, minimised or covered windows;
        // the Settings window does not count).
        let names: [Notification.Name] = [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.updateVisibility() }
            })
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // D8: the app delegate is the Quick Look panel's controller (QuickLook.swift).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.begin(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.end(panel) }
    }

    /// Detach the Bot Chats (they stay in Hermes), then stop the backend only if we spawned it. If we
    /// crash instead, the spawned backend's HERMES_PARENT_PID watchdog exits it.
    ///
    /// Not `.terminateLater`: that parks the run loop in a modal mode, and the MainActor
    /// continuations of the async cleanup (and the SIGTERM source on the main queue) never ran,
    /// so a scripted quit hung until SIGKILL (evidence/m1/app-attach-console.log). Instead: cancel,
    /// clean up on the normal run loop, then terminate again.
    ///
    /// Cleanup has an overall deadline (`quitDeadline`): a stuck backend (an RPC that never answers)
    /// must not hang ⌘Q, Ctrl+C or SIGTERM. Past it the app exits anyway; an owned backend is stopped
    /// first.
    static let quitDeadline: TimeInterval = 5
    private var cleanupDone = false
    private var cleanupStarted = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupDone { return .terminateNow }
        if !cleanupStarted {
            cleanupStarted = true
            AppModel.shared.log("quit requested: cleaning up before exit")
            Task { @MainActor in
                await AppModel.shared.shutdown()
                self.finishTermination()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitDeadline) {
                MainActor.assumeIsolated {
                    guard !self.cleanupDone else { return }
                    AppModel.shared.abandonShutdown(after: Self.quitDeadline)
                    self.finishTermination()
                }
            }
        }
        return .terminateCancel
    }

    @MainActor private func finishTermination() {
        guard !cleanupDone else { return }
        cleanupDone = true
        PasteboardAttachments.purge()  // pasted images never outlive the app
        NSApp.terminate(nil)
    }
}
