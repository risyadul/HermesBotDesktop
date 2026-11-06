import Foundation

/// A stored session's transcript, read without touching it (A17, "Open Recent Session"):
/// `GET /api/sessions/{id}/messages?profile=<p>&inline_images=false` (`web_routers/sessions.py`
/// `get_session_messages`). The route opens the profile's store read-only and returns the latest page (up to
/// 500 messages, compression ancestors included, display projection applied). Unlike `session.resume` it
/// starts no runtime and writes nothing, so a routine run or side thread can be looked at safely.
public enum SessionTranscriptREST {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unavailable
        case notFound
        case http(Int)
        case badResponse

        public var description: String {
            switch self {
            case .unavailable: return "This Hermes does not offer read-only session access."
            case .notFound: return "Hermes no longer has this session."
            case .http(let code): return "Hermes answered HTTP \(code)."
            case .badResponse: return "Hermes sent a transcript this app cannot read."
            }
        }
    }

    /// The request URL, or nil when the id or profile cannot be put in one.
    public static func url(base: URL, sessionId: String, profile: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard !sessionId.isEmpty, !profile.isEmpty,
              let encId = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.percentEncodedPath = "/api/sessions/" + encId + "/messages"
        c.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "inline_images", value: "false")]
        return c.url
    }

    /// Maps the answer: 200 with a `messages` array → its rows as history, 404 → gone, anything else fails.
    /// Stored rows use the DB's keys, so `tool_name` is read as the tool's name and the display projection
    /// (`display_content`, e.g. a steer's own words) wins over the raw content.
    public static func decode(status: Int, body: JSONValue?) throws -> [ChatHistoryMessage] {
        switch status {
        case 200:
            guard let rows = body?["messages"]?.array else { throw Failure.badResponse }
            return ChatHistoryMessage.decode(.array(rows.map(normalized)))
        case 404: throw Failure.notFound
        default: throw Failure.http(status)
        }
    }

    static func normalized(_ row: JSONValue) -> JSONValue {
        guard var o = row.object else { return row }
        if o["name"] == nil, let tool = o["tool_name"], tool.string != nil { o["name"] = tool }
        if let shown = o["display_content"]?.string { o["text"] = .string(shown) }
        return .object(o)
    }

    /// Reads one session's transcript. The token goes only in the `X-Hermes-Session-Token` header.
    public static func messages(_ access: SessionRESTAccess?, sessionId: String, profile: String,
                                timeout: TimeInterval = 15) async throws -> [ChatHistoryMessage] {
        guard let access, let url = url(base: access.base, sessionId: sessionId, profile: profile) else { throw Failure.unavailable }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue(access.token, forHTTPHeaderField: "X-Hermes-Session-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return try decode(status: status, body: try? JSONDecoder().decode(JSONValue.self, from: data))
    }
}
