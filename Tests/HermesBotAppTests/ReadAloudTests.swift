import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B17 Read Aloud: what is spoken (code blocks, tool and Thought rows skipped), the controller's
/// speak/stop/toggle/Esc rules and the "Read replies aloud automatically" setting. A recording fake stands
/// in for AVSpeechSynthesizer; nothing is spoken.
@MainActor
final class ReadAloudTests: XCTestCase {
    final class RecordingSynthesizer: SpeechSynthesizing {
        var onFinish: ((Int) -> Void)?
        var spoken: [(text: String, token: Int)] = []
        var stops = 0
        func speak(_ text: String, token: Int) { spoken.append((text, token)) }
        func stop() { stops += 1 }
    }

    /// An Esc watcher the test fires by hand.
    @MainActor final class FakeEscape {
        var handler: (@MainActor () -> Void)?
        var installs = 0
        var removes = 0
        var monitor: EscapeMonitor {
            EscapeMonitor { [self] onEscape in
                installs += 1
                handler = onEscape
                return { [self] in removes += 1; handler = nil }
            }
        }
    }

    private var synth: RecordingSynthesizer!
    private var escape: FakeEscape!
    private var speech: ReadAloudController!

    override func setUp() async throws {
        synth = RecordingSynthesizer()
        escape = FakeEscape()
        speech = ReadAloudController(synthesizer: synth, escape: escape.monitor)
    }

    // MARK: spoken text

    func testCodeBlocksAndMediaAreNotRead() {
        let reply = """
            # Result
            Run **this** with [the docs](https://example.com):

            ```swift
            print("hidden")
            ```

            - one
            - two `inline`

            ---
            > quoted
            MEDIA:/tmp/chart.png
            """
        let spoken = SpeechText.speakable(reply)
        XCTAssertFalse(spoken.contains("print"), "fenced code is skipped")
        XCTAssertFalse(spoken.contains("MEDIA"), "attachments are not read")
        XCTAssertFalse(spoken.contains("**") || spoken.contains("#") || spoken.contains("https"), "markup is not read")
        for words in ["Result", "Run this with the docs:", "one", "two inline", "quoted"] {
            XCTAssertTrue(spoken.contains(words), "\(words) in \(spoken)")
        }
        XCTAssertEqual(SpeechText.speakable("```\nls -la\n```"), "", "a code-only reply has nothing to read")
    }

    func testTheTurnIsItsReplyTextsOnly() {
        let lines = [
            ChatLine(role: .user, text: "first"),
            ChatLine(role: .bot, text: "old reply"),
            ChatLine(role: .user, text: "second"),
            ChatLine(role: .thought, text: "thinking"),
            ChatLine(role: .bot, text: "Let me check."),
            ChatLine(role: .tool, text: "terminal"),
            ChatLine(role: .bot, text: "Done."),
        ]
        let turn = SpeechText.turn(containing: lines[6].id, in: lines)
        XCTAssertEqual(turn.map(\.text), ["Let me check.", "Done."], "Thought and tool rows are skipped, the turn is bounded by user lines")
        XCTAssertEqual(SpeechText.spoken(turn), "Let me check.\n\nDone.")
        XCTAssertEqual(SpeechText.turn(containing: lines[1].id, in: lines).map(\.text), ["old reply"])
        XCTAssertEqual(SpeechText.turn(containing: lines[5].id, in: lines), [], "a tool row is not a reply")
        XCTAssertEqual(SpeechText.lastTurn(lines).map(\.text), ["Let me check.", "Done."])
    }

    func testAFailedOrStreamingLastTurnIsNotReadAutomatically() {
        let failed = [ChatLine(role: .user, text: "go"), ChatLine(role: .bot, text: "partial"), ChatLine(role: .error, text: "Stopped.")]
        XCTAssertEqual(SpeechText.lastTurn(failed), [])
        let streaming = [ChatLine(role: .user, text: "go"), ChatLine(role: .bot, text: "writing", streaming: true)]
        XCTAssertEqual(SpeechText.lastTurn(streaming), [])
    }

