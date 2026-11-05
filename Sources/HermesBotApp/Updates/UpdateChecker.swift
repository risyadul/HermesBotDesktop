import AppKit
import Foundation

/// E3: runs update checks (UpdatePolicy.swift) and the daily schedule, and hands what should be shown to
/// `present` (an alert in the app, a recorder in tests). Nothing is downloaded or installed: "Download" opens
/// the release page in the browser.
@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// What `present` gets: a result to show, the running version (nil in a build without one) and whether the
    /// user asked (a background result waits until the app is frontmost).
    struct Prompt: Equatable {
        let result: UpdateCheckResult
        let currentVersion: String?
        var trigger: UpdateCheckTrigger = .manual
    }

    static let shared = UpdateChecker()
    /// How often the schedule asks whether a check is due (UpdatePolicy.isDue decides).
    static let tick: Duration = .seconds(60 * 60)
    /// The first look after launch waits a little, so it does not compete with connecting to Hermes.
    static let launchDelay: Duration = .seconds(20)

    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?

    private let defaults: UserDefaults
    private let currentVersion: String?
    private let fetch: Fetch
    private let now: () -> Date
    private let present: @MainActor (Prompt) -> Void
    private var schedule: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         fetch: @escaping Fetch = UpdateChecker.liveFetch,
         now: @escaping () -> Date = Date.init,
         present: @escaping @MainActor (Prompt) -> Void = UpdateAlert.present) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.now = now
        self.present = present
        lastCheck = defaults.object(forKey: UpdatePolicy.lastCheckKey) as? Date
    }

    /// A packaged build knows its version; `swift run` does not, and never checks in the background.
    var current: AppVersion? { currentVersion.flatMap(AppVersion.init) }

    /// One check. Returns nil when one is already running (the menu item is disabled meanwhile).
    @discardableResult
    func check(_ trigger: UpdateCheckTrigger) async -> UpdateCheckResult? {
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }
        let result: UpdateCheckResult
        do {
            let (data, response) = try await fetch(UpdatePolicy.request(appVersion: currentVersion))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = UpdatePolicy.result(status: status, data: data, current: current)
        } catch {
            result = UpdatePolicy.failure(error)
        }
        if case .failed = result {} else {
            lastCheck = now()
            defaults.set(lastCheck, forKey: UpdatePolicy.lastCheckKey)
        }
        let lastShown = defaults.string(forKey: UpdatePolicy.lastShownTagKey)
        if UpdatePolicy.shouldShow(result, trigger: trigger, lastShownTag: lastShown) {
            if trigger == .background, case .available(let release) = result {
                defaults.set(release.tag, forKey: UpdatePolicy.lastShownTagKey)
            }
            present(Prompt(result: result, currentVersion: currentVersion, trigger: trigger))
        }
        return result
    }

    /// The scheduled check: only in a build with a version, with automatic checks on, once a day.
    @discardableResult
    func checkIfDue() async -> UpdateCheckResult? {
        guard current != nil,
              UpdatePolicy.isDue(autoCheck: UpdatePolicy.isAutoCheckOn(defaults), lastCheck: lastCheck, now: now())
        else { return nil }
        return await check(.background)
    }

    /// Starts the daily schedule (idempotent): a look shortly after launch, then every `tick`.
    func startSchedule() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    nonisolated static func liveFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdatePolicy.timeout
        configuration.timeoutIntervalForResource = UpdatePolicy.timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}

/// The update alert: release notes in a scrolling text view, "Download" opens the release page in the browser.
enum UpdateAlert {
    struct Content: Equatable {
        let title: String
        let message: String
        let notes: String?
        /// Set when "Download" is offered.
        let downloadURL: URL?
    }

    static func content(for prompt: UpdateChecker.Prompt) -> Content {
        let running = prompt.currentVersion.map { "You have version \($0)." }
            ?? "This copy has no version number (it was not built by scripts/package-app.sh)."
        switch prompt.result {
        case .available(let release):
            let version = release.version?.description ?? release.tag
            return Content(title: "Hermes Bot \(version) is available",
                           message: "\(running) Download opens the release page in your browser; nothing is installed automatically.",
                           notes: release.notes.isEmpty ? nil : release.notes, downloadURL: release.pageURL)
        case .upToDate(let release):
            let version = release.version?.description ?? release.tag
            return Content(title: "Hermes Bot is up to date",
                           message: "Version \(prompt.currentVersion ?? version) is the latest release.",
                           notes: nil, downloadURL: nil)
        case .noRelease:
            return Content(title: "No release published yet",
                           message: "There is no Hermes Bot release on GitHub to update to.", notes: nil, downloadURL: nil)
        case .failed(let reason):
            return Content(title: "Couldn't check for updates", message: reason, notes: nil, downloadURL: nil)
        }
    }

    /// A background result found while another app is frontmost: shown when this app becomes active, so a daily
    /// check never takes focus from what the user is doing.
    @MainActor private static var waiting: (prompt: UpdateChecker.Prompt, observer: NSObjectProtocol)?

    @MainActor
    static func present(_ prompt: UpdateChecker.Prompt) {
        if prompt.trigger == .background, !NSApp.isActive {
            if let old = waiting { NotificationCenter.default.removeObserver(old.observer) }
            let observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard let pending = waiting else { return }
                    NotificationCenter.default.removeObserver(pending.observer)
                    waiting = nil
                    show(pending.prompt)
                }
            }
            waiting = (prompt, observer)
            return
        }
        if prompt.trigger == .manual { NSApp.activate(ignoringOtherApps: true) }
        show(prompt)
    }

    @MainActor
    private static func show(_ prompt: UpdateChecker.Prompt) {
        let content = content(for: prompt)
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        if case .failed = prompt.result { alert.alertStyle = .warning }
        if let notes = content.notes { alert.accessoryView = notesView(notes) }
        if content.downloadURL != nil {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "OK")
        }
        if alert.runModal() == .alertFirstButtonReturn, let url = content.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Release notes as plain text: inline Markdown markers (`**`, backticks, `[text](url)`) dropped, line
    /// layout kept. No clickable links; "Download" is the one way out of the alert.
    static func plainNotes(_ notes: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: notes, options: options) else { return notes }
        return String(parsed.characters)
    }

    /// Release notes as read-only, selectable, scrolling text.
    @MainActor
    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.textStorage?.setAttributedString(NSAttributedString(string: plainNotes(notes), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]))
        scroll.documentView = text
        return scroll
    }
}
