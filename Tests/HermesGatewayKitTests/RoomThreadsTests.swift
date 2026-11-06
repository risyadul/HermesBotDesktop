import Foundation
import XCTest
@testable import HermesGatewayKit

/// C1.1 rename wire shape and C1.2 threads: thread ids, per-thread lines, thread summaries and the
/// anchored-thread opening message. No live backend.
final class RoomThreadsTests: XCTestCase {
    private let room = RoomSummary([
        "room_id": "hba-x", "name": "Test", "revision": 1, "latest_seq": 0, "created_at": 1, "updated_at": 1,
        "members": [["member_id": "alpha", "profile": "alpha", "handle": "alpha", "display_name": "Alpha"],
                    ["member_id": "beta", "profile": "beta", "handle": "beta"]],
    ])!

    private func user(_ seq: Int, _ text: String = "hi", thread: String? = "main") -> RoomEvent {
        var p: [String: JSONValue] = ["text": .string(text)]
        if let thread { p["thread_id"] = .string(thread) }
        return RoomEvent(seq: seq, eventId: "user:\(seq)", kind: "message.user", actor: ["kind": "user", "id": "desktop"], payload: .object(p))
    }
    private func member(_ seq: Int, _ m: String, _ text: String = "hello", thread: String = "main") -> RoomEvent {
        RoomEvent(seq: seq, eventId: "dmessage:\(seq)", kind: "message.member", actor: ["kind": "member", "id": .string(m)],
                  payload: ["text": .string(text), "member_id": .string(m), "discussion_event_id": "user:1", "thread_id": .string(thread)])
    }
    private func timeline(_ events: [RoomEvent]) -> RoomTimeline {
        var t = RoomTimeline()
        t.apply(RoomLogPage(events: events, cursor: events.last?.seq ?? 0, latestSeq: events.last?.seq ?? 0, hasMore: false))
        return t
    }

    // MARK: thread ids

    func testThreadOfEventDefaultsToMain() {
        XCTAssertEqual(RoomThreads.id(of: user(1)), "main")
        XCTAssertEqual(RoomThreads.id(of: user(1, thread: nil)), "main", "an event without thread_id belongs to main")
        XCTAssertEqual(RoomThreads.id(of: user(1, thread: "t1x-abc")), "t1x-abc")
    }

    func testReplyThreadContinuesOrAnchors() {
        XCTAssertEqual(RoomThreads.replyThread(for: member(7, "alpha")), "hba-t-7", "a main message starts a thread anchored on it")
        XCTAssertEqual(RoomThreads.replyThread(for: member(9, "alpha", thread: "hba-t-7")), "hba-t-7", "a thread message continues it")
        XCTAssertEqual(RoomThreads.replyThread(for: member(9, "alpha", thread: "tdesk-1")), "tdesk-1", "threads of other clients too")
        XCTAssertTrue(RoomMember.isIdentifier(RoomThreads.anchored(at: 123)), "thread_id must pass the server's identifier rule")
    }

    func testAnchorSeqParsesOnlyAppThreads() {
        XCTAssertEqual(RoomThreads.anchorSeq(of: "hba-t-12"), 12)
        XCTAssertNil(RoomThreads.anchorSeq(of: "main"))
        XCTAssertNil(RoomThreads.anchorSeq(of: "t1x-abc"))
        XCTAssertNil(RoomThreads.anchorSeq(of: "hba-t-x"))
        XCTAssertNil(RoomThreads.anchorSeq(of: "hba-t-0"))
    }

    func testOpeningQuotesAnchorOnOneLineAndCuts() {
        XCTAssertEqual(RoomThreads.opening("why?", quoting: "Alpha", "line one\nline two"), "> Alpha: line one line two\n\nwhy?")
        XCTAssertEqual(RoomThreads.opening("why?", quoting: "Alpha", "  \n "), "why?", "nothing to quote: the text alone")
        let long = String(repeating: "x", count: RoomThreads.quoteLimit + 50)
        let q = RoomThreads.opening("ok", quoting: "A", long)
        XCTAssertTrue(q.hasPrefix("> A: " + String(repeating: "x", count: RoomThreads.quoteLimit) + "…\n\n"))
    }

    func testBodyDropsTheOpeningQuote() {
        XCTAssertEqual(RoomThreads.body(of: RoomThreads.opening("why?", quoting: "Alpha", "A\nB")), "why?")
        XCTAssertEqual(RoomThreads.body(of: "plain\n\ntext"), "plain\n\ntext")
        XCTAssertEqual(RoomThreads.body(of: "> quote only"), "> quote only")
    }

    func testThreadTitleIsTheUsersWords() {
        var t = RoomTimeline()
        let first = user(3, RoomThreads.opening("why safer?", quoting: "Alpha", "B is safer"), thread: "hba-t-2")
        t.apply(RoomLogPage(events: [user(1), member(2, "alpha"), first], cursor: 3, latestSeq: 3, hasMore: false))
        XCTAssertEqual(t.threads.first?.title, "why safer?")
    }

    // MARK: timeline

    func testLinesCarryThreadAndFilterByThread() {
        let t = timeline([user(1), member(2, "alpha"), user(3, "follow", thread: "hba-t-2"), member(4, "beta", "re", thread: "hba-t-2")])
        XCTAssertEqual(t.lines(room: room).map(\.threadId), ["main", "main", "hba-t-2", "hba-t-2"])
        XCTAssertEqual(t.lines(thread: "hba-t-2", room: room).map(\.id), [3, 4])
        XCTAssertEqual(t.lines(thread: "main", room: room).map(\.id), [1, 2])
    }

