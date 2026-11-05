import Foundation

/// Typed calls to the optional `bot-activity` plugin (github.com/risyadul/hermes-bot-activity,
/// `dashboard/plugin_api.py`), mounted at `/api/plugins/bot-activity/`. It records per-bot LLM turns, tool
/// calls, approvals and Group Chat member reasoning/message streams — events that never reach `groups.log`.
/// A missing or disabled plugin surfaces as `PluginREST.Failure.pluginUnavailable`.
public struct BotActivityAPI: Sendable {
    public static let pluginName = "bot-activity"
    /// `DEFAULT_LIMIT` / `MAX_LIMIT` (`plugin_api.py:22-23`).
    public static let defaultLimit = 300
    public static let maxLimit = 1000
    /// A running/waiting row not updated for this long is abandoned (`STALE_AFTER_S`, `plugin_api.py:25`).
    public static let staleAfter: TimeInterval = 15 * 60
    /// A stream with no update for this long is done: rooms have no end frame (`STREAM_QUIET_S`, `:27`).
    public static let streamQuiet: TimeInterval = 30

    public let rest: PluginREST

    public init(access: SessionRESTAccess, timeout: TimeInterval = 15) {
        rest = PluginREST(access: access, plugin: Self.pluginName, timeout: timeout)
    }

    public init(rest: PluginREST) { self.rest = rest }

    /// `GET /activity?since=&room=&bot=&limit=` (`plugin_api.py:52-75`). `since: 0` = the most recent
    /// `limit` rows (oldest first); `since > 0` = rows with `rev > since` in rev order, cut at `limit`.
    /// Feed the page to `BotActivityFeed.apply`, which picks the next cursor.
    public func activity(room: String?, bot: String? = nil, since: Int, limit: Int = BotActivityAPI.defaultLimit) async throws -> BotActivityPage {
        let lim = min(max(1, limit), Self.maxLimit)
        var q: [URLQueryItem] = [.init(name: "since", value: String(max(0, since))), .init(name: "limit", value: String(lim))]
        if let room, !room.isEmpty { q.append(.init(name: "room", value: room)) }
        if let bot, !bot.isEmpty { q.append(.init(name: "bot", value: bot)) }
        let r = try await rest.get("/activity", query: q)
        guard let rows = r["rows"]?.array else { throw PluginREST.Failure.decode("activity: missing 'rows'") }
        return BotActivityPage(rows: rows.compactMap(BotActivityRow.init(json:)), rev: r["rev"]?.intValue ?? 0,
                               now: r["now"]?.double, since: max(0, since), limit: lim)
    }

    /// `GET /bots` (`plugin_api.py:78-102`): every known bot with its live work items.
    public func bots() async throws -> [BotActivityBot] {
        let r = try await rest.get("/bots")
        return (r["bots"]?.array ?? []).compactMap(BotActivityBot.init(json:))
    }

    /// `GET /setup` (`plugin_api.py:127-139`): which profiles carry an up-to-date, enabled copy.
    public func setupStatus() async throws -> BotActivitySetup {
        let r = try await rest.get("/setup")
        return BotActivitySetup(
            profiles: (r["profiles"]?.array ?? []).compactMap(BotActivitySetup.Profile.init(json:)),
            untracked: (r["untracked"]?.array ?? []).compactMap(\.string),
            outdated: (r["outdated"]?.array ?? []).compactMap(\.string),
            optedOut: (r["opted_out"]?.array ?? []).compactMap(\.string))
    }

    /// `POST /setup {bots?}` (`plugin_api.py:142-153`): copies/refreshes and enables the plugin in each target
    /// profile (`bots: nil` = every untracked or outdated, not opted-out profile). Results per bot.
    public func rollOut(bots: [String]? = nil) async throws -> BotActivityRollOut {
        let body: JSONValue = bots.map { ["bots": .array($0.map(JSONValue.string))] } ?? [:]
        let r = try await rest.post("/setup", body: body)
        let results = (r["results"]?.array ?? []).compactMap(BotActivityRollOut.Result.init(json:))
        return BotActivityRollOut(results: results, ok: r["ok"]?.bool ?? results.allSatisfy(\.ok))
    }
}

