import Foundation
import XCTest
@testable import HermesBotApp

/// E3 update check: version order, the GitHub release answer (a fixture, never the real API), the daily schedule
/// and what is shown when. The checker gets a fake fetch, a throwaway defaults suite and a recording presenter.
@MainActor
final class UpdateCheckTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "hba-updates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    /// Trimmed from a real `GET /repos/{owner}/{repo}/releases/latest` answer (fields the app ignores left in).
    nonisolated static func releaseJSON(tag: String = "v0.3.0", body: String = "## What's Changed\\n* **Updates**: check daily by @someone in [#12](https://github.com/risyadul/HermesBotDesktop/pull/12)",
                            htmlURL: String? = nil, prerelease: Bool = false, draft: Bool = false) -> Data {
        let html = htmlURL ?? "https://github.com/risyadul/HermesBotDesktop/releases/tag/\(tag)"
        return Data("""
        {
          "url": "https://api.github.com/repos/risyadul/HermesBotDesktop/releases/123456789",
          "html_url": "\(html)",
          "id": 123456789,
          "author": {"login": "risyadul", "id": 1, "type": "User"},
          "node_id": "RE_kwDOExample",
          "tag_name": "\(tag)",
          "target_commitish": "main",
          "name": "\(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "created_at": "2026-11-01T10:00:00Z",
          "published_at": "2026-11-01T10:05:00Z",
          "assets": [{"name": "HermesBot-0.3.0-macos-universal.zip", "size": 4194304, "content_type": "application/zip",
                      "browser_download_url": "https://github.com/risyadul/HermesBotDesktop/releases/download/\(tag)/HermesBot-0.3.0-macos-universal.zip"}],
          "tarball_url": "https://api.github.com/repos/risyadul/HermesBotDesktop/tarball/\(tag)",
          "zipball_url": "https://api.github.com/repos/risyadul/HermesBotDesktop/zipball/\(tag)",
          "body": "\(body)"
        }
        """.utf8)
    }

    // MARK: version order

    func testVersionParsing() throws {
        XCTAssertEqual(AppVersion("1.2.3")?.core, [1, 2, 3])
        XCTAssertEqual(AppVersion("v0.2")?.core, [0, 2, 0])
        XCTAssertEqual(AppVersion(" V7 ")?.core, [7, 0, 0])
        XCTAssertEqual(AppVersion("1.0.0-beta.2+exp.sha.5114f85")?.prerelease, ["beta", "2"])
        XCTAssertEqual(AppVersion("1.0.0+build.7")?.description, "1.0.0")
        XCTAssertEqual(AppVersion("2.0.0-rc.1")?.description, "2.0.0-rc.1")
        for bad in ["", "v", "1.2.3.4", "1..2", "1.2.", "a.b.c", "1.2.3-", "1.2.3-beta..1", "1.2.3-01", "-1.2.3", "1.2.x",
                    "1.2.3-bêta", "nightly", "1234567890.0.0"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testVersionOrder() throws {
        // semver 2.0.0 §11 example, ascending.
        let ascending = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                         "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1", "1.10.0", "2"]
        let versions = try ascending.map { try XCTUnwrap(AppVersion($0), $0) }
        for (i, a) in versions.enumerated() {
            for (j, b) in versions.enumerated() {
                XCTAssertEqual(a < b, i < j, "\(a) < \(b)")
                XCTAssertEqual(a == b, i == j, "\(a) == \(b)")
            }
        }
        XCTAssertEqual(AppVersion("v0.2"), AppVersion("0.2.0"))
        XCTAssertEqual(AppVersion("1.0.0+a"), AppVersion("1.0.0+b"), "build metadata is ignored")
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.9")), try XCTUnwrap(AppVersion("0.10.0")), "numeric, not string, order")
    }

    // MARK: the GitHub answer

    func testReleaseFixtureDecodes() throws {
        let release = try GitHubRelease.decode(Self.releaseJSON())
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.version, AppVersion("0.3.0"))
        XCTAssertEqual(release.title, "v0.3.0")
        XCTAssertTrue(release.notes.hasPrefix("## What's Changed\n* **Updates**"))
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/risyadul/HermesBotDesktop/releases/tag/v0.3.0")
        XCTAssertFalse(release.isPrerelease)
        XCTAssertFalse(release.isDraft)
    }

    func testReleasePageIsAlwaysThisRepositorysReleases() throws {
        let fallback = "https://github.com/risyadul/HermesBotDesktop/releases/tag/v0.3.0"
        for hostile in ["https://evil.example/risyadul/HermesBotDesktop/releases/tag/v0.3.0",
                        "http://github.com/risyadul/HermesBotDesktop/releases/tag/v0.3.0",
                        "https://github.com/someone-else/HermesBotDesktop/releases/tag/v0.3.0",
                        "https://github.com/risyadul/HermesBotDesktop/releases/../../../login",
                        "https://user@github.com/risyadul/HermesBotDesktop/releases/tag/v0.3.0",
                        "https://github.com:8443/risyadul/HermesBotDesktop/releases/tag/v0.3.0",
                        "file:///etc/passwd", "javascript:alert(1)", ""] {
            let release = try GitHubRelease.decode(Self.releaseJSON(htmlURL: hostile))
            XCTAssertEqual(release.pageURL.absoluteString, fallback, hostile)
        }
        XCTAssertEqual(UpdatePolicy.releasePage(nil, tag: "../x").absoluteString, "https://github.com/risyadul/HermesBotDesktop/releases")
        XCTAssertEqual(UpdatePolicy.releasePage(nil, tag: "..").absoluteString, "https://github.com/risyadul/HermesBotDesktop/releases")
    }

    func testMalformedAnswersAreFailures() {
        for data in [Data("{}".utf8), Data("not json".utf8), Data(#"{"tag_name": "  "}"#.utf8), Data()] {
            guard case .failed = UpdatePolicy.result(status: 200, data: data, current: AppVersion("0.2.0")) else {
                return XCTFail("accepted \(String(decoding: data, as: UTF8.self))")
            }
        }
        let huge = Data(count: UpdatePolicy.responseLimit + 1)
        guard case .failed = UpdatePolicy.result(status: 200, data: huge, current: nil) else { return XCTFail("oversized answer") }
        guard case .failed = UpdatePolicy.result(status: 200, data: Self.releaseJSON(tag: "nightly"), current: nil) else {
            return XCTFail("a tag that is not a version is not offered")
        }
    }

    func testNotesAreCapped() throws {
        let long = String(repeating: "x", count: UpdatePolicy.notesLimit + 500)
        let release = try GitHubRelease.decode(Self.releaseJSON(body: long))
        XCTAssertEqual(release.notes.count, UpdatePolicy.notesLimit + 3)
        XCTAssertTrue(release.notes.hasSuffix("\n\n…"))
    }

    func testResultByStatusAndVersion() {
        let current = AppVersion("0.2.0")
        guard case .available(let r) = UpdatePolicy.result(status: 200, data: Self.releaseJSON(tag: "v0.3.0"), current: current) else {
            return XCTFail("newer release")
        }
        XCTAssertEqual(r.tag, "v0.3.0")
        guard case .upToDate = UpdatePolicy.result(status: 200, data: Self.releaseJSON(tag: "v0.2.0"), current: current) else {
            return XCTFail("same version")
        }
        guard case .upToDate = UpdatePolicy.result(status: 200, data: Self.releaseJSON(tag: "v0.1.9"), current: current) else {
            return XCTFail("older release")
        }
        guard case .available = UpdatePolicy.result(status: 200, data: Self.releaseJSON(tag: "v0.2.0"), current: AppVersion("0.2.0-rc.1")) else {
            return XCTFail("a release after its own pre-release")
        }
        guard case .available = UpdatePolicy.result(status: 200, data: Self.releaseJSON(), current: nil) else {
            return XCTFail("no running version: offered")
        }
        XCTAssertEqual(UpdatePolicy.result(status: 200, data: Self.releaseJSON(prerelease: true), current: current), .noRelease)
        XCTAssertEqual(UpdatePolicy.result(status: 200, data: Self.releaseJSON(draft: true), current: current), .noRelease)
        XCTAssertEqual(UpdatePolicy.result(status: 404, data: Data(), current: current), .noRelease)
        for status in [403, 429, 500, 0] {
            guard case .failed = UpdatePolicy.result(status: status, data: Self.releaseJSON(), current: current) else {
                return XCTFail("HTTP \(status)")
            }
        }
    }

    func testRequestIsUnauthenticatedWithUserAgent() {
        let request = UpdatePolicy.request(appVersion: "0.2.0")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/risyadul/HermesBotDesktop/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "HermesBotApp/0.2.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(UpdatePolicy.request(appVersion: nil).value(forHTTPHeaderField: "User-Agent"), "HermesBotApp/dev")
    }

    // MARK: schedule

    func testDailySchedule() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(UpdatePolicy.isDue(autoCheck: true, lastCheck: nil, now: now), "never checked")
        XCTAssertFalse(UpdatePolicy.isDue(autoCheck: false, lastCheck: nil, now: now), "switch off")
        XCTAssertFalse(UpdatePolicy.isDue(autoCheck: true, lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UpdatePolicy.isDue(autoCheck: true, lastCheck: now.addingTimeInterval(-UpdatePolicy.interval + 1), now: now))
        XCTAssertTrue(UpdatePolicy.isDue(autoCheck: true, lastCheck: now.addingTimeInterval(-UpdatePolicy.interval), now: now))
        XCTAssertTrue(UpdatePolicy.isDue(autoCheck: true, lastCheck: now.addingTimeInterval(3600), now: now), "clock set back")
        XCTAssertTrue(UpdatePolicy.isAutoCheckOn(defaults), "on by default")
        UpdatesSection.setting(defaults).wrappedValue = false
        XCTAssertFalse(UpdatePolicy.isAutoCheckOn(defaults), "Settings switch is what the schedule reads")
    }

    func testWhatIsShown() throws {
        let release = try GitHubRelease.decode(Self.releaseJSON())
        let results: [UpdateCheckResult] = [.available(release), .upToDate(release), .noRelease, .failed("offline")]
        for result in results {
            XCTAssertTrue(UpdatePolicy.shouldShow(result, trigger: .manual, lastShownTag: release.tag), "manual shows \(result)")
        }
        XCTAssertTrue(UpdatePolicy.shouldShow(.available(release), trigger: .background, lastShownTag: nil))
        XCTAssertTrue(UpdatePolicy.shouldShow(.available(release), trigger: .background, lastShownTag: "v0.2.5"))
        XCTAssertFalse(UpdatePolicy.shouldShow(.available(release), trigger: .background, lastShownTag: release.tag), "once per release")
        for quiet in results.dropFirst() {
            XCTAssertFalse(UpdatePolicy.shouldShow(quiet, trigger: .background, lastShownTag: nil), "background quiet on \(quiet)")
        }
    }

    // MARK: checker

    private final class FakeNetwork: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var answer: Result<(Int, Data), Error> = .success((200, UpdateCheckTests.releaseJSON()))
        var requests: [URLRequest] { lock.withLock { _requests } }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let answer = lock.withLock { _requests.append(request); return self.answer }
            let (status, data) = try answer.get()
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func checker(version: String? = "0.2.0", network: FakeNetwork, clock: @escaping () -> Date = Date.init,
                         shown: @escaping @MainActor (UpdateChecker.Prompt) -> Void) -> UpdateChecker {
        UpdateChecker(defaults: defaults, currentVersion: version, fetch: { try await network.fetch($0) }, now: clock, present: shown)
    }

    func testManualCheckShowsEveryOutcome() async throws {
        let network = FakeNetwork()
        var shown: [UpdateChecker.Prompt] = []
        let c = checker(network: network) { shown.append($0) }

        guard case .available = await c.check(.manual) else { return XCTFail("newer release") }
        network.answer = .success((200, Self.releaseJSON(tag: "v0.2.0")))
        guard case .upToDate = await c.check(.manual) else { return XCTFail("same version") }
        network.answer = .failure(URLError(.notConnectedToInternet))
        let offline = await c.check(.manual)
        XCTAssertEqual(offline, .failed("This Mac is offline."))
        XCTAssertEqual(shown.count, 3, "a manual check always answers")
        XCTAssertEqual(shown.first?.currentVersion, "0.2.0")
        XCTAssertEqual(shown.map(\.trigger), [.manual, .manual, .manual])
        XCTAssertEqual(network.requests.first?.value(forHTTPHeaderField: "User-Agent"), "HermesBotApp/0.2.0")
        XCTAssertNil(defaults.string(forKey: UpdatePolicy.lastShownTagKey), "manual checks do not mark a release as shown")
    }

    func testBackgroundCheckIsQuietOnFailureAndShowsAReleaseOnce() async throws {
        let network = FakeNetwork()
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        var shown: [UpdateChecker.Prompt] = []
        let c = checker(network: network, clock: { now }) { shown.append($0) }

        network.answer = .failure(URLError(.timedOut))
        let timedOut = await c.checkIfDue()
        XCTAssertEqual(timedOut, .failed("GitHub did not answer in time."))
        XCTAssertTrue(shown.isEmpty, "background failures stay quiet")
        XCTAssertNil(c.lastCheck, "a failed check is retried at the next tick")

        network.answer = .success((200, Self.releaseJSON(tag: "v0.3.0")))
        guard case .available = await c.checkIfDue() else { return XCTFail("due: never succeeded") }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.trigger, .background, "waits for the app to be frontmost instead of taking focus")
        XCTAssertEqual(c.lastCheck, now)
        XCTAssertEqual(defaults.object(forKey: UpdatePolicy.lastCheckKey) as? Date, now)

        now += 3600
        let early = await c.checkIfDue()
        XCTAssertNil(early, "not due an hour later")
        now += UpdatePolicy.interval
        guard case .available = await c.checkIfDue() else { return XCTFail("due a day later") }
        XCTAssertEqual(shown.count, 1, "the same release is not shown every day")
        XCTAssertEqual(network.requests.count, 3)

        now += UpdatePolicy.interval
        network.answer = .success((200, Self.releaseJSON(tag: "v0.4.0")))
        await c.checkIfDue()
        XCTAssertEqual(shown.count, 2, "a newer release is shown")
        guard case .available(let r) = shown.last?.result else { return XCTFail() }
        XCTAssertEqual(r.tag, "v0.4.0")
    }

    func testNoBackgroundCheckWhenSwitchedOffOrUnversioned() async {
        let network = FakeNetwork()
        var shown = 0
        UpdatesSection.setting(defaults).wrappedValue = false
        let switchedOff = await checker(network: network) { _ in shown += 1 }.checkIfDue()
        XCTAssertNil(switchedOff)
        UpdatesSection.setting(defaults).wrappedValue = true
        let unversioned = await checker(version: nil, network: network) { _ in shown += 1 }.checkIfDue()
        XCTAssertNil(unversioned, "swift run builds never check by themselves")
        let devVersion = await checker(version: "dev", network: network) { _ in shown += 1 }.checkIfDue()
        XCTAssertNil(devVersion)
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(shown, 0)

        // A manual check still works in an unversioned build, and offers the latest release.
        guard case .available = await checker(version: nil, network: network) { _ in shown += 1 }.check(.manual) else {
            return XCTFail("manual check in a dev build")
        }
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(network.requests.last?.value(forHTTPHeaderField: "User-Agent"), "HermesBotApp/dev")
    }

    // MARK: alert text

    func testAlertContent() throws {
        let release = try GitHubRelease.decode(Self.releaseJSON())
        let available = UpdateAlert.content(for: .init(result: .available(release), currentVersion: "0.2.0"))
        XCTAssertEqual(available.title, "Hermes Bot 0.3.0 is available")
        XCTAssertTrue(available.message.hasPrefix("You have version 0.2.0."))
        XCTAssertTrue(available.message.contains("nothing is installed automatically"))
        XCTAssertEqual(available.downloadURL, release.pageURL)
        XCTAssertNotNil(available.notes)

        let dev = UpdateAlert.content(for: .init(result: .available(release), currentVersion: nil))
        XCTAssertTrue(dev.message.contains("no version number"))

        let upToDate = UpdateAlert.content(for: .init(result: .upToDate(release), currentVersion: "0.3.0"))
        XCTAssertEqual(upToDate.title, "Hermes Bot is up to date")
        XCTAssertNil(upToDate.downloadURL)

        let failed = UpdateAlert.content(for: .init(result: .failed("This Mac is offline."), currentVersion: "0.3.0"))
        XCTAssertEqual(failed.message, "This Mac is offline.")
        XCTAssertNil(failed.downloadURL)

        XCTAssertEqual(UpdateAlert.plainNotes("* **Bold** and `code` in [#12](https://example.com/x)"), "* Bold and code in #12")
    }
}
