import SwiftUI
import XCTest
@testable import HermesBotApp

/// B17 dictation: words land at the caret, partial results replace each other, and dictation stops on
/// silence, on the button, on an edit, on a final result; permission and language problems become the
/// banner's errors. A scripted fake stands in for SFSpeechRecognizer and the microphone.
@MainActor
final class DictationTests: XCTestCase {
    final class FakeRecognizer: SpeechRecognizing {
        var denial: DictationError?
        var startError: DictationError?
        var onUpdate: (@MainActor (DictationUpdate) -> Void)?
        var authorizations = 0
        var starts = 0
        var stops = 0

        func authorize() async -> DictationError? { authorizations += 1; return denial }

        func start(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws(DictationError) {
            if let startError { throw startError }
            starts += 1
            self.onUpdate = onUpdate
        }

        func stop() { stops += 1 }
        func send(_ u: DictationUpdate) { onUpdate?(u) }
    }

    /// The composer's text, as a binding.
    final class Draft: @unchecked Sendable {  // main-actor tests only
        var text: String
        init(_ text: String) { self.text = text }
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    private var engine: FakeRecognizer!
    private var dictation: DictationController!

    override func setUp() async throws {
        engine = FakeRecognizer()
        dictation = DictationController(engine: engine)
        dictation.silenceTimeout = 60
        dictation.initialTimeout = 60
    }

    private func listen(_ draft: Draft, caret: NSRange? = nil) async {
        dictation.start(text: draft.binding, caret: caret)
        await eventually { self.dictation.state == .listening }
    }

    // MARK: insertion

    func testWordsGoAtTheCaretWithSpacing() {
        XCTAssertEqual(DictationInsertion(text: "", caret: nil).text(with: "Hello"), "Hello")
        XCTAssertEqual(DictationInsertion(text: "Say", caret: nil).text(with: "hello"), "Say hello", "a space after a word")
        XCTAssertEqual(DictationInsertion(text: "Say ", caret: nil).text(with: "hello"), "Say hello")
        let middle = DictationInsertion(text: "Ask about tomorrow", caret: NSRange(location: 9, length: 0))
        XCTAssertEqual(middle.text(with: "the weather"), "Ask about the weather tomorrow")
        XCTAssertEqual(middle.caret(with: "the weather"), ("Ask about the weather" as NSString).length, "the caret ends after the words")
        let selection = DictationInsertion(text: "Use red here.", caret: NSRange(location: 4, length: 3))
        XCTAssertEqual(selection.text(with: "blue"), "Use blue here.", "dictation replaces the selection")
        XCTAssertEqual(DictationInsertion(text: "Hi.", caret: NSRange(location: 2, length: 0)).text(with: "there"), "Hi there.",
                       "no space before punctuation")
        XCTAssertEqual(DictationInsertion(text: "a", caret: NSRange(location: 99, length: 5)).text(with: "b"), "a b", "a stale caret clamps")
        XCTAssertEqual(DictationInsertion(text: "👍🏽ok", caret: NSRange(location: 1, length: 0)).prefix, "",
                       "a caret inside an emoji moves to its start")
        XCTAssertEqual(DictationInsertion(text: "Hi", caret: nil).text(with: ""), "Hi", "nothing heard leaves the text alone")
    }

    // MARK: controller

    func testPartialResultsStreamIntoTheDraftAndFinalStops() async {
        let draft = Draft("Note: ")
        await listen(draft)
        XCTAssertEqual(engine.authorizations, 1, "permissions are asked on first use")
        engine.send(.partial("buy"))
        XCTAssertEqual(draft.text, "Note: buy")
        engine.send(.partial("buy milk"))
        XCTAssertEqual(draft.text, "Note: buy milk", "each partial replaces the previous one")
        XCTAssertEqual(dictation.caret, ("Note: buy milk" as NSString).length)
        engine.send(.final("Buy milk."))
        XCTAssertEqual(draft.text, "Note: Buy milk.")
        XCTAssertEqual(dictation.state, .idle)
        engine.send(.partial("late"))
        XCTAssertEqual(draft.text, "Note: Buy milk.", "nothing arrives after dictation ends")
    }