    func testThreadSummaries() {
        let t = timeline([user(1), member(2, "alpha"), user(3, "follow up", thread: "hba-t-2"), member(4, "beta", "re", thread: "hba-t-2"),
                          user(5, "other topic", thread: "tdesk-1"), member(6, "alpha", "ok", thread: "hba-t-2")])
        XCTAssertEqual(t.threads, [
            RoomThreadSummary(id: "hba-t-2", anchorSeq: 2, firstSeq: 3, lastSeq: 6, messageCount: 3, title: "follow up"),
            RoomThreadSummary(id: "tdesk-1", anchorSeq: nil, firstSeq: 5, lastSeq: 5, messageCount: 1, title: "other topic"),
        ])
    }

    func testAnchorOutsideTheLogIsNil() {
        let t = timeline([user(1, "x", thread: "hba-t-99")])
        XCTAssertNil(t.threads.first?.anchorSeq, "the anchor message is not in the log: no anchor to show")
    }

    func testAnchorsAtFirstAndLastEventAndWithinGaps() {
        // Pages may arrive unsorted; the timeline keeps the applied seq order even when it detects gaps.
        let t = timeline([member(90, "alpha", thread: "hba-t-90"),
                          user(1, "first"),
                          user(20, "middle"),
                          user(30, "first anchor", thread: "hba-t-1"),
                          user(40, "middle anchor", thread: "hba-t-20"),
                          user(50, "missing anchor", thread: "hba-t-21"),
                          user(60, "outside", thread: "hba-t-91")])
        XCTAssertTrue(t.gapDetected)
        let summaries = Dictionary(t.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(summaries["hba-t-1"]?.anchorSeq, 1)
        XCTAssertEqual(summaries["hba-t-20"]?.anchorSeq, 20)
        XCTAssertEqual(summaries["hba-t-90"]?.anchorSeq, 90)
        XCTAssertNil(summaries["hba-t-21"]?.anchorSeq)
        XCTAssertNil(summaries["hba-t-91"]?.anchorSeq)
        XCTAssertTrue(RoomTimeline().threads.isEmpty)
    }

    func testPhasesArePerThread() {
        let main = user(1), side = user(2, "q", thread: "hba-t-1")
        let t = timeline([main, side])
        XCTAssertEqual(t.phase(of: main), .pending, "a message in another thread does not supersede main")
        XCTAssertEqual(t.phase(of: side), .pending)
    }

    // MARK: rename

    func testRenamedAndNormalizedName() {
        XCTAssertEqual(room.renamed("New").name, "New")
        XCTAssertEqual(room.renamed("New").roomId, "hba-x")
        XCTAssertEqual(RoomSummary.normalizedName("  Ops  "), "Ops")
        XCTAssertNil(RoomSummary.normalizedName("   "))
        XCTAssertNotNil(RoomSummary.normalizedName(String(repeating: "é", count: 200)), "200 characters is the limit, not bytes")
        XCTAssertNil(RoomSummary.normalizedName(String(repeating: "a", count: 201)))
    }

    func testRenameRequestShapeAndResult() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, params in
            guard method == "groups.rename" else { return nil }
            return ["room": ["room_id": params["room_id"] ?? "", "name": params["name"] ?? "", "revision": 2, "members": [],
                             "event": ["seq": 9, "kind": "room.renamed", "payload": ["name": params["name"] ?? ""]]]]
        }
        let client = try await connect(gw)
        let api = GroupsAPI(client: client)
        let renamed = try await api.renameRoom(roomId: "hba-x", eventId: "hba-rename-1", name: "Ops")
        XCTAssertEqual(renamed.name, "Ops")
        XCTAssertEqual(renamed.revision, 2)
        XCTAssertEqual(gw.received.first { $0["method"] == "groups.rename" }?["params"],
                       ["room_id": "hba-x", "event_id": "hba-rename-1", "name": "Ops"])
        client.close()
    }

    func testRenameErrorSurfacesAsRPCError() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { method, _ in
            method == "groups.rename" ? ["__error": ["code": 4117, "message": "invalid room name"]] : nil
        }
        let client = try await connect(gw)
        do {
            _ = try await GroupsAPI(client: client).renameRoom(roomId: "hba-x", eventId: "hba-rename-1", name: "x")
            XCTFail("expected an error")
        } catch let e as GatewayClient.RPCError {
            XCTAssertEqual(e.code, 4117)
        }
        client.close()
    }

    func testThreadSendShape() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let client = try await connect(gw)
        _ = try? await GroupsAPI(client: client).sendMessage(roomId: "hba-x", eventId: "hba-msg-1", text: "hi", threadId: "hba-t-4")
        XCTAssertEqual(gw.received.first { $0["method"] == "groups.send" }?["params"],
                       ["room_id": "hba-x", "event_id": "hba-msg-1", "payload": ["text": "hi", "thread_id": "hba-t-4"]])
        client.close()
    }

    private func connect(_ gw: FakeGateway) async throws -> GatewayClient {
        var c = URLComponents(); c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(gw.port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: "t")]
        let client = GatewayClient(url: c.url!)
        try await client.connect(timeout: 10)
        return client
    }
}
