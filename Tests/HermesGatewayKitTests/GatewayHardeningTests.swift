import Foundation
import XCTest
@testable import HermesGatewayKit

/// Pre-release hardening of the kit (WP2): required ids, cleanup when `open` fails half-way,
/// `groups.list` paging termination and a terminal client state. In-process fake `/api/ws` only.
final class GatewayHardeningTests: XCTestCase {
    private let secret = "hbaHardenSecret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    // MARK: - BotChatSession.open

    func testSessionCreateWithoutSessionIdThrowsBadFrame() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, _ in method == "session.create" ? ["stored_session_id": "st-1", "info": [:]] : nil }
        let backend = try await connectBackend(gw)
        defer { backend.client.close() }
        do {
            _ = try await BotChatSession.open(backend, bot: try XCTUnwrap(Bot(["name": "fake"])), title: "hba-test")
            XCTFail("open succeeded without a session_id")
        } catch GatewayClient.ClientError.badFrame(let what) {
            XCTAssertEqual(what, "session.create: no session_id")
        }
        XCTAssertEqual(methods(gw), ["session.create"], "nothing is sent for an empty session id")
    }

    func testTitleFailureClosesAndDeletesTheCreatedSession() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, _ in
            method == "session.title" ? ["__error": ["code": 4009, "message": "title rejected"]] : nil
        }
        let backend = try await connectBackend(gw)
        defer { backend.client.close() }
        do {
            _ = try await BotChatSession.open(backend, bot: try XCTUnwrap(Bot(["name": "fake"])), title: "hba-test")
            XCTFail("open succeeded although session.title failed")
        } catch let e as GatewayClient.RPCError {
            XCTAssertEqual(e.code, 4009, "the original error is rethrown")
        }
        XCTAssertEqual(methods(gw), ["session.create", "session.title", "session.close", "session.delete"])
        let frames = gw.received
        XCTAssertEqual(frames.first { $0["method"] == "session.close" }?["params"], ["session_id": "rt-1"])
        XCTAssertEqual(frames.first { $0["method"] == "session.delete" }?["params"], ["session_id": "st-1", "profile": "fake"])
    }

    // MARK: - groups.list paging

    func testAllRoomsStopsWhenNextOffsetDoesNotAdvance() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        // Page 0 is full and points to 2; offset 2 answers an empty page that repeats offset 2 forever.
        gw.responder = { method, params in
            guard method == "groups.list" else { return nil }
            switch params["offset"]?.int ?? -1 {
            case 0: return ["rooms": [["room_id": "hba-a"], ["room_id": "hba-b"]], "next_offset": 2]
            default: return ["rooms": [], "next_offset": 2]
            }
        }
        let backend = try await connectBackend(gw)
        defer { backend.client.close() }
        let rooms = try await GroupsAPI(client: backend.client).allRooms()
        XCTAssertEqual(rooms.map(\.roomId), ["hba-a", "hba-b"])
        XCTAssertEqual(gw.received.compactMap { $0["params"]?["offset"]?.int }, [0, 2])
    }

    func testAllRoomsStopsOnBackwardOffsetAndToleratesMissingRoomsKey() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, _ in method == "groups.list" ? ["next_offset": 0] : nil }
        let backend = try await connectBackend(gw)
        defer { backend.client.close() }
        let rooms = try await GroupsAPI(client: backend.client).allRooms()
        XCTAssertEqual(rooms, [], "a missing `rooms` key decodes as empty (with a schema warning)")
        XCTAssertEqual(methods(gw), ["groups.list"])
    }

    // MARK: - terminal client state

    func testCallsAfterCloseFailFastWithClosed() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let backend = try await connectBackend(gw)
        backend.client.close()
        do { _ = try await backend.client.call("profiles.list", timeout: 5); XCTFail("call succeeded after close") }
        catch GatewayClient.ClientError.closed(let reason) { XCTAssertEqual(reason, "client close") }
        do { _ = try await backend.client.connect(timeout: 5); XCTFail("connect succeeded after close") }
        catch GatewayClient.ClientError.closed {}
        XCTAssertEqual(methods(gw), [])
    }

    func testCallsAfterServerDropFailWithClosedNotTransport() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let backend = try await connectBackend(gw)
        defer { backend.client.close() }
        let reasons = ReasonBox()
        backend.onDisconnect { reasons.add($0) }
        gw.dropAll()
        try await waitUntil { !reasons.all.isEmpty }
        for _ in 0..<2 {
            do { _ = try await backend.client.call("profiles.list", timeout: 5); XCTFail("call succeeded after drop") }
            catch GatewayClient.ClientError.closed(let reason) { XCTAssertFalse(reason.contains(secret), reason) }
        }
        XCTAssertEqual(reasons.all.count, 1, "the disconnect is reported once")
    }

    // MARK: - helpers

    private func connectBackend(_ gw: FakeGateway) async throws -> Backend {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(gw.port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: secret)]
        let client = GatewayClient(url: c.url!)
        let ready = try await client.connect(timeout: 10)
        return Backend(mode: .spawned(pid: 0, port: Int(gw.port)), client: client, ready: ready, verdicts: [], owned: nil)
    }

    private func methods(_ gw: FakeGateway) -> [String] { gw.received.compactMap { $0["method"]?.string } }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met in \(timeout)s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private final class ReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    func add(_ r: String) { lock.withLock { reasons.append(r) } }
    var all: [String] { lock.withLock { reasons } }
}