    func testReadAloudIsOfferedOnFinishedRepliesWithWords() {
        let lines = [ChatLine(role: .user, text: "hi"), ChatLine(role: .bot, text: "Part one."), ChatLine(role: .bot, text: "Part two.")]
        XCTAssertNil(ReadAloudItem.reply(lines[0], lines: { lines }), "not the user's own message")
        XCTAssertNil(ReadAloudItem.reply(ChatLine(role: .bot, text: "…", streaming: true), lines: { lines }), "not while streaming")
        XCTAssertNil(ReadAloudItem.reply(ChatLine(role: .bot, text: "```\nx\n```"), lines: { lines }), "not a code-only reply")
        let item = try? XCTUnwrap(ReadAloudItem.reply(lines[1], lines: { lines }))
        XCTAssertEqual(item?.reply, "Part one.")
        XCTAssertEqual(item?.turn, "Part one.\n\nPart two.", "Shift-click reads the whole turn")
        XCTAssertEqual(item?.hasLongerTurn, true)
    }

    // MARK: controller

    func testSpeakStopAndToggle() {
        let id = UUID()
        speech.speak("Hello there.", id: id)
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(speech.speakingId, id)
        XCTAssertEqual(escape.installs, 1, "Esc is watched while reading")

        speech.toggle("Hello there.", id: id)
        XCTAssertNil(speech.speakingId, "the same reply's button stops it")
        XCTAssertEqual(synth.stops, 1)
        XCTAssertEqual(escape.removes, 1)

        speech.speak("   ", id: id)
        XCTAssertEqual(synth.spoken.count, 1, "blank text reads nothing")
        speech.stop()
        XCTAssertEqual(synth.stops, 1, "stop while silent does nothing")
    }

    func testANewReadReplacesTheCurrentOneAndALateFinishIsIgnored() {
        let a = UUID(), b = UUID()
        speech.speak("First.", id: a)
        let firstToken = synth.spoken[0].token
        speech.speak("Second.", id: b)
        XCTAssertEqual(synth.stops, 1, "the first read is stopped")
        XCTAssertEqual(speech.speakingId, b)
        synth.onFinish?(firstToken)
        XCTAssertEqual(speech.speakingId, b, "the cancelled first utterance's callback does not end the second")
        synth.onFinish?(synth.spoken[1].token)
        XCTAssertNil(speech.speakingId, "the second finishing ends the read")
        XCTAssertEqual(escape.removes, escape.installs, "the Esc watcher goes with it")
    }

    func testEscStopsReading() {
        speech.speak("Long answer.", id: UUID())
        escape.handler?()
        XCTAssertNil(speech.speakingId)
        XCTAssertEqual(synth.stops, 1)
    }

    func testAutoReadIsOffByDefaultAndReadsAFinishedReplyOnceWhenOn() throws {
        let suite = "hba-voice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        speech.autoReadEnabled = { VoiceSection.setting(defaults).wrappedValue }
        let lines = [ChatLine(role: .user, text: "hi"), ChatLine(role: .tool, text: "search"),
                     ChatLine(role: .bot, text: "Found it.\n\n```\ncode\n```")]

        XCTAssertFalse(VoiceSection.setting(defaults).wrappedValue, "off by default")
        speech.turnEvent("message.complete", lines: lines)
        XCTAssertTrue(synth.spoken.isEmpty)

        VoiceSection.setting(defaults).wrappedValue = true
        XCTAssertEqual(defaults.object(forKey: ReadAloudController.autoReadKey) as? Bool, true, "the switch writes the key the controller reads")
        speech.turnEvent("message.delta", lines: lines)
        XCTAssertTrue(synth.spoken.isEmpty, "only a finished reply is read")
        speech.turnEvent("message.complete", lines: lines)
        XCTAssertEqual(synth.spoken.map(\.text), ["Found it."], "code blocks and tool rows are skipped")
        XCTAssertEqual(speech.speakingId, lines[2].id)
        speech.turnEvent("message.complete", lines: lines)
        XCTAssertEqual(synth.spoken.count, 1, "the same reply is not read twice")

        let failed = lines + [ChatLine(role: .user, text: "again"), ChatLine(role: .error, text: "boom")]
        speech.turnEvent("message.complete", lines: failed)
        XCTAssertEqual(synth.spoken.count, 1, "a failed turn is not read")
    }

    func testTheSharedControllerIsSilentUnderTests() {
        speech = ReadAloudController.shared
        speech.speak("Never heard.", id: UUID())
        XCTAssertTrue(speech.isSpeaking)
        speech.stop()
        XCTAssertFalse(speech.isSpeaking)
    }
}