/// One row of the plugin's `events` table (`store.py:54-72`, `row_to_dict` `:212-221`). `args`/`result`
/// are JSON when the stored text parses as an object/array, else the raw string.
public struct BotActivityRow: Sendable, Equatable, Identifiable {
    public let key: String
    public let rev: Int
    public let ts: Double
    public let updated: Double
    public let bot: String?
    public let sessionId: String?
    public let turnId: String?
    public let roomId: String?
    public let threadId: String?
    public let memberId: String?
    /// `tool`, `turn`, `reasoning`, `message`, … (open).
    public let kind: String
    /// `ok`, `error`, `running`, `waiting`, `streaming`, `done`, … (open).
    public let status: String?
    public let title: String?
    public let args: JSONValue?
    public let result: JSONValue?
    public let text: String?
    public let durationMs: Int?
    public var id: String { key }

    public init(key: String, rev: Int, ts: Double, updated: Double, bot: String? = nil, sessionId: String? = nil,
                turnId: String? = nil, roomId: String? = nil, threadId: String? = nil, memberId: String? = nil,
                kind: String, status: String? = nil, title: String? = nil, args: JSONValue? = nil,
                result: JSONValue? = nil, text: String? = nil, durationMs: Int? = nil) {
        self.key = key; self.rev = rev; self.ts = ts; self.updated = updated; self.bot = bot
        self.sessionId = sessionId; self.turnId = turnId; self.roomId = roomId; self.threadId = threadId
        self.memberId = memberId; self.kind = kind; self.status = status; self.title = title; self.args = args
        self.result = result; self.text = text; self.durationMs = durationMs
    }

    /// nil without a `key` or `rev`; everything else is optional.
    public init?(json j: JSONValue) {
        guard let key = j["key"]?.nonEmptyString, let rev = j["rev"]?.intValue else { return nil }
        let ts = j["ts"]?.double ?? 0
        self.init(key: key, rev: rev, ts: ts, updated: j["updated"]?.double ?? ts, bot: j["bot"]?.nonEmptyString,
                  sessionId: j["session_id"]?.nonEmptyString, turnId: j["turn_id"]?.nonEmptyString,
                  roomId: j["room_id"]?.nonEmptyString, threadId: j["thread_id"]?.nonEmptyString,
                  memberId: j["member_id"]?.nonEmptyString, kind: j["kind"]?.string ?? "",
                  status: j["status"]?.nonEmptyString, title: j["title"]?.nonEmptyString,
                  args: j["args"]?.nonNull, result: j["result"]?.nonNull,
                  text: j["text"]?.string, durationMs: j["duration_ms"]?.intValue)
    }
}

/// One `GET /activity` answer plus the request it answered (the cursor rule needs both).
public struct BotActivityPage: Sendable, Equatable {
    public let rows: [BotActivityRow]
    /// Max rev of the whole store (not room-filtered), never below `since`.
    public let rev: Int
    /// Server clock (epoch seconds) for freshness checks; nil if absent.
    public let now: Double?
    public let since: Int
    public let limit: Int

    public init(rows: [BotActivityRow], rev: Int, now: Double?, since: Int, limit: Int) {
        self.rows = rows; self.rev = rev; self.now = now; self.since = since; self.limit = limit
    }
}

/// `GET /bots` entry.
public struct BotActivityBot: Sendable, Equatable, Identifiable {
    public struct Item: Sendable, Equatable {
        public let key: String
        public let kind: String
        public let status: String?
        public let title: String?
        public let roomId: String?
        public let threadId: String?
        public let ts: Double?
        public let updated: Double?
    }

    public let bot: String
    public let title: String?
    public let lastSeen: Double?
    public let active: [Item]
    public var id: String { bot }

    init?(json j: JSONValue) {
        guard let bot = j["bot"]?.nonEmptyString else { return nil }
        self.bot = bot
        title = j["title"]?.nonEmptyString
        lastSeen = j["last_seen"]?.double
        active = (j["active"]?.array ?? []).compactMap { a in
            a["key"]?.nonEmptyString.map {
                Item(key: $0, kind: a["kind"]?.string ?? "", status: a["status"]?.nonEmptyString, title: a["title"]?.nonEmptyString,
                     roomId: a["room_id"]?.nonEmptyString, threadId: a["thread_id"]?.nonEmptyString,
                     ts: a["ts"]?.double, updated: a["updated"]?.double)
            }
        }
    }
}

/// `GET /setup` (`installer.profile_status`, `installer.py:146-159`).
public struct BotActivitySetup: Sendable, Equatable {
    public struct Profile: Sendable, Equatable, Identifiable {
        public let bot: String
        public let title: String?
        public let installed: Bool
        public let enabled: Bool
        public let outdated: Bool
        public let optedOut: Bool
        /// installed AND enabled.
        public let tracked: Bool
        public var id: String { bot }

