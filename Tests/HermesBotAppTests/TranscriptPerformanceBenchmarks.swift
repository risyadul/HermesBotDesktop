import Combine
import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// Opt-in Release benchmarks of synchronous model work, not keyboard-to-paint latency or FPS.
///
/// CI=false HERMES_TRANSCRIPT_BENCHMARKS=1 HERMES_PERF_LABEL=current \
///   swift test -c release --jobs 2 --filter TranscriptPerformanceBenchmarks
///
/// The same file is copied to the frozen baseline. Fixtures, persistence and setup are outside samples.
/// No model is connected to Hermes. A distinct UserDefaults suite contains the real draft-store workload.
@MainActor
final class TranscriptPerformanceBenchmarks: XCTestCase {
    private let sizes = [1_000, 10_000]
    private var checksum = 0

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_TRANSCRIPT_BENCHMARKS"] == "1" else {
            throw XCTSkip("opt-in model benchmark: HERMES_TRANSCRIPT_BENCHMARKS=1 swift test -c release --filter TranscriptPerformanceBenchmarks")
        }
        #if DEBUG
        XCTFail("Performance comparisons require a Release build: swift test -c release")
        throw BenchmarkFailure.releaseRequired
        #endif
    }

    private enum BenchmarkFailure: Error { case releaseRequired, roomDidNotLoad }
    private final class Publications { var count = 0 }

    private var sampleCount: Int {
        let value = ProcessInfo.processInfo.environment["HERMES_PERF_SAMPLES"].flatMap(Int.init) ?? 31
        return max(5, min(101, value))
    }

    private struct Result: Encodable {
        let label: String
        let operation: String
        let historyCount: Int
        let samples: Int
        let warmups: Int
        let measurement: String
        let p50MS: Double
        let p95MS: Double
        let maxMS: Double
        let totalMS: Double
        let modelPublications: Int?
        let derivedReplays: Int?
    }

    private func measure(_ operation: String, historyCount: Int, samples: Int? = nil, warmups: Int = 3,
                         publications: Publications? = nil, replayCount: (() -> Int)? = nil,
                         work: () -> Int) throws {
        for _ in 0..<warmups { checksum &+= work() }
        let initialPublications = publications?.count
        let initialReplays = replayCount?()
        var elapsed: [Double] = []
        for _ in 0..<(samples ?? sampleCount) {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = work()
            let end = DispatchTime.now().uptimeNanoseconds
            checksum &+= value
            elapsed.append(Double(end - start) / 1_000_000)
        }
        let sorted = elapsed.sorted()
        let result = Result(label: ProcessInfo.processInfo.environment["HERMES_PERF_LABEL"] ?? "unlabelled",
                            operation: operation, historyCount: historyCount, samples: sorted.count,
                            warmups: warmups, measurement: "synchronous-main-actor-model-elapsed-ms; NOT event-to-paint",
                            p50MS: sorted[(sorted.count - 1) / 2],
                            p95MS: sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
                            maxMS: sorted.last!, totalMS: elapsed.reduce(0, +),
                            modelPublications: initialPublications.map { publications!.count - $0 },
                            derivedReplays: initialReplays.map { replayCount!() - $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        print("[TRANSCRIPT_PERF] " + String(decoding: data, as: UTF8.self))
        if let path = ProcessInfo.processInfo.environment["HERMES_PERF_REPORT_PATH"] {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data + Data([10]))
        }
    }

    private static let tallMessage = """
    ## Large retained answer

    """ + (0..<80).map { index in
        "### Section \(index)\n\nA retained paragraph with **emphasis**, a [link](https://example.com) and `code`. "
            + String(repeating: "This text deliberately spans many wrapped lines. ", count: 8)
            + "\n\n| Item | Status | Notes |\n| --- | --- | --- |\n| Section \(index) | ready | A wrapped table cell retained in history. |\n"
    }.joined(separator: "\n")

    private static func text(_ index: Int) -> String {
        if index.isMultiple(of: 251) { return "Retained answer \(index)\n" + tallMessage }
        return "History \(index): preserve the reader's current message.\n\n"
            + "| Check | Result |\n| --- | --- |\n| Index \(index) | retained |\n\n```swift\nlet value = \(index)\n```"
    }

    private static func history(_ count: Int) -> [ChatHistoryMessage] {
        (0..<count).map { index in
            switch index % 6 {
            case 0: return ChatHistoryMessage(role: .user, text: "Review retained turn \(index).", rowId: index + 1)
            case 2, 3:
                return ChatHistoryMessage(role: .tool, text: "Inspection complete", toolName: "read_file",
                                          toolContext: "Sources/Retained\(index).swift", rowId: index + 1)
            default:
                return ChatHistoryMessage(role: .assistant, text: text(index),
                                          reasoning: index.isMultiple(of: 19) ? "Compare this result with the retained history." : nil,
                                          rowId: index + 1)
            }
        }
    }

    private func chat(_ count: Int, store: ChatDraftStore? = nil) -> ChatModel {
        let bot = Bot(["name": "benchmark-bot", "display_name": "Benchmark bot"])!
        let model = ChatModel(bot: bot, opener: { _ in FakeChatLink() }, drafts: store)
        model.log = { _ in }
        XCTAssertTrue(model.transcript.seed(history: Self.history(count)))
        _ = model.presentation
        return model
    }

    private func draftStore() -> (UserDefaults, String, ChatDraftStore) {
        let suite = "herald.performance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let text = String(repeating: "Retained safe draft text. ", count: 170)
        var values: [String: [String: Any]] = [:]
        for index in 0..<64 {
            let name = index == 0 ? "benchmark-bot" : "retained-draft-\(index)"
            values[name] = ["text": text, "at": Double(index + 1)]
        }
        defaults.set(values, forKey: ChatDraftStore.key)
        return (defaults, suite, ChatDraftStore(defaults: defaults))
    }

    func testBotDraftSetterWithRealIsolatedPersistence() throws {
        for count in sizes {
            let (defaults, suite, store) = draftStore()
            let model = chat(count, store: store)
            defer { model.close(); defaults.removePersistentDomain(forName: suite) }
            let original = model.presentation
            let publications = Publications()
            let subscription = model.objectWillChange.sink { _ in publications.count += 1 }
            defer { subscription.cancel() }
            let inputs = (0..<(sampleCount + 3)).map { "Typed safe draft " + String(repeating: "a", count: $0 + 1) }
            var index = 0
            try measure("bot-draft-set-persisted-plus-cached-presentation-read", historyCount: count,
                        publications: publications) {
                model.draft = inputs[index]
                index += 1
                return model.presentation.items.count
            }
            XCTAssertTrue(model.presentation === original, "draft edits must not invalidate transcript data")
            XCTAssertEqual(model.draft, inputs.last)
            model.close() // Also measures correctness of a newer coalesced persistence implementation's close flush.
            XCTAssertEqual(store.draft(for: model.bot.name), inputs.last)
        }
        XCTAssertGreaterThan(checksum, 0)
    }

    func testDirectDraftStoreWriteControl() throws {
        let (defaults, suite, store) = draftStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inputs = (0..<(sampleCount + 3)).map { "Control draft " + String(repeating: "b", count: $0 + 1) }
        var index = 0
        try measure("direct-draft-store-save-64-drafts-control", historyCount: 0) {
            store.save(inputs[index], for: "benchmark-bot")
            index += 1
            return inputs[index - 1].count
        }
        XCTAssertEqual(store.draft(for: "benchmark-bot"), inputs.last)
    }

    func testBotMetadataEventAndPresentationRead() throws {
        for count in sizes {
            let model = chat(count)
            defer { model.close() }
            let ids = model.lines.map(\.id)
            var index = 0
            try measure("bot-metadata-event-plus-presentation-read", historyCount: count) {
                index += 1
                model.apply(.info(SessionInfoSnapshot(model: "benchmark-model", provider: "fake",
                                                      usage: ContextUsage(used: index, max: 100_000, percent: 1))))
                return model.presentation.items.count
            }
            XCTAssertEqual(model.lines.map(\.id), ids, "metadata must not alter message content/identity")
        }
    }

    func testBotSequentialStreamingAndPresentationRead() throws {
        for count in sizes {
            let model = chat(count)
            defer { model.close() }
            XCTAssertNotNil(model.transcript.beginTurn("Continue the retained discussion"))
            model.apply(.started)
            _ = model.presentation
            let chunk = String(repeating: "An incremental streamed phrase. ", count: 16)
            try measure("bot-stream-delta-plus-presentation-read", historyCount: count, samples: 64, warmups: 0) {
                model.apply(.delta(chunk))
                return model.presentation.items.count + model.streamingText.utf8.count
            }
            XCTAssertEqual(model.streamingText, String(repeating: chunk, count: 64))
        }
    }

    private static func events(_ count: Int) -> [RoomEvent] {
        (1...count).map { seq in
            let group = (seq - 1) / 5
            switch seq % 5 {
            case 1: return RoomFixtures.user(seq, "Review room turn \(seq)")
            case 4: return RoomFixtures.settled(seq, disc: "user:\(seq - 3)")
            default:
                let thread = group.isMultiple(of: 7) ? RoomThreads.anchored(at: (group % 20) * 5 + 1) : RoomThreads.main
                return RoomFixtures.member(seq, "alpha", text(seq), thread: thread, disc: "user:\(group * 5 + 1)")
            }
        }
    }

    private func loadedRoom(_ count: Int) async throws -> RoomModel {
        let room = RoomFixtures.room("hba-performance-room")
        let api = FakeRoomActions(rooms: [room])
        api.setEvents(room.roomId, Self.events(count))
        let model = RoomModel(room: room, api: api)
        model.start()
        let deadline = Date().addingTimeInterval(30)
        while model.timeline.cursor < count || model.lastSync == nil {
            if Date() > deadline { model.shutdown(); throw BenchmarkFailure.roomDidNotLoad }
            await Task.yield()
        }
        model.stopPolling()
        _ = model.presentation
        XCTAssertEqual(model.timeline.events.count, count)
        return model
    }

    func testRoomDraftSetterAndNotificationDrivenProjectionReplay() async throws {
        for count in sizes {
            let model = try await loadedRoom(count)
            defer { model.shutdown() }
            let publications = Publications()
            let subscription = model.objectWillChange.sink { _ in publications.count += 1 }
            defer { subscription.cancel() }
            let original = model.presentation
            var index = 0
            try measure("room-draft-set-plus-cached-presentation-read", historyCount: count,
                        publications: publications) {
                index += 1
                model.setDraft("Draft \(index)", thread: RoomThreads.main)
                return model.presentation.rows.count
            }
            XCTAssertTrue(model.presentation === original)
            var replays = 0
            // Deliberate, labelled model-only replay of the old parent body's projection recipe, only
            // after a real parent-model publication. This is not SwiftUI's actual body scheduling.
            try measure("room-draft-notification-projection-replay-NOT-SwiftUI-layout", historyCount: count,
                        publications: publications, replayCount: { replays }) {
                let before = publications.count
                index += 1
                model.setDraft("Replay draft \(index)", thread: RoomThreads.main)
                guard publications.count != before else { return model.presentation.rows.count }
                replays += 1
                let states = RoomPresentation.memberStates(room: model.room, timeline: model.timeline, driver: model.driver)
                return model.presentation.rows.count + states.count + model.timeline.threads.count
                    + Int(RoomPollPolicy.interval(driver: model.driver, timeline: model.timeline))
            }
        }
    }

    func testRoomTimelineAppendAndSnapshotConstruction() throws {
        for count in sizes {
            var timeline = RoomTimeline()
            _ = timeline.apply(RoomLogPage(events: Self.events(count), cursor: count, latestSeq: count, hasMore: false))
            let room = RoomFixtures.room("hba-performance-room")
            var presentation = RoomTranscriptPresentation(timeline: timeline, room: room)
            var seq = count
            try measure("room-timeline-append-plus-snapshot-construction", historyCount: count) {
                seq += 1
                let event = RoomFixtures.member(seq, "beta", "A new incremental room reply \(seq)")
                _ = timeline.apply(RoomLogPage(events: [event], cursor: seq, latestSeq: seq, hasMore: false))
                presentation = RoomTranscriptPresentation(timeline: timeline, room: room, previous: presentation)
                return presentation.rows.count
            }
            XCTAssertEqual(presentation.rows.last?.id, seq)
        }
    }
}
