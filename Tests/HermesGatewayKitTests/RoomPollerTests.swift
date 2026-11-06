import Foundation
import XCTest
@testable import HermesGatewayKit

/// `RoomPoller` lifecycle: a stopped/restarted loop must never apply, publish or
/// sleep on a response that arrives late, and only one loop is current. Deterministic: log replies
/// are held until the test releases them.
@MainActor
final class RoomPollerTests: XCTestCase {
    private let room = RoomSummary(["room_id": "hba-x", "name": "Test", "members": []])!

    private func ev(_ seq: Int) -> RoomEvent { RoomEvent(seq: seq, eventId: "e\(seq)", kind: "room.renamed", payload: ["name": "n"]) }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timeout: \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makePoller(_ src: ScriptedRoomSource) -> (RoomPoller, Box) {
        let p = RoomPoller(source: src, roomId: "hba-x")
        p.interval = { _, _ in 60 }  // one sync per loop unless nudged
        let box = Box()
        p.onUpdate = { u in box.cursors.append(u.timeline.cursor) }
        p.onError = { _ in box.errors += 1 }
        return (p, box)
    }

    final class Box { var cursors: [Int] = []; var errors = 0 }

    /// The reviewer's repro: poll 1 (old snapshot, seq 1) is delayed; the view goes away and comes
    /// back; poll 2 (seq 2) lands first; poll 1 then arrives. Before the fix: cursors [2, 1].
    func testLateResponseOfStoppedLoopIsDropped() async throws {
        let src = ScriptedRoomSource(room: room, script: [
            .init(events: [ev(1)], latest: 1, hold: true),
            .init(events: [ev(1), ev(2)], latest: 2),
        ])
        let (p, box) = makePoller(src)
        p.start()
        try await waitUntil("poll 1 sent") { src.logCalls == 1 }
        p.stop()          // onDisappear
        p.start()         // onAppear
        try await waitUntil("poll 2 applied") { box.cursors == [2] }
        src.release(1)
        try await waitUntil("poll 1 dropped") { p.droppedStale == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.cursors, [2], "the late seq-1 snapshot is never published")
        XCTAssertEqual(p.timeline.cursor, 2, "the cursor does not go back")
        XCTAssertEqual(p.timeline.events.map(\.seq), [1, 2])
        XCTAssertEqual(p.appliedCount, 1)
        XCTAssertEqual(src.logCalls, 2, "the stale loop does not poll again or sleep")
        XCTAssertTrue(p.isRunning)
        XCTAssertEqual(p.generation, 3, "start, stop, start")
        p.stop()
    }

    func testNothingIsPublishedAfterStop() async throws {
        let src = ScriptedRoomSource(room: room, script: [.init(events: [ev(1)], latest: 1, hold: true)])
        let (p, box) = makePoller(src)
        p.start()
        try await waitUntil("poll sent") { src.logCalls == 1 }
        p.stop()
        XCTAssertFalse(p.isRunning)
        src.release(1)
        try await waitUntil("dropped") { p.droppedStale == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.cursors, [])
        XCTAssertEqual(p.timeline.cursor, 0)
        XCTAssertEqual(src.logCalls, 1)
    }

    func testErrorOfStoppedLoopIsNotReported() async throws {
        let src = ScriptedRoomSource(room: room, script: [.init(events: [], latest: 0, hold: true, fail: true)])
        let (p, box) = makePoller(src)
        p.start()
        try await waitUntil("poll sent") { src.logCalls == 1 }
        p.stop()
        src.release(1)
        try await waitUntil("dropped") { p.droppedStale == 1 }
        XCTAssertEqual(box.errors, 0)
    }

    func testErrorOfCurrentLoopIsReportedAndLoopGoesOn() async throws {
        let src = ScriptedRoomSource(room: room, script: [.init(events: [], latest: 0, fail: true), .init(events: [ev(1)], latest: 1)])
        let (p, box) = makePoller(src)
        p.start()
        try await waitUntil("error reported") { box.errors == 1 }
        p.nudge()
        try await waitUntil("next sync") { box.cursors == [1] }
        p.stop()
    }

