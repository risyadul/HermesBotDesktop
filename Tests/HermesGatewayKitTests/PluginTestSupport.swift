import Foundation
@testable import HermesGatewayKit

/// In-process HTTP stand-in for plugin REST tests: a `URLProtocol` whose answers are registered per port, so
/// each test owns a fake "server" (`127.0.0.1:<port>`) and nothing touches the network or the user's backend.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var json: String = "{}"
        /// Answer with a 302 to this URL instead.
        var redirectTo: URL?
    }

    /// One request as the stub saw it (body read from the stream URLSession hands protocols).
    struct Seen: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: JSONValue?
    }

    typealias Handler = @Sendable (Seen) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [Int: Handler] = [:]
    nonisolated(unsafe) private static var seen: [Int: [Seen]] = [:]
    nonisolated(unsafe) private static var nextPort = 41_000

    /// Registers a fake server and returns its port.
    static func serve(_ handler: @escaping Handler) -> Int {
        lock.withLock {
            nextPort += 1
            handlers[nextPort] = handler
            return nextPort
        }
    }

    static func requests(port: Int) -> [Seen] { lock.withLock { seen[port] ?? [] } }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let port = url.port ?? 80
        var body: JSONValue?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            body = try? JSONDecoder().decode(JSONValue.self, from: data)
        } else if let data = request.httpBody {
            body = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        let s = Seen(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[port, default: []].append(s)
            return Self.handlers[port]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(s)
        if let target = reply.redirectTo {
            let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: resp)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum PluginStub {
    static let token = "hbaPluginSecret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    static func access(port: Int, host: String = "127.0.0.1") -> SessionRESTAccess {
        SessionRESTAccess(base: URL(string: "http://\(host):\(port)")!, token: token)
    }

    static func rest(port: Int, plugin: String, host: String = "127.0.0.1") -> PluginREST {
        PluginREST(access: access(port: port, host: host), plugin: plugin, timeout: 5,
                   makeConfiguration: { StubURLProtocol.configuration() })
    }

    /// A fake server answering by `"<METHOD> <path>"` (path without query); unknown routes 404 "Not Found".
    static func routes(_ table: [String: StubURLProtocol.Reply]) -> Int {
        StubURLProtocol.serve { seen in
            table["\(seen.method) \(seen.url.path)"] ?? .init(status: 404, json: #"{"detail":"Not Found"}"#)
        }
    }

    static func query(_ seen: StubURLProtocol.Seen) -> [String: String] {
        let items = URLComponents(url: seen.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}