    func testTheButtonStopsAndKeepsTheWords() async {
        let draft = Draft("")
        await listen(draft)
        engine.send(.partial("hello"))
        dictation.toggle(text: draft.binding, caret: nil)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(draft.text, "hello")
        engine.send(.partial("hello world"))
        XCTAssertEqual(draft.text, "hello", "a result after Stop (or Send) is dropped")
    }

    func testSendClearingTheDraftEndsDictation() async {
        let draft = Draft("")
        await listen(draft)
        engine.send(.partial("ship it"))
        draft.text = ""  // sent
        engine.send(.partial("ship it now"))
        XCTAssertEqual(draft.text, "", "an edit (or a send) wins over dictation")
        XCTAssertEqual(dictation.state, .idle)
    }

    func testSilenceStopsDictation() async {
        dictation.initialTimeout = 0.05
        dictation.silenceTimeout = 0.05
        let draft = Draft("")
        await listen(draft)
        engine.send(.partial("one"))
        await eventually { self.dictation.state == .idle }
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(draft.text, "one")
    }

    func testNothingHeardEndsQuietly() async {
        let draft = Draft("keep")
        await listen(draft)
        engine.send(.ended)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertNil(dictation.error)
        XCTAssertEqual(draft.text, "keep")
    }

    func testPermissionDeniedExplainsAndLinksToSettings() async {
        engine.denial = .microphoneDenied
        dictation.start(text: Draft("").binding, caret: nil)
        await eventually { self.dictation.error != nil }
        XCTAssertEqual(dictation.error, .microphoneDenied)
        XCTAssertEqual(engine.starts, 0, "nothing listens without permission")
        XCTAssertTrue(dictation.error?.message.contains("Microphone") == true)
        XCTAssertEqual(dictation.error?.settingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(DictationError.speechDenied.settingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        dictation.dismissError()
        XCTAssertEqual(dictation.state, .idle)
    }

    func testAnUnsupportedLanguageIsExplained() async {
        engine.startError = .unsupportedLanguage("Klingon")
        dictation.start(text: Draft("").binding, caret: nil)
        await eventually { self.dictation.error != nil }
        XCTAssertEqual(dictation.error, .unsupportedLanguage("Klingon"))
        XCTAssertTrue(DictationError.unsupportedLanguage("Klingon").message.contains("Klingon"))
        XCTAssertNil(dictation.error?.settingsURL)
    }

    func testARecognizerFailureShowsTheBanner() async {
        await listen(Draft(""))
        engine.send(.failed(.failed("audio route changed")))
        XCTAssertEqual(dictation.error, .failed("audio route changed"))
        XCTAssertEqual(engine.stops, 1)
        // The next click starts again.
        dictation.toggle(text: Draft("").binding, caret: nil)
        await eventually { self.dictation.state == .listening }
        XCTAssertEqual(engine.starts, 2)
    }

    func testStopWhileAskingForPermissionStartsNothing() async {
        dictation.start(text: Draft("").binding, caret: nil)
        dictation.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(engine.starts, 0)
    }

    // MARK: system engine edges (no microphone touched)

    func testOutsideTheAppBundleDictationIsUnavailable() {
        XCTAssertFalse(SystemSpeechRecognizer.bundleDeclaresUsage(nil))
        XCTAssertFalse(SystemSpeechRecognizer.bundleDeclaresUsage(["NSMicrophoneUsageDescription": "x"]))
        XCTAssertTrue(SystemSpeechRecognizer.bundleDeclaresUsage(["NSMicrophoneUsageDescription": "x",
                                                                  "NSSpeechRecognitionUsageDescription": "y"]))
        XCTAssertTrue(DictationError.outsideApp.message.contains("Herald.app"))
    }

    func testRecognizerErrorsMap() {
        XCTAssertEqual(SystemSpeechRecognizer.update(for: NSError(domain: "kAFAssistantErrorDomain", code: 1110)), .ended,
                       "no speech detected is not an error")
        XCTAssertEqual(SystemSpeechRecognizer.update(for: NSError(domain: "kLSRErrorDomain", code: 301)), .ended, "cancelled")
        XCTAssertEqual(SystemSpeechRecognizer.update(for: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])),
                       .failed(.failed("boom")))
    }

    func testMicButtonLabels() {
        XCTAssertEqual(DictationButton.label(false), "Dictate")
        XCTAssertEqual(DictationButton.label(true), "Stop dictation")
    }
}
