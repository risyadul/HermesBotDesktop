import Foundation

/// Read-only access to the attached backend's dashboard REST routes (same process and port as
/// `/api/ws`). The token is the backend's live session token (`web_server.py:386-387`, published 0600
/// to the rendezvous dir, `web_server.py:1361-1368`); it is sent only as the `X-Hermes-Session-Token`
/// header (`_has_valid_session_token`, `web_server.py:458-468`), never in a URL, and never rendered.
public struct SessionRESTAccess: Sendable, CustomStringConvertible {
    public let base: URL
    let token: String

    public init(base: URL, token: String) { self.base = base; self.token = token }

    /// Safe to log: no token.
    public var description: String { "rest=\(base.absoluteString)" }
}

/// Whether one profile's session store holds an exact stored id, read without any listing filter.
public enum StoredIdPresence: Sendable, Equatable, CustomStringConvertible {
    /// The store has a row with exactly this id (`source` as stored; `messages` = the row's
    /// `message_count` when the answer carries it).
    case present(source: String, messages: Int? = nil)
    /// Proven absent (`why`: `not_found`, or `prefix_resolved_other_id`).
    case absent(String)
    /// Could not be proven either way (transport, auth, profile, corrupt store, unexpected payload).
    case unknown(String)

    public var description: String {
        switch self {
        case .present(let s, let m): return "present(source=\(s.isEmpty ? "?" : s)\(m.map { ", messages=\($0)" } ?? ""))"
        case .absent(let w): return "absent(\(w))"
        case .unknown(let w): return "unknown(\(w))"
        }
    }

    public var isPresent: Bool { if case .present = self { return true }; return false }
    public var isUnknown: Bool { if case .unknown = self { return true }; return false }
}

/// `RoomSessionGateway` over an attached backend:
/// - `profiles.list` (every profile of the install: default + named dirs, `hermes_cli/profiles.py:1049-1067`);
/// - `session.list {profile, include_hidden: true, limit: 500}` — a HUMAN listing used only to DISCOVER
///   candidate member rows (bot_room is not a denied listing source). It is NOT an inventory: it drops
///   `kanban`/`tool`/`oneshot` rows even with `include_hidden` (`methods_session.py:133-157,549-571`),
///   archived rows, compression children, and everything past the window
///   (`hermes_state_sessions.py:1348-1373,1421,1461-1462`). Absence there proves nothing;
/// - `GET /api/sessions/{id}?profile=<p>` (`web_routers/sessions.py:562-582`) for the exact-id inventory a
///   close needs: `db.get_session(id)` on that profile's store, no source/hidden/archive/window filter;
/// - `session.active_list`, `session.close {session_id: runtime}`, `session.delete {session_id, profile}`.
public struct AttachedSessionGateway: RoomSessionGateway {
    public let client: GatewayClient
    public let rest: SessionRESTAccess?
    public var httpTimeout: TimeInterval = 10
    public var listLimit = 500

    public init(client: GatewayClient, rest: SessionRESTAccess?) { self.client = client; self.rest = rest }

    public func profileNames() async throws -> [String] {
        let r = try await client.call("profiles.list", ["include_sessions": false])
        return (r["profiles"]?.array ?? []).compactMap { $0["name"]?.string }
    }

    public func storedRows(profile: String) async throws -> [StoredSessionRow] {
        let r = try await client.call("session.list", ["profile": .string(profile), "include_hidden": true, "limit": .number(Double(listLimit))])
        return (r["sessions"]?.array ?? []).compactMap { StoredSessionRow(profile: profile, $0) }
    }

    public func liveRows() async throws -> [LiveSessionRow] {
        (try await client.call("session.active_list", [:])["sessions"]?.array ?? []).compactMap(LiveSessionRow.init)
    }

    public func close(runtimeId: String) async throws -> Bool {
        try await client.call("session.close", ["session_id": .string(runtimeId)])["closed"]?.bool ?? false
    }

    public func delete(profile: String, id: String) async throws {
        _ = try await client.call("session.delete", ["session_id": .string(id), "profile": .string(profile)])
    }

    public func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }

    /// Exact-id lookup in `profile`'s store. Never throws: anything that is not a proven answer is `.unknown`.
    public func storedIdPresence(profile: String, id: String) async -> StoredIdPresence {
        guard let rest else { return .unknown("no REST access to the attached backend") }
        guard !id.isEmpty, !profile.isEmpty else { return .unknown("empty id or profile") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encId = id.addingPercentEncoding(withAllowedCharacters: allowed),
              var c = URLComponents(url: rest.base, resolvingAgainstBaseURL: false) else { return .unknown("bad url") }
        c.percentEncodedPath = "/api/sessions/" + encId
        c.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let url = c.url else { return .unknown("bad url") }
        var req = URLRequest(url: url, timeoutInterval: httpTimeout)
        req.httpMethod = "GET"
        req.setValue(rest.token, forHTTPHeaderField: "X-Hermes-Session-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)
            return Self.presence(status: status, body: body, requestedId: id, profile: profile)
        } catch {
            return .unknown("session detail request failed: \(Redaction.describe(error, secrets: [rest.token]))")
        }
    }

    /// Maps a `GET /api/sessions/{id}?profile=` answer (`web_routers/sessions.py:562-582`):
    /// - 200 + `id == requested`: present. `resolve_session_id` tries the exact id FIRST and only then a
    ///   unique prefix (`hermes_state_sessions.py:900-908`), so 200 with any OTHER id proves the exact id
    ///   is absent (a longer id merely starts with it) — never counted as present;
    /// - 404 `{"detail":"Session not found"}` (`_NOT_FOUND`, `:43`): absent;
    /// - 404 for a missing profile (`Profile '…' does not exist.`, `web_server_cron.py:122-123`), 400, 401,
    ///   503 (corrupt store), anything else, a non-object body, or a profile stamp that is not the
    ///   requested profile: unknown.
    /// Only `id`, `source`, `message_count` and `profile` are read; the payload is not kept.
    static func presence(status: Int, body: JSONValue?, requestedId: String, profile: String) -> StoredIdPresence {
        switch status {
        case 200:
            guard let body, body.object != nil, let got = body["id"]?.string else { return .unknown("HTTP 200 without a session id") }
            if let stamped = body["profile"]?.string, stamped != profile {
                return .unknown("HTTP 200 stamped profile '\(stamped)' ≠ '\(profile)'")
            }
            guard got == requestedId else { return .absent("prefix_resolved_other_id") }
            return .present(source: body["source"]?.string ?? "", messages: body["message_count"]?.int)
        case 404:
            if body?["detail"]?.string == "Session not found" { return .absent("not_found") }
            return .unknown("HTTP 404 \(String((body?["detail"]?.string ?? "").prefix(80)))")
        default:
            return .unknown("HTTP \(status)")
        }
    }
}
