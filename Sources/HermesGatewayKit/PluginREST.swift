import Foundation

/// Client for a dashboard plugin's REST routes, `/api/plugins/<plugin>/<path>`, on the attached backend
/// (same process and port as `/api/ws`).
///
/// Wire facts (hermes-agent `hermes_cli/web_server.py`, `web_server_dashboard.py`; probed read-only):
/// - Auth is the `X-Hermes-Session-Token` header (`_has_valid_session_token`, `web_server.py:458-468`). The
///   token is never put in a URL (`?token=` answers 401 on these routes) and never rendered: every error
///   text is scrubbed with `Redaction.scrub(secrets: [token])`.
/// - A plugin that is missing, disabled or not enabled answers 404 with one of the details in
///   `unavailableDetails`: `"Plugin not found"` (`_plugin_api_runtime_gate`, `web_server.py:651-690`),
///   `"Not Found"` (`_PluginApiHotMount`, `web_server_dashboard.py:943-965`: no router mounted for that
///   name; also an unknown sub-route of a mounted plugin, i.e. an older plugin), or
///   `"plugin '<name>' is not enabled in this profile"` (`_mount_hosted_plugin_api`, `:833-834`). Every
///   other 404 is the route's own answer (a missing task, an unknown board) and stays `.http(404, detail)`.
/// - FastAPI errors carry `{"detail": <string | [{msg, ...}]>}`.
///
/// Rules: loopback base only (the token never leaves the host), redirects refused (the header is never
/// forwarded), ephemeral session, explicit timeout.
public struct PluginREST: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", patch = "PATCH", put = "PUT", delete = "DELETE" }

    public enum Failure: Error, RedactionSafeError, Equatable {
        /// 401/403: the session token was refused.
        case unauthorized(status: Int)
        /// The plugin is not installed, not enabled, or (for a sub-route) too old to have this route.
        case pluginUnavailable(plugin: String)
        /// Any other non-2xx; `detail` is FastAPI's `detail`, scrubbed and capped. 3xx: redirect refused.
        case http(status: Int, detail: String)
        case transport(String)
        case decode(String)
        /// Refused before sending: non-loopback base, bad plugin name or path.
        case refused(String)

        public var description: String {
            switch self {
            case .unauthorized(let s): return "plugin request unauthorized (HTTP \(s))"
            case .pluginUnavailable(let p): return "plugin '\(p)' is not installed or not enabled"
            case .http(let s, let d): return "plugin request failed: HTTP \(s)" + (d.isEmpty ? "" : ": \(d)")
            case .transport(let m): return "plugin request transport error: \(m)"
            case .decode(let m): return "plugin response could not be decoded: \(m)"
            case .refused(let m): return "plugin request refused: \(m)"
            }
        }
    }

    /// 404 details that mean "this plugin's routes are not served" (see the type comment).
    static let unavailableDetails: Set<String> = ["Plugin not found", "Not Found"]
    static let maxDetail = 300

    public let access: SessionRESTAccess
    public let plugin: String
    public var timeout: TimeInterval
    /// Tests inject a configuration with a stub `URLProtocol`; production uses `.ephemeral`.
    let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init(access: SessionRESTAccess, plugin: String, timeout: TimeInterval = 15) {
        self.init(access: access, plugin: plugin, timeout: timeout, makeConfiguration: { .ephemeral })
    }

    init(access: SessionRESTAccess, plugin: String, timeout: TimeInterval = 15,
         makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.access = access; self.plugin = plugin; self.timeout = timeout; self.makeConfiguration = makeConfiguration
    }

    /// One path segment, percent-encoded (ids and slugs from the server or the user).
    public static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
    }

    // MARK: - requests

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await send(.get, path, query: query)
    }

    public func post(_ path: String, query: [URLQueryItem] = [], body: JSONValue? = [:]) async throws -> JSONValue {
        try await send(.post, path, query: query, body: body)
    }

    public func patch(_ path: String, query: [URLQueryItem] = [], body: JSONValue) async throws -> JSONValue {
        try await send(.patch, path, query: query, body: body)
    }

    public func delete(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await send(.delete, path, query: query)
    }

    /// Typed variant: the 2xx body decoded as `T`.
    public func send<T: Decodable>(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
                                   as type: T.Type) async throws -> T {
        let data = try await sendRaw(method, path, query: query, body: body)
        do { return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("null".utf8) : data) } catch {
            throw Failure.decode(Redaction.scrub(Self.decodeReason(error), secrets: [access.token]))
        }
    }

    /// The 2xx body as `JSONValue` (`.null` for an empty body).
    public func send(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let data = try await sendRaw(method, path, query: query, body: body)
        if data.isEmpty { return .null }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw Failure.decode("response is not JSON") }
        return v
    }

    func sendRaw(_ method: Method, _ path: String, query: [URLQueryItem], body: JSONValue?) async throws -> Data {
        let req = try request(method, path, query: query, body: body)
        let session = URLSession(configuration: makeConfiguration(), delegate: HostRendezvous.RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw Failure.transport(Redaction.describe(error, secrets: [access.token]))
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.transport("not an HTTP response") }
        if let failure = Self.failure(status: http.statusCode, body: data, plugin: plugin, secrets: [access.token]) { throw failure }
        return data
    }

    /// The request, or `.refused` (never sent) for a non-loopback base, a bad plugin name or a bad path.
    func request(_ method: Method, _ path: String, query: [URLQueryItem], body: JSONValue?) throws -> URLRequest {
        guard let host = access.base.host, HostRendezvous.isLoopback(host), access.base.scheme == "http" else {
            throw Failure.refused("base \(access.base.scheme ?? "?")://\(access.base.host ?? "?") is not loopback http")
        }
        guard !plugin.isEmpty, plugin.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw Failure.refused("invalid plugin name")
        }
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw Failure.refused("invalid path")
        }
        guard var c = URLComponents(url: access.base, resolvingAgainstBaseURL: false) else { throw Failure.refused("bad base url") }
        c.percentEncodedPath = "/api/plugins/\(plugin)\(path)"
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { throw Failure.refused("bad url") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method.rawValue
        req.setValue(access.token, forHTTPHeaderField: "X-Hermes-Session-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body, method != .get, method != .delete {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.compactJSON(sortedKeys: true).utf8)
        }
        return req
    }

    /// nil for 2xx; otherwise the typed failure.
    static func failure(status: Int, body: Data, plugin: String, secrets: [String]) -> Failure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized(status: status)
        case 300..<400: return .http(status: status, detail: "redirect refused")
        default:
            let detail = Redaction.scrub(Self.detail(body), secrets: secrets)
            if status == 404, unavailableDetails.contains(detail) || detail == "plugin '\(plugin)' is not enabled in this profile" {
                return .pluginUnavailable(plugin: plugin)
            }
            return .http(status: status, detail: String(detail.prefix(maxDetail)))
        }
    }

    /// FastAPI `detail`: a string, or a validation list whose `msg`s are joined; "" when absent.
    static func detail(_ body: Data) -> String {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: body), let d = v["detail"] else { return "" }
        if let s = d.string { return s }
        if let items = d.array {
            return items.map { $0["msg"]?.string ?? $0.compactJSON() }.joined(separator: "; ")
        }
        return d.compactJSON()
    }

    /// Key path + kind only: never the payload values.
    static func decodeReason(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "decode failed" }
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c): return "missing key '\(k.stringValue)' at '\(path(c))'"
        case .typeMismatch(_, let c): return "type mismatch at '\(path(c))'"
        case .valueNotFound(_, let c): return "null value at '\(path(c))'"
        case .dataCorrupted(let c): return "corrupted data at '\(path(c))'"
        @unknown default: return "decode failed"
        }
    }
}

// MARK: - lenient field readers shared by the plugin models

extension JSONValue {
    /// Integer for a JSON number (epoch seconds, counts); nil for null/absent/other types/non-finite.
    var intValue: Int? {
        guard case .number(let n) = self, n.isFinite, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }

    /// Non-empty string, else nil.
    var nonEmptyString: String? { string.flatMap { $0.isEmpty ? nil : $0 } }

    /// nil for JSON `null`. (A `nil` literal inside a `flatMap` closure would become `.null`: `JSONValue`
    /// is `ExpressibleByNilLiteral`.)
    var nonNull: JSONValue? {
        if case .null = self { return nil }
        return self
    }
}

/// A required field was absent or of the wrong type (key name only, never values).
struct MissingField: Error, RedactionSafeError {
    let key: String
    let model: String
    var description: String { "\(model): missing or invalid '\(key)'" }
}
