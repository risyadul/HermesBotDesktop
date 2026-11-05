import XCTest
@testable import HermesBotApp

/// Try Again after a failed bot-list load was a no-op because the opened
/// connection was kept and `connect()` refused to run while one existed. `ConnectFlow.open` must leave
/// nothing behind on a failed load, so the next attempt opens a fresh connection and can succeed.
@MainActor
final class ConnectRetryTests: XCTestCase {
    @MainActor private final class Connection {
        let id: Int
        var released = false
        init(id: Int) { self.id = id }
    }

    private struct Transient: Error {}

    /// A stand-in for AppModel: holds the connection only after a full success, like `backend`.
    @MainActor private final class Harness {
        var opened: [Connection] = []
        var loads = 0
        var failLoads: Set<Int>
        var held: Connection?
        init(failLoads: Set<Int>) { self.failLoads = failLoads }

        func attempt() async -> Bool {
            guard held == nil else { return false }
            do {
                held = try await ConnectFlow.open(
                    connect: { () async throws -> Connection in
                        let c = Connection(id: self.opened.count + 1)
                        self.opened.append(c)
                        return c
                    },
                    load: { _ in
                        self.loads += 1
                        if self.failLoads.contains(self.loads) { throw Transient() }
                    },
                    release: { c in c.released = true })
                return true
            } catch {
                return false
            }
        }
    }

    func testFirstLoadFailsThenRetrySucceedsOnAFreshConnection() async {
        let h = Harness(failLoads: [1])
        let first = await h.attempt()
        XCTAssertFalse(first)
        XCTAssertNil(h.held, "a failed load must not leave a connection behind")
        XCTAssertEqual(h.opened.count, 1)
        XCTAssertTrue(h.opened[0].released, "the connection opened for the failed load is released")

        let retry = await h.attempt()  // Try Again
        XCTAssertTrue(retry)
        XCTAssertEqual(h.opened.count, 2, "retry opens a new connection instead of being refused")
        XCTAssertEqual(h.loads, 2, "retry loads again")
        XCTAssertEqual(h.held?.id, 2)
        XCTAssertFalse(h.opened[1].released)
    }

    func testOrdinarySuccessReleasesNothing() async {
        let h = Harness(failLoads: [])
        let ok = await h.attempt()
        XCTAssertTrue(ok)
        XCTAssertEqual(h.opened.count, 1)
        XCTAssertEqual(h.loads, 1)
        XCTAssertFalse(h.opened[0].released)
        XCTAssertEqual(h.held?.id, 1)
        let again = await h.attempt()
        XCTAssertFalse(again, "connected: a second connect is a no-op")
        XCTAssertEqual(h.opened.count, 1)
    }

    func testConnectFailureHasNothingToRelease() async {
        var released = 0
        do {
            _ = try await ConnectFlow.open(
                connect: { () async throws -> Connection in throw Transient() },
                load: { _ in XCTFail("no load without a connection") },
                release: { _ in released += 1 })
            XCTFail("connect error must surface")
        } catch {
            XCTAssertTrue(error is Transient)
        }
        XCTAssertEqual(released, 0)
    }

    func testLoadErrorIsTheOneSurfaced() async {
        do {
            _ = try await ConnectFlow.open(connect: { Connection(id: 1) }, load: { _ in throw Transient() }, release: { _ in })
            XCTFail("load error must surface")
        } catch {
            XCTAssertTrue(error is Transient)
        }
    }
}
