import Foundation
import XCTest
@testable import HermesBotApp

private actor ControlledMessageParser {
    private var starts: [MessageRenderRequest] = []
    private var waiting: [String: CheckedContinuation<PreparedMessageContent, Never>] = [:]

    func parse(_ request: MessageRenderRequest) async -> PreparedMessageContent {
        starts.append(request)
        return await withCheckedContinuation { waiting[request.text] = $0 }
    }

    func started() -> [MessageRenderRequest] { starts }

    func complete(_ text: String) {
        waiting.removeValue(forKey: text)?.resume(returning:
            PreparedMessageContent(blocks: [.paragraph(AttributedString(text))], media: []))
    }
}

/// Models a synchronous Foundation parse blocked inside the detached CPU operation. The timeout is a
/// test cleanup guard, not the mechanism releasing a healthy test; the actor must stay responsive now.
private final class BlockingSharedMessageParser: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts: [String] = []
    private var timedOut = false

    func parse(_ request: MessageRenderRequest) -> PreparedMessageContent {
        XCTAssertFalse(Thread.isMainThread)
        lock.withLock { starts.append(request.text) }
        if request.text == "hold", gate.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { timedOut = true }
        }
        return PreparedMessageContent(blocks: [.paragraph(AttributedString(request.text))], media: [])
    }

    func release() { gate.signal() }
    func started() -> [String] { lock.withLock { starts } }
    func didTimeOut() -> Bool { lock.withLock { timedOut } }
}

@MainActor
final class MessageRenderStateTests: XCTestCase {
    private func request(_ text: String, id: String = "row", streaming: Bool = true) -> MessageRenderRequest {
        MessageRenderRequest(text: text, identity: id, streaming: streaming)
    }

    private func waitForStarts(_ count: Int, parser: ControlledMessageParser,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await parser.started().count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("parser did not start \(count) requests", file: file, line: line)
    }

