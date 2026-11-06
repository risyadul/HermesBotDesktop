import Foundation
import XCTest
@testable import HermesGatewayKit

/// Shared helpers for the Desktop-parity suites (server requests, canonical Bot Chat, slash, attachments).
/// Everything runs against the in-process `FakeGateway` on 127.0.0.1.
enum Parity {
    static let secret = "hbaParitySecret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    static func client(_ gw: FakeGateway) -> GatewayClient {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(gw.port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: secret)]
        return GatewayClient(url: c.url!)
    }

    /// A backend over the fake, connected the production way (`Backend.make`: capabilities after ready).
    /// `holdWindow` is short so unclaimed requests are declined quickly; the fake answers in milliseconds.
    static func backend(_ gw: FakeGateway, holdWindow: TimeInterval = 0.5) async throws -> Backend {
        let client = client(gw)
        let ready = try await client.connect(timeout: 10)
        return await Backend.make(mode: .spawned(pid: 0, port: Int(gw.port)), client: client, ready: ready,
                                  verdicts: [], owned: nil, holdWindow: holdWindow)
    }

    static let bot = Bot(["name": "fake", "display_name": "Fake"])!

    static func methods(_ gw: FakeGateway) -> [String] { gw.received.compactMap { $0["method"]?.string } }

    static func waitUntil(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                          _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met in \(timeout)s", file: file, line: line) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The default answers the parity suites need on top of `FakeGateway`'s built-ins.
    static func defaults(_ method: String) -> JSONValue? {
        switch method {
        case "client.capabilities": return ["server_requests": ["approval", "clarify", "sudo", "secret"], "declines_not_shown": true]
        default: return nil
        }
    }
}

/// Thread-safe collector for events, counters and per-call state in responders.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
    /// Appends and returns the new count (a per-method call counter in responders).
    func bump(_ x: T) -> Int { lock.withLock { items.append(x); return items.count } }
}
