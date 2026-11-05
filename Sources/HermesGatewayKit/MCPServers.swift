import Foundation

/// A14: one bot's MCP servers, over the gateway's per-profile `mcp.servers.*` methods
/// (`tui_gateway/methods_tools.py`), as Hermes Desktop's MCP setup uses them (`mcp-setup.tsx`,
/// `lib/mcp-dashboard-oauth.ts`). Every call carries `profile`, so it writes that bot's `config.yaml` / `.env`.
/// - `list` → `{servers: [{name, transport, url, command, args, env (key names), auth, oauth_tokens_present, enabled}]}`.
/// - `add {name, config: {url} | {command, args, env}}`; `set_api_key {name, env_var?, value}` stores the secret in
///   the profile's `.env` and only a `${ENV}` reference in `config.yaml` (Bearer header for URL servers);
///   `test {name}` connects and lists tools.
/// - OAuth (URL servers): `oauth.start` → `{session_id, auth_url}` with the backend's own loopback callback
///   (`http://127.0.0.1:<port>/callback`); the app opens `auth_url` in the browser and polls `oauth.poll` every
///   second until `approved` / `error` (6 minutes at most, 3 poll failures in a row end it); an abandoned flow is
///   cancelled with `oauth.cancel`.
/// Secrets never reach a log: `GatewayClient` omits these methods' params from its wire tap.
public struct MCPServers: Sendable {
    public typealias Call = BotMetaSync.Call
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    let call: Call

    public init(call: @escaping Call) { self.call = call }

    public static let testTimeout: TimeInterval = 120
    public static let oauthTimeout: TimeInterval = 360
    public static let pollInterval: TimeInterval = 1
    public static let maxPollFailures = 3

    public struct Failure: Error, RedactionSafeError, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// An older gateway without `mcp.servers.*` (Desktop's `unknown method` feature-detect).
    public static func isUnsupported(_ error: Error) -> Bool {
        guard let e = error as? GatewayClient.RPCError else { return false }
        return e.code == -32601 || e.message.range(of: "unknown method", options: .caseInsensitive) != nil
    }

    // MARK: list

    public struct Server: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let transport: String
        public let url: String?
        public let command: String?
        public let args: [String]
        public let env: [String]
        public let auth: String?
        public let oauthTokensPresent: Bool?
        public let enabled: Bool

        public init(name: String, transport: String = "stdio", url: String? = nil, command: String? = nil, args: [String] = [],
                    env: [String] = [], auth: String? = nil, oauthTokensPresent: Bool? = nil, enabled: Bool = true) {
            self.name = name; self.transport = transport; self.url = url; self.command = command; self.args = args
            self.env = env; self.auth = auth; self.oauthTokensPresent = oauthTokensPresent; self.enabled = enabled
        }

        init?(_ v: JSONValue) {
            guard let name = v["name"]?.string, !name.isEmpty else { return nil }
            self.init(name: name, transport: v["transport"]?.string ?? "stdio", url: v["url"]?.string, command: v["command"]?.string,
                      args: (v["args"]?.array ?? []).compactMap(\.string), env: (v["env"]?.array ?? []).compactMap(\.string),
                      auth: v["auth"]?.string, oauthTokensPresent: v["oauth_tokens_present"]?.bool,
                      enabled: v["enabled"]?.bool ?? true)
        }