        init?(json j: JSONValue) {
            guard let bot = j["bot"]?.nonEmptyString else { return nil }
            self.bot = bot
            title = j["title"]?.nonEmptyString
            installed = j["installed"]?.bool ?? false
            enabled = j["enabled"]?.bool ?? false
            outdated = j["outdated"]?.bool ?? false
            optedOut = j["opted_out"]?.bool ?? false
            tracked = j["tracked"]?.bool ?? (installed && enabled)
        }
    }

    public let profiles: [Profile]
    public let untracked: [String]
    public let outdated: [String]
    public let optedOut: [String]

    /// Something `rollOut()` would change.
    public var needsRollOut: Bool { !untracked.isEmpty || !outdated.isEmpty }
}

/// `POST /setup` answer (`installer.track`, `installer.py:244-288`).
public struct BotActivityRollOut: Sendable, Equatable {
    public struct Result: Sendable, Equatable {
        public let bot: String
        public let ok: Bool
        public let changed: Bool
        public let error: String?
        public let note: String?
        public let restartNeeded: Bool

        init?(json j: JSONValue) {
            guard let bot = j["bot"]?.nonEmptyString else { return nil }
            self.bot = bot
            ok = j["ok"]?.bool ?? false
            changed = j["changed"]?.bool ?? false
            error = j["error"]?.nonEmptyString
            note = j["note"]?.nonEmptyString
            restartNeeded = j["restart_needed"]?.bool ?? false
        }
    }

    public let results: [Result]
    public let ok: Bool
}

/// Installing the plugin through the gateway's Plugins Hub RPC, `plugins.manage {action, ...}`
/// (`tui_gateway/methods_tools.py:1854-1935,1962-1972`; params `PluginsManageParams`,
/// `tui_gateway/contracts/tools_mcp_plugins.py:594-610`). The legacy `plugins.list` (`methods_tools.py:268`)
/// lists only LOADED plugins, so an installed-but-disabled copy would read as missing; `plugins.manage list`
/// lists every discovered plugin with its activation `status`.
public struct BotActivityPluginManager: Sendable {
    public static let repository = "https://github.com/risyadul/hermes-bot-activity"
    /// The reviewed commit installed by `installBotActivity()` (full SHA: `plugins.manage install` pins `ref`).
    public static let pinnedRef = "da1c9d10eb228cd6f0a93e255ee92c8c3a6717f2"
    /// A git clone + dependency check: far slower than a normal call.
    public static let installTimeout: TimeInterval = 240

    public enum State: Sendable, Equatable {
        case notInstalled
        /// `status`: `enabled`, `disabled` or `not enabled` (`_plugin_status`, `hermes_cli/plugins_cmd.py:887-900`).
        /// `pinnedSHA`: the row's `pinned_sha`, the full commit a `--ref` install is pinned to
        /// (`pinned_revision`, `hermes_cli/plugins_cmd_git.py:90-95`); nil for a manual/dev copy or an unpinned
        /// install (no install record with `pinned: true`).
        case installed(status: String, version: String, source: String, pinnedSHA: String?)

        public var isEnabled: Bool { if case .installed(let s, _, _, _) = self { return s == "enabled" }; return false }

        /// The installed copy is provably the reviewed commit: Hermes's install record pins it to `pinnedRef`.
        /// A commit SHA fixes the whole tree, so the repository it was cloned from does not matter
        /// (`plugins.manage list` does not report the clone URL).
        public var isPinnedCopy: Bool {
            if case .installed(_, _, _, let sha?) = self { return sha.lowercased() == BotActivityPluginManager.pinnedRef }
            return false
        }
    }

    public let client: GatewayClient
    public init(client: GatewayClient) { self.client = client }

    /// `plugins.manage {action: "list"}` rows as received (`_plugin_rows`, `methods_tools.py:1790-1819`).
    public func pluginsList() async throws -> [JSONValue] {
        let r = try await client.call("plugins.manage", ["action": "list"], timeout: 60)
        return SchemaLog.array(r, "plugins", method: "plugins.manage list")
    }

    public func botActivityState() async throws -> State { Self.state(fromRows: try await pluginsList()) }

    /// `plugins.manage {action: "install", repo, ref, enable: true}` (`_plugins_install`, `:1880-1893`).
    /// `force: true` replaces an existing copy (`dashboard_install_plugin(force:)`, which install otherwise
    /// refuses with "already exists"): "Reinstall Pinned Version" over a copy that is not the reviewed one.
    @discardableResult
    public func installBotActivity(force: Bool = false) async throws -> JSONValue {
        var params: [String: JSONValue] = ["action": "install", "repo": .string(Self.repository), "ref": .string(Self.pinnedRef), "enable": true]
        if force { params["force"] = true }
        return try await client.call("plugins.manage", .object(params), timeout: Self.installTimeout)
    }