    func testStartIsSingleLoopAndNudgeWakesIt() async throws {
        let src = ScriptedRoomSource(room: room, script: [.init(events: [ev(1)], latest: 1), .init(events: [ev(2)], latest: 2)])
        let (p, box) = makePoller(src)
        p.start(); p.start()
        XCTAssertEqual(p.generation, 1, "a second start while running opens no second loop")
        try await waitUntil("first sync") { box.cursors == [1] }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(src.logCalls, 1, "then it sleeps (interval 60 s)")
        p.nudge()
        try await waitUntil("nudged sync") { box.cursors == [1, 2] }
        XCTAssertEqual(src.logCalls, 2)
        p.stop()
        p.nudge()  // no loop: no-op
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(src.logCalls, 2)
    }

    /// Stop while the loop sleeps: the sleeper ends and nothing else runs.
    func testStopDuringSleepEndsTheLoop() async throws {
        let src = ScriptedRoomSource(room: room, script: [.init(events: [ev(1)], latest: 1)])
        let (p, box) = makePoller(src)
        p.start()
        try await waitUntil("first sync") { box.cursors == [1] }
        p.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(src.logCalls, 1)
        XCTAssertEqual(src.stateCalls, 1)
    }

    // MARK: composer availability

    func testComposerRefusesWhileClosingAndAfterClose() {
        var c = RoomComposer()
        XCTAssertTrue(c.beginClosing())
        XCTAssertFalse(c.beginClosing(), "one disband at a time")
        XCTAssertNil(c.beginSend("hello"), "disband in flight: nothing is posted")
        XCTAssertFalse(c.isOpen)
        XCTAssertFalse(c.sending, "a refused send leaves no in-flight state")
        c.reopen()
        XCTAssertEqual(c.beginSend("hello"), "hello", "a failed disband reopens the room")
        c.finishSend()
        XCTAssertTrue(c.beginClosing())
        c.close()
        XCTAssertNil(c.beginSend("after disband"))
        c.reopen()
        XCTAssertEqual(c.availability, .closed, "closed is final")
        XCTAssertFalse(c.beginClosing())
        XCTAssertFalse(c.canSend)
    }

    func testComposerSendInFlightThenClose() {
        var c = RoomComposer()
        XCTAssertEqual(c.beginSend("one"), "one")
        XCTAssertTrue(c.beginClosing(), "a disband may start while a send is in flight")
        c.finishSend()
        XCTAssertNil(c.beginSend("two"))
        c.close()
        XCTAssertNil(c.beginSend("two"))
    }
}

/// Answers `groups.log` from a script, one reply per call; a reply can be held until `release(n)`.
final class ScriptedRoomSource: RoomSource, @unchecked Sendable {
    struct Reply {
        var events: [RoomEvent]
        var latest: Int
        var hold = false
        var fail = false
    }
    struct Boom: Error {}

    private let lock = NSLock()
    private var script: [Reply]
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var _logCalls = 0, _stateCalls = 0
    private let room: RoomSummary

    init(room: RoomSummary, script: [Reply]) { self.room = room; self.script = script }

    var logCalls: Int { lock.withLock { _logCalls } }
    var stateCalls: Int { lock.withLock { _stateCalls } }

    func release(_ n: Int) {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            if let c = held.removeValue(forKey: n) { return c }
            released.insert(n); return nil
        }
        c?.resume()
    }

    func roomLog(roomId: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPage {
        let (n, reply): (Int, Reply) = lock.withLock {
            _logCalls += 1
            return (_logCalls, script.isEmpty ? Reply(events: [], latest: 0) : script.removeFirst())
        }
        if reply.hold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if released.remove(n) != nil { return true }
                    held[n] = c; return false
                }
                if now { c.resume() }
            }
        }
        if reply.fail { throw Boom() }
        let events = reply.events.filter { $0.seq > sinceSeq }
        return RoomLogPage(events: events, cursor: events.last?.seq ?? sinceSeq, latestSeq: reply.latest, hasMore: false)
    }

    func roomState(roomId: String) async throws -> RoomStateSnapshot {
        lock.withLock { _stateCalls += 1 }
        return RoomStateSnapshot(room: room, driver: RoomDriverStatus(working: false))
    }
}
