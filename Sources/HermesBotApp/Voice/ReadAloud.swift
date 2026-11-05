import AppKit
import Foundation
import HermesGatewayKit

/// B17: the text-to-speech engine Read Aloud drives (`SystemSpeechSynthesizer` in the app, fakes in tests).
/// `speak` replaces whatever is being said; `onFinish` reports the token of an utterance that ended or was
/// stopped, so a late callback for an old utterance cannot end the new one.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var onFinish: ((Int) -> Void)? { get set }
    func speak(_ text: String, token: Int)
    func stop()
}

/// Esc while speaking: a key watcher installed only while something is being read. It never consumes the
/// key, so Esc still closes the find bar or a menu as well. `install` returns the remover.
struct EscapeMonitor {
    let install: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    static var none: EscapeMonitor { EscapeMonitor { _ in {} } }

    /// A local key-down monitor (main thread, this app's windows only).
    static var appKit: EscapeMonitor {
        EscapeMonitor { onEscape in
            let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == escapeKeyCode { MainActor.assumeIsolated { onEscape() } }
                return event
            }
            return { if let token { NSEvent.removeMonitor(token) } }
        }
    }

    static let escapeKeyCode: UInt16 = 53
}

/// B17: Read Aloud for Bot Chat replies, one voice for the whole app (the system default voice).
/// Explicit reads (a reply's Read Aloud button or menu item; Shift-click reads the whole turn) and the
/// automatic read of new replies (Settings › Voice, off by default) both replace what is being said. Esc,
/// sending a message, starting dictation or Stop Reading end it.
@MainActor
final class ReadAloudController: ObservableObject {
    /// `@AppStorage` key of Settings › Voice › "Read replies aloud automatically".
    nonisolated static let autoReadKey = "hba.readRepliesAloud"
    nonisolated static let autoReadByDefault = false

    /// The app's controller; under XCTest a silent synthesizer, so tests never speak.
    static let shared: ReadAloudController = {
        let env = ProcessInfo.processInfo.environment
        let testing = env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        return testing ? ReadAloudController(synthesizer: SilentSynthesizer(), escape: .none)
            : ReadAloudController(synthesizer: SystemSpeechSynthesizer(), escape: .appKit)
    }()

    /// The line whose text is being read (the line clicked, or the last reply of an automatic read).
    @Published private(set) var speakingId: UUID?
    var isSpeaking: Bool { speakingId != nil }
    /// Whether finished replies are read automatically (the Settings switch).
    var autoReadEnabled: () -> Bool = {
        UserDefaults.standard.object(forKey: ReadAloudController.autoReadKey) as? Bool ?? ReadAloudController.autoReadByDefault
    }

    private let synthesizer: any SpeechSynthesizing
    private let escape: EscapeMonitor
    private var removeEscape: (@MainActor () -> Void)?
    private var token = 0
    /// The last reply read automatically: a repeated `message.complete` does not read it twice.
    private var autoReadId: UUID?

    init(synthesizer: any SpeechSynthesizing, escape: EscapeMonitor) {
        self.synthesizer = synthesizer
        self.escape = escape
        synthesizer.onFinish = { [weak self] t in self?.finished(t) }
    }

    /// Reads `text` (already speakable, `SpeechText`) for line `id`, replacing anything being read.
    /// Blank text reads nothing.
    func speak(_ text: String, id: UUID) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        stop()
        token += 1
        speakingId = id
        removeEscape = escape.install { [weak self] in self?.stop() }
        synthesizer.speak(words, token: token)
    }

    /// The Read Aloud button: stops when this line is being read, reads it otherwise.
    func toggle(_ text: String, id: UUID) {
        if speakingId == id { stop() } else { speak(text, id: id) }
    }

    func stop() {
        guard speakingId != nil else { return }
        token += 1  // a late finish of the stopped utterance is stale
        synthesizer.stop()
        ended()
    }

    /// A Bot Chat turn event (`ChatModel.onTurnEvent`): with the setting on, a finished reply is read.
    func turnEvent(_ type: String, lines: [ChatLine]) {
        guard type == "message.complete", autoReadEnabled() else { return }
        let turn = SpeechText.lastTurn(lines)
        guard let last = turn.last, last.id != autoReadId else { return }
        let text = SpeechText.spoken(turn)
        guard !text.isEmpty else { return }
        autoReadId = last.id
        speak(text, id: last.id)
    }

    private func finished(_ t: Int) {
        guard t == token, speakingId != nil else { return }
        ended()
    }

    private func ended() {
        speakingId = nil
        removeEscape?()
        removeEscape = nil
    }
}

/// A synthesizer that says nothing (tests, and the shared controller under XCTest).
@MainActor
final class SilentSynthesizer: SpeechSynthesizing {
    var onFinish: ((Int) -> Void)?
    func speak(_ text: String, token: Int) {}
    func stop() {}
}

/// What a reply's Read Aloud action reads: the reply itself, or with Shift its whole turn.
struct ReadAloudItem {
    let id: UUID
    let text: String
    /// The chat's lines when the action runs (the turn may have grown since the row was drawn).
    let lines: @MainActor () -> [ChatLine]

    /// The reply's own spoken text.
    var reply: String { SpeechText.speakable(text) }

    /// Every reply text of the turn, in order.
    @MainActor var turn: String { SpeechText.spoken(SpeechText.turn(containing: id, in: lines())) }

    /// Whether the turn has more than this one reply text (the "Read Turn Aloud" item).
    @MainActor var hasLongerTurn: Bool { SpeechText.turn(containing: id, in: lines()).count > 1 }

    /// A Read Aloud item for a finished bot reply with something to say; nil otherwise.
    static func reply(_ line: ChatLine, lines: @escaping @MainActor () -> [ChatLine]) -> ReadAloudItem? {
        guard line.role == .bot, !line.streaming, !SpeechText.speakable(line.text).isEmpty else { return nil }
        return ReadAloudItem(id: line.id, text: line.text, lines: lines)
    }
}