    /// `plugins.manage {action: "toggle", name, enable: true}` (`_plugins_toggle`, `:1860-1877`): turns on a copy
    /// that is installed but disabled (install would refuse an existing directory).
    @discardableResult
    public func enableBotActivity() async throws -> JSONValue {
        try await client.call("plugins.manage", ["action": "toggle", "name": .string(BotActivityAPI.pluginName), "enable": true],
                              timeout: 60)
    }

    /// `plugins.manage {action: "remove", name}` (`_plugins_remove`, `:1926-1934`): user installs only.
    @discardableResult
    public func removeBotActivity() async throws -> JSONValue {
        try await client.call("plugins.manage", ["action": "remove", "name": .string(BotActivityAPI.pluginName)], timeout: 60)
    }

    static func state(fromRows rows: [JSONValue]) -> State {
        let name = BotActivityAPI.pluginName
        guard let row = rows.first(where: { $0["name"]?.string == name || $0["key"]?.string == name }) else { return .notInstalled }
        return .installed(status: row["status"]?.string ?? (row["enabled"]?.bool == true ? "enabled" : "not enabled"),
                          version: row["version"]?.string ?? "", source: row["source"]?.string ?? "",
                          pinnedSHA: row["pinned_sha"]?.nonEmptyString)
    }
}

/// Turns the plugin on or off in ONE bot profile with the Hermes CLI, `hermes -p <bot> plugins enable|disable
/// bot-activity` (`cmd_enable`/`cmd_disable`, `hermes_cli/plugins_cmd.py:689-760`): the profile's
/// `plugins.enabled`/`plugins.disabled` lists change, its copy stays on disk. Roll-out copies the plugin into
/// every profile, so removing the root copy alone would leave every bot recording; and `POST /setup` skips a
/// profile that lists the plugin in `plugins.disabled` (`installer.py:244-265`), so Enable turns those back on
/// here first. The hermes binary passes the same checks as every hermes the app runs
/// (`ServeProcess.trustedExecutable`); no shell, clean environment, always an explicit `-p` (without it the CLI
/// follows the sticky active profile), a timeout.
public struct BotActivityProfileSwitch: Sendable {
    /// `ENABLE_TIMEOUT_S` (`installer.py:40`): enable waits for the live activation round trips.
    public static let timeout: TimeInterval = 150

    public struct Failure: Error, RedactionSafeError, Equatable {
        public let description: String
    }

    public let home: URL
    let environment: [String: String]
    let runner: any CommandRunner

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: any CommandRunner = ProcessCommandRunner()) {
        self.home = home; self.environment = environment; self.runner = runner
    }

    /// `PROFILE_ID_RE` (`hermes_constants.py:320`). Anything else never reaches the command line.
    public static func isProfileName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    public static func arguments(bot: String, enable: Bool) -> [String] {
        ["-p", bot, "plugins", enable ? "enable" : "disable", BotActivityAPI.pluginName]
    }

    /// Throws `Failure` (Redaction-safe) for a bad name, an untrusted/missing hermes, a launch error, a
    /// non-zero exit or a timeout.
    public func setEnabled(_ enable: Bool, bot: String) async throws {
        guard Self.isProfileName(bot) else { throw Failure(description: "not a profile name") }
        let hermes: String
        switch ServeProcess.trustedExecutable(environment: environment, home: home, log: home.appendingPathComponent(".hermes/logs").path) {
        case .success(let path): hermes = path
        case .failure(let e): throw Failure(description: Redaction.scrub(e.description))
        }
        var env = ProcessCommandRunner.cleanEnvironment(environment)
        env["HOME"] = home.path
        env["HERMES_HOME"] = home.appendingPathComponent(".hermes").path
        env["PATH"] = BackgroundServe.path(hermes: hermes, home: home.path)
        let r: CommandResult
        do { r = try await runner.run(hermes, Self.arguments(bot: bot, enable: enable), environment: env, timeout: Self.timeout) } catch {
            throw Failure(description: Redaction.describe(error))
        }
        guard r.succeeded else {
            if r.timedOut { throw Failure(description: "timed out") }
            let last = Redaction.scrub(r.output).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let detail = last.trimmingCharacters(in: .whitespaces).prefix(200)
            throw Failure(description: detail.isEmpty ? "hermes exited with \(r.status)" : String(detail))
        }
    }
}
