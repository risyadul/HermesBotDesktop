import Foundation

// E3 update check, pure parts: the GitHub Releases request and answer, the daily schedule and when a result is
// shown. No third-party updater: the app only reads `releases/latest` (unauthenticated, no token) and offers to
// open the release page; it never downloads or installs anything. UpdateChecker.swift runs it.

/// The fields of a GitHub release the app uses (`GET /repos/{owner}/{repo}/releases/latest`).
struct GitHubRelease: Equatable, Sendable {
    let tag: String
    /// The tag as a version; nil when the tag is not one ("nightly").
    let version: AppVersion?
    let title: String
    /// Markdown release notes, capped at `UpdatePolicy.notesLimit` characters.
    let notes: String
    /// Always a page of this repository's releases on github.com (`UpdatePolicy.releasePage`).
    let pageURL: URL
    let isPrerelease: Bool
    let isDraft: Bool

    private struct Wire: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let prerelease: Bool?
        let draft: Bool?
    }

    static func decode(_ data: Data) throws -> GitHubRelease {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let tag = wire.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty tag_name")) }
        let title = wire.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GitHubRelease(tag: tag, version: AppVersion(tag), title: title.isEmpty ? tag : title,
                             notes: UpdatePolicy.capNotes(wire.body ?? ""),
                             pageURL: UpdatePolicy.releasePage(wire.html_url, tag: tag),
                             isPrerelease: wire.prerelease ?? false, isDraft: wire.draft ?? false)
    }
}

enum UpdateCheckTrigger: Sendable {
    /// App menu → Check for Updates… or Settings → Check Now: every outcome is shown, failures included.
    case manual
    /// The daily check: only a new release is shown (once per release); failures stay quiet.
    case background
}

enum UpdateCheckResult: Equatable, Sendable {
    case available(GitHubRelease)
    case upToDate(GitHubRelease)
    /// The repository has no published release yet (404).
    case noRelease
    /// A user-facing reason (no URLs, no response bodies).
    case failed(String)
}

enum UpdatePolicy {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/risyadul/HermesBotDesktop/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/risyadul/HermesBotDesktop/releases")!
    /// Daily, checked from an hourly tick (UpdateChecker), so a Mac that slept through the due time checks soon after.
    static let interval: TimeInterval = 24 * 60 * 60
    static let notesLimit = 20_000
    /// A release answer is a few KB; anything far larger is not one.
    static let responseLimit = 1 << 20
    static let timeout: TimeInterval = 20

    /// UserDefaults keys. `autoCheckKey`: Settings → Updates switch, on by default.
    static let autoCheckKey = "hba.updates.autoCheck"
    static let autoCheckByDefault = true
    static let lastCheckKey = "hba.updates.lastCheck"
    /// The tag a background check last showed, so the daily check does not show the same release every day.
    static let lastShownTagKey = "hba.updates.lastShownTag"

    static func isAutoCheckOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoCheckKey) as? Bool ?? autoCheckByDefault
    }

    /// A check is due when automatic checks are on and the last successful one is a day old, never happened, or
    /// lies in the future (the clock was set back).
    static func isDue(autoCheck: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard autoCheck else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Unauthenticated: no token, no cookies (the session is ephemeral). GitHub asks for a User-Agent.
    static func request(appVersion: String?) -> URLRequest {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("HermesBotApp/\(appVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The answer to `request`. `current` nil (a build without a version, e.g. `swift run`): any release is offered.
    static func result(status: Int, data: Data, current: AppVersion?) -> UpdateCheckResult {
        switch status {
        case 200:
            guard data.count <= responseLimit, let release = try? GitHubRelease.decode(data) else {
                return .failed("GitHub sent an answer the app could not read.")
            }
            // `releases/latest` never returns drafts or pre-releases; if it ever does, they are not offered.
            guard !release.isDraft, !release.isPrerelease else { return .noRelease }
            guard let latest = release.version else { return .failed("The latest release (\(release.tag)) has no version number.") }
            if let current, latest <= current { return .upToDate(release) }
            return .available(release)
        case 404:
            return .noRelease
        case 403, 429:
            return .failed("GitHub's limit for unauthenticated requests was reached. Try again in an hour.")
        default:
            return .failed("GitHub answered with HTTP status \(status). Try again later.")
        }
    }

    static func failure(_ error: Error) -> UpdateCheckResult {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .failed("This Mac is offline.")
            case .timedOut:
                return .failed("GitHub did not answer in time.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failed("GitHub could not be reached.")
            default: break
            }
        }
        return .failed("GitHub could not be reached.")
    }

    /// Whether a check's result is shown. Manual: always. Background: only a release not shown by an earlier
    /// background check; "up to date", "no release" and failures stay quiet.
    static func shouldShow(_ result: UpdateCheckResult, trigger: UpdateCheckTrigger, lastShownTag: String?) -> Bool {
        switch trigger {
        case .manual: return true
        case .background:
            if case .available(let release) = result { return release.tag != lastShownTag }
            return false
        }
    }

    /// The release page to open: GitHub's `html_url` only when it is a page of this repository's releases on
    /// github.com over https; otherwise the tag's page, built here.
    static func releasePage(_ htmlURL: String?, tag: String) -> URL {
        if let htmlURL, let url = URL(string: htmlURL), url.scheme == "https", url.host == "github.com",
           url.user == nil, url.password == nil, url.port == nil,
           url.path.hasPrefix(releasesPage.path + "/"), !url.pathComponents.contains("..") {
            return url
        }
        // A tag of plain characters only (no "/", "..", "%"); anything else gets the releases list.
        let plain = tag.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)) }
        guard plain, tag.rangeOfCharacter(from: CharacterSet.letters.union(.decimalDigits)) != nil else { return releasesPage }
        return releasesPage.appendingPathComponent("tag").appendingPathComponent(tag, isDirectory: false)
    }

    static func capNotes(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > notesLimit else { return trimmed }
        return String(trimmed.prefix(notesLimit)) + "\n\n…"
    }
}