        public var isURL: Bool { url?.isEmpty == false || transport == "http" }
        /// OAuth sign-in applies to URL servers that do not authenticate with a header (`oauth.start` refuses those).
        public var canSignIn: Bool { isURL && auth != "header" }
    }

    public func list(profile: String) async throws -> [Server] {
        let r = try await call("mcp.servers.list", ["profile": .string(profile)])
        return (r["servers"]?.array ?? []).compactMap(Server.init)
    }

    // MARK: add

    public enum Transport: Sendable, Equatable {
        case command(String, args: [String], env: [String: String])
        case url(String)
    }

    public struct NewServer: Sendable, Equatable {
        public let name: String
        public let transport: Transport

        public init(name: String, transport: Transport) { self.name = name; self.transport = transport }

        public var params: JSONValue {
            let config: JSONValue
            switch transport {
            case .url(let url): config = ["url": .string(url)]
            case .command(let command, let args, let env):
                var c: [String: JSONValue] = ["command": .string(command), "args": .array(args.map { .string($0) })]
                if !env.isEmpty { c["env"] = .object(env.mapValues { .string($0) }) }
                config = .object(c)
            }
            return ["name": .string(name), "config": config]
        }
    }

    /// A server name the app accepts (it becomes a `config.yaml` key and an env-var stem).
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// The Add form, checked: a name, then either an http(s) URL or a command with arguments (shell-style quotes)
    /// and `KEY=VALUE` lines.
    public static func newServer(name: String, url: String?, command: String, arguments: String, environment: String) throws -> NewServer {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(n) else { throw Failure("Use letters, digits, '.', '-' or '_' for the name (64 at most).") }
        if let url {
            let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: u), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host?.isEmpty == false
            else { throw Failure("Enter an http:// or https:// URL.") }
            return NewServer(name: n, transport: .url(u))
        }
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { throw Failure("Enter the command that starts the server.") }
        return NewServer(name: n, transport: .command(c, args: try self.arguments(arguments), env: try self.environment(environment)))
    }

    /// Splits an argument line on spaces, keeping "double" or 'single' quoted parts together.
    public static func arguments(_ text: String) throws -> [String] {
        var out: [String] = [], current = "", quote: Character?, started = false
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; started = true
            } else if c.isWhitespace {
                if started { out.append(current); current = ""; started = false }
            } else {
                current.append(c); started = true
            }
        }
        guard quote == nil else { throw Failure("An argument has an unclosed quote.") }
        if started { out.append(current) }
        return out
    }

    /// `KEY=VALUE` per line (blank lines ignored).
    public static func environment(_ text: String) throws -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "="),
                  String(line[..<eq]).range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            else { throw Failure("Write environment variables as KEY=VALUE, one per line.") }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env
    }

    public func add(profile: String, _ server: NewServer) async throws {
        var p = server.params.object ?? [:]
        p["profile"] = .string(profile)
        _ = try await call("mcp.servers.add", .object(p))
    }

    // MARK: API key

    public static func apiKeyParams(profile: String, name: String, envVar: String?, value: String) -> JSONValue {
        var p: [String: JSONValue] = ["profile": .string(profile), "name": .string(name), "value": .string(value)]
        if let envVar, !envVar.trimmingCharacters(in: .whitespaces).isEmpty {
            p["env_var"] = .string(envVar.trimmingCharacters(in: .whitespaces))
        }
        return .object(p)
    }

    /// Stores `value` for server `name`; returns the env var it went to.
    @discardableResult
    public func setAPIKey(profile: String, name: String, envVar: String?, value: String) async throws -> String {
        let r = try await call("mcp.servers.set_api_key", Self.apiKeyParams(profile: profile, name: name, envVar: envVar, value: value))
        return r["env_var"]?.string ?? ""
    }

    // MARK: test

    public struct TestResult: Sendable, Equatable {
        public let ok: Bool
        public let error: String?
        public let tools: Int
        public let oauthNeeded: Bool

        public init(ok: Bool, error: String? = nil, tools: Int = 0, oauthNeeded: Bool = false) {
            self.ok = ok; self.error = error; self.tools = tools; self.oauthNeeded = oauthNeeded
        }

        /// Some gateway builds wrap the body in a second `result` (Desktop unwraps it too).
        public init(_ r: JSONValue) {
            let body = r["ok"] == nil && r["result"]?.object != nil ? r["result"]! : r
            let why = body["error"]?.string.map { Redaction.scrub(String($0.prefix(300))) }
            self.init(ok: body["ok"]?.bool == true, error: why, tools: body["tools"]?.array?.count ?? 0,
                      oauthNeeded: body["oauth_needed"]?.bool ?? false)
        }
    }

    public func test(profile: String, name: String) async throws -> TestResult {
        TestResult(try await call("mcp.servers.test", ["profile": .string(profile), "name": .string(name)]))
    }

    // MARK: OAuth

    /// The backend-hosted loopback the browser comes back to: `http://127.0.0.1:<port>/callback`, nothing else
    /// (Desktop's check when it has no callback bridge of its own). The authorization URL itself must be http(s).
    public static func checkAuthURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw Failure("The OAuth server did not provide an authorization URL.") }
        let redirect = parts.queryItems?.first { $0.name == "redirect_uri" }?.value.flatMap(URLComponents.init(string:))
        guard let r = redirect, r.scheme == "http", r.host == "127.0.0.1", let port = r.port, port > 0,
              r.path == "/callback", r.user == nil, r.password == nil, r.query == nil, r.fragment == nil
        else { throw Failure("The OAuth server did not provide a local loopback callback URL.") }
        return url
    }

    public struct Cancelled: Error, RedactionSafeError, Equatable {
        public var description: String { "Sign-in cancelled." }
        public init() {}
    }

    /// Runs one sign-in: start, open the browser (`open` returns false when it could not), poll until approved.
    /// Returns the number of tools the server reported. `cancelled` is checked between steps.
    @discardableResult
    public func signIn(profile: String, name: String, open: @Sendable (URL) async -> Bool,
                       sleep: Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                       cancelled: @Sendable () -> Bool = { false },
                       timeout: TimeInterval = oauthTimeout, now: @Sendable () -> Date = Date.init) async throws -> Int {
        let deadline = now().addingTimeInterval(timeout)
        let scope: [String: JSONValue] = ["profile": .string(profile), "name": .string(name)]
        func request(_ action: String, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
            let r = try await call("mcp.servers.oauth.\(action)", .object(scope.merging(extra) { $1 }))
            guard r["ok"]?.bool != false else {
                throw Failure(Redaction.scrub(r["error_message"]?.string ?? "MCP OAuth request failed"))
            }
            return r
        }
        var session: String?
        do {
            if cancelled() { throw Cancelled() }
            let started = try await request("start")
            session = started["session_id"]?.string
            guard let id = session, !id.isEmpty, let auth = started["auth_url"]?.string, !auth.isEmpty else {
                throw Failure("The OAuth server did not provide an authorization URL and session.")
            }
            let url = try Self.checkAuthURL(auth)
            if cancelled() { throw Cancelled() }
            guard await open(url) else { throw Failure("Could not open the sign-in page in your browser.") }
            var failures = 0
            while true {
                if cancelled() { throw Cancelled() }
                if now() >= deadline { throw Failure("Timed out waiting for the sign-in to finish.") }
                let current: JSONValue
                do {
                    current = try await request("poll", ["session_id": .string(id)])
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= Self.maxPollFailures { throw error }
                    try await sleep(Self.pollInterval)
                    continue
                }
                switch current["status"]?.string {
                case "approved"?: return current["tools"]?.array?.count ?? 0
                case "error"?: throw Failure(Redaction.scrub(current["error_message"]?.string ?? "OAuth authorization failed"))
                default: try await sleep(Self.pollInterval)
                }
            }
        } catch {
            if let id = session, !id.isEmpty { _ = try? await request("cancel", ["session_id": .string(id)]) }
            throw error
        }
    }
}