    private func waitForRendered(_ text: String, state: MessageRenderState,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if state.rendered?.request.text == text { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("latest render was not published", file: file, line: line)
    }

    private func waitForScheduler(_ worker: MarkdownRenderWorker,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: (MarkdownRenderWorker.Snapshot) -> Bool) async throws {
        for _ in 0..<200 {
            if condition(await worker.snapshot()) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("scheduler condition was not reached", file: file, line: line)
    }

    private func assertCancelled(_ task: Task<PreparedMessageContent, any Error>,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("cancelled request returned a render", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)", file: file, line: line)
        }
    }

    func testSharedSchedulerBoundsCountAndBytesAndCancelsWhileSynchronousParseIsBlocked() async throws {
        let parser = BlockingSharedMessageParser()
        defer { parser.release() }
        let worker = MarkdownRenderWorker(maxPendingCount: 2, maxPendingBytes: 16, parser: { parser.parse($0) })
        let active = Task { try await worker.prepare(request("hold")) }
        try await waitForScheduler(worker) { $0.activeCount == 1 }
        let first = Task { try await worker.prepare(request("12345678")) }
        let second = Task { try await worker.prepare(request("abcdefgh")) }
        try await waitForScheduler(worker) { $0.pendingCount == 2 && $0.pendingBytes == 16 }
        do {
            _ = try await worker.prepare(request("x"))
            XCTFail("count bound must reject admission")
        } catch { XCTAssertTrue(error is MessageRenderAdmissionError) }
        first.cancel()
        await assertCancelled(first)
        try await waitForScheduler(worker) { $0.pendingCount == 1 && $0.pendingBytes == 8 }
        do {
            _ = try await worker.prepare(request("sixteen bytes!!!"))
            XCTFail("byte bound must reject admission even when a queue slot is free")
        } catch { XCTAssertTrue(error is MessageRenderAdmissionError) }
        for i in 0..<50 {
            let transient = Task { try await worker.prepare(request(String(format: "%08d", i))) }
            try await waitForScheduler(worker) { $0.pendingCount == 2 && $0.pendingBytes == 16 }
            transient.cancel()
            await assertCancelled(transient)
            try await waitForScheduler(worker) { $0.pendingCount == 1 && $0.pendingBytes == 8 }
        }
        active.cancel()
        await assertCancelled(active)
        let blocked = await worker.snapshot()
        XCTAssertEqual(blocked.activeCount, 1, "cancel does not start another parser before synchronous CPU work returns")
        XCTAssertEqual(blocked.pendingCount, 1)
        XCTAssertEqual(parser.started(), ["hold"], "queued cancelled rows never run the parser")
        parser.release()
        let rendered = try await second.value
        XCTAssertEqual(rendered.blocks.map(\.plainText).joined(), "abcdefgh")
        try await waitForScheduler(worker) { $0.activeCount == 0 && $0.pendingCount == 0 && $0.pendingBytes == 0 }
        XCTAssertFalse(parser.didTimeOut(), "actor cancellation/admission must be responsive during the stalled CPU parse")
    }

    func testSharedSchedulerReplacesPendingRequestForSameClient() async throws {
        let parser = BlockingSharedMessageParser()
        defer { parser.release() }
        let worker = MarkdownRenderWorker(maxPendingCount: 2, maxPendingBytes: 32, parser: { parser.parse($0) })
        let active = Task { try await worker.prepare(request("hold")) }
        try await waitForScheduler(worker) { $0.activeCount == 1 }
        let client = UUID()
        let old = Task { try await worker.prepare(request("old"), client: client) }
        try await waitForScheduler(worker) { $0.pendingCount == 1 && $0.pendingBytes == 3 }
        let latest = Task { try await worker.prepare(request("latest text"), client: client) }
        await assertCancelled(old)
        try await waitForScheduler(worker) { $0.pendingCount == 1 && $0.pendingBytes == 11 }
        parser.release()
        _ = try await active.value
        let rendered = try await latest.value
        XCTAssertEqual(rendered.blocks.map(\.plainText).joined(), "latest text")
        XCTAssertEqual(parser.started(), ["hold", "latest text"])
        XCTAssertFalse(parser.didTimeOut())
    }

    func testAdmissionFailureRetriesLatestVisibleTextAndEventuallyRenders() async throws {
        let parser = BlockingSharedMessageParser()
        defer { parser.release() }
        let worker = MarkdownRenderWorker(maxPendingCount: 0, maxPendingBytes: 0, parser: { parser.parse($0) })
        let active = Task { try await worker.prepare(request("hold")) }
        try await waitForScheduler(worker) { $0.activeCount == 1 }
        let state = MessageRenderState(worker: worker)
        state.request(request("first waiting value"))
        try await waitForScheduler(worker) { $0.rejectedCount > 0 }
        state.request(request("latest complete value", streaming: false))
        XCTAssertNil(state.rendered)
        let congested = await worker.snapshot()
        XCTAssertEqual(congested.pendingCount, 0)
        XCTAssertEqual(congested.pendingBytes, 0)
        parser.release()
        _ = try await active.value
        try await waitForRendered("latest complete value", state: state)
        XCTAssertEqual(state.rendered?.request.streaming, false)
        XCTAssertEqual(parser.started(), ["hold", "latest complete value"])
        XCTAssertFalse(parser.didTimeOut())
        state.cancel()
    }

    func testSlowParserCoalescesIntermediateRevisionsAndFlushesLatestFinalText() async throws {
        let parser = ControlledMessageParser()
        let state = MessageRenderState(parser: { await parser.parse($0) })
        state.request(request("first"))
        try await waitForStarts(1, parser: parser)
        for i in 1...100 { state.request(request("revision \(i)")) }
        let initialStarts = await parser.started()
        XCTAssertEqual(initialStarts.map(\.text), ["first"], "one parse in flight, only latest pending retained")
        await parser.complete("first")
        try await waitForStarts(2, parser: parser)
        XCTAssertEqual(state.rendered?.request.text, "first", "keep useful rich content while the latest parse runs")
        state.request(request("complete final text", streaming: false))
        await parser.complete("revision 100")
        try await waitForStarts(3, parser: parser)
        await parser.complete("complete final text")
        try await waitForRendered("complete final text", state: state)
        let starts = await parser.started()
        XCTAssertEqual(starts.map(\.text), ["first", "revision 100", "complete final text"])
        XCTAssertEqual(state.rendered?.content.blocks.map(\.plainText).joined(), "complete final text")
        XCTAssertEqual(state.rendered?.request.streaming, false)
        state.cancel()
    }

    func testReusedRowRejectsAnOldIdentityEvenWhenCancelledParserReturnsLate() async throws {
        let parser = ControlledMessageParser()
        let state = MessageRenderState(parser: { await parser.parse($0) })
        state.request(request("old content", id: "old"))
        try await waitForStarts(1, parser: parser)
        state.request(request("new content", id: "new"))
        try await waitForStarts(2, parser: parser)
        await parser.complete("old content")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(state.rendered, "old content must never attach to a different semantic row")
        await parser.complete("new content")
        try await waitForRendered("new content", state: state)
        XCTAssertEqual(state.rendered?.request.identity, "new")
        state.cancel()
    }

    func testDisappearanceCancelsPendingWorkAndReappearanceCanRenderAgain() async throws {
        let parser = ControlledMessageParser()
        let state = MessageRenderState(parser: { await parser.parse($0) })
        state.request(request("in flight"))
        try await waitForStarts(1, parser: parser)
        state.request(request("obsolete pending"))
        state.cancel()
        await parser.complete("in flight")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(state.rendered)
        let starts = await parser.started()
        XCTAssertEqual(starts.map(\.text), ["in flight"])
        state.request(request("visible again", streaming: false))
        try await waitForStarts(2, parser: parser)
        await parser.complete("visible again")
        try await waitForRendered("visible again", state: state)
        state.cancel()
    }

    func testParserRunsOffMainAndPreservesLongMarkdownAndMedia() async throws {
        let text = "# Long reply \(UUID().uuidString)\n\n"
            + String(repeating: "A **formatted** paragraph with [docs](https://example.com).\n\n", count: 100)
            + "| Name | Value |\n| - | - |\n| alpha | beta |\n\nMEDIA:/tmp/example.csv"
        let state = MessageRenderState(parser: { request in
            XCTAssertFalse(Thread.isMainThread, "the CPU parse must not inherit the UI actor")
            return try await MarkdownRenderWorker.shared.prepare(request)
        })
        state.request(request(text, streaming: false))
        try await waitForRendered(text, state: state)
        let expected = MessageBody.content(text)
        XCTAssertEqual(state.rendered?.content.blocks, expected.blocks)
        XCTAssertEqual(state.rendered?.content.media, expected.media)
        XCTAssertFalse(expected.media.isEmpty)
        XCTAssertTrue(expected.blocks.contains { if case .table = $0 { return true }; return false })
        state.cancel()
    }
}
