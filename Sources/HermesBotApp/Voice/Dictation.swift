import AppKit
import Foundation
import SwiftUI

/// Why dictation could not start or stopped, in words for the composer's banner.
enum DictationError: Error, Equatable {
    case microphoneDenied
    case speechDenied
    /// Parental controls or a profile block speech recognition or the microphone.
    case restricted
    /// No recognizer for the user's language (the name shown).
    case unsupportedLanguage(String)
    /// The recognizer exists but cannot run now (offline without on-device support, Siri disabled…).
    case recognizerUnavailable
    case noMicrophone
    /// A `swift run` build: macOS only grants the microphone to an app bundle that says why it needs it.
    case outsideApp
    case failed(String)

    var message: String {
        switch self {
        case .microphoneDenied:
            return "Dictation needs the microphone. Allow Hermes Bot in System Settings › Privacy & Security › Microphone."
        case .speechDenied:
            return "Dictation needs speech recognition. Allow Hermes Bot in System Settings › Privacy & Security › Speech Recognition."
        case .restricted:
            return "Speech recognition or the microphone is restricted on this Mac."
        case .unsupportedLanguage(let language):
            return "Dictation is not available for \(language). Pick another language in System Settings › General › Language & Region."
        case .recognizerUnavailable:
            return "Speech recognition is not available right now. Check your connection, or turn on Dictation in System Settings › Keyboard."
        case .noMicrophone:
            return "No microphone is available. Connect one, or pick an input in System Settings › Sound."
        case .outsideApp:
            return "Dictation works in the packaged HermesBot.app only (this copy runs outside it, for example `swift run`)."
        case .failed(let reason):
            return "Dictation stopped: \(reason)"
        }
    }

    /// The System Settings pane that fixes it, when there is one.
    var settingsURL: URL? {
        switch self {
        case .microphoneDenied: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechDenied: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        default: return nil
        }
    }
}

/// What the recognizer reports, on the main actor and in order.
enum DictationUpdate: Equatable {
    /// The best transcription so far (it replaces the previous one).
    case partial(String)
    /// The last transcription; the recognizer is done.
    case final(String)
    /// The recognizer ended without hearing anything.
    case ended
    case failed(DictationError)
}

/// B17: speech-to-text for the composer's mic button (`SystemSpeechRecognizer` in the app, fakes in tests).
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// Asks for speech recognition and microphone access the first time; nil when both are granted.
    func authorize() async -> DictationError?
    /// Starts listening; `onUpdate` is called on the main actor until `stop` or a final/ended/failed update.
    func start(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws(DictationError)
    /// Stops listening and discards whatever the recognizer still has.
    func stop()
}

/// Where dictated words go: in place of the selection at the caret, spaced from the text around them.
struct DictationInsertion: Equatable {
    let prefix: String
    let suffix: String

    /// `caret` in UTF-16 units (NSTextView); nil appends to the end.
    init(text: String, caret: NSRange?) {
        let ns = text as NSString
        guard let caret else { prefix = text; suffix = ""; return }
        let start = min(max(0, caret.location), ns.length)
        let end = min(ns.length, start + max(0, caret.length))
        // Never split a surrogate pair or a composed character.
        func boundary(_ i: Int) -> Int { i >= ns.length ? ns.length : ns.rangeOfComposedCharacterSequence(at: i).location }
        let safeStart = boundary(start)
        prefix = ns.substring(to: safeStart)
        suffix = ns.substring(from: max(safeStart, boundary(end)))
    }

    private func lead(_ spoken: String) -> String {
        guard !spoken.isEmpty, let last = prefix.last, !last.isWhitespace else { return "" }
        return " "
    }

    private func trail(_ spoken: String) -> String {
        guard !spoken.isEmpty, let first = suffix.first, !first.isWhitespace, !first.isPunctuation else { return "" }
        return " "
    }

    /// The composer text with `spoken` in place.
    func text(with spoken: String) -> String { prefix + lead(spoken) + spoken + trail(spoken) + suffix }

    /// The caret after the dictated words, in UTF-16 units.
    func caret(with spoken: String) -> Int { (prefix + lead(spoken) + spoken + trail(spoken)).utf16.count }
}

/// B17: one composer's dictation. The mic button toggles it; recognized words stream into the text at
/// the caret (each partial replaces the previous one); it stops after `silenceTimeout` without new words
/// (`initialTimeout` before the first), on the button, on Send, or when the user edits the text meanwhile.
/// Permissions are asked lazily, on the first use.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle, starting, listening
        case failed(DictationError)
    }

    @Published private(set) var state: State = .idle
    /// Where the caret goes after the last insertion (UTF-16 offset), for the field editor.
    @Published private(set) var caret: Int?
    var isActive: Bool { state == .starting || state == .listening }
    var error: DictationError? { if case .failed(let e) = state { return e } else { return nil } }

    var silenceTimeout: TimeInterval = 2
    var initialTimeout: TimeInterval = 8

    private let engine: any SpeechRecognizing
    private var read: () -> String = { "" }
    private var write: (String) -> Void = { _ in }
    private var insertion: DictationInsertion?
    /// The text this controller last wrote: anything else means the user edited it.
    private var written: String?
    private var silence: Task<Void, Never>?
    private var session = 0

    init(engine: any SpeechRecognizing = SystemSpeechRecognizer()) {
        self.engine = engine
    }

    /// The mic button.
    func toggle(text: Binding<String>, caret: NSRange?) {
        if isActive { stop() } else { start(text: text, caret: caret) }
    }

    func start(text: Binding<String>, caret: NSRange?) {
        guard !isActive else { return }
        session += 1
        let current = session
        read = { text.wrappedValue }
        write = { text.wrappedValue = $0 }
        insertion = nil
        written = nil
        self.caret = nil
        state = .starting
        Task {
            if let denied = await engine.authorize() {
                guard current == session, state == .starting else { return }
                state = .failed(denied)
                return
            }
            guard current == session, state == .starting else { return }
            insertion = DictationInsertion(text: read(), caret: caret)
            do {
                try engine.start { [weak self] update in
                    guard let self, current == self.session else { return }
                    self.apply(update)
                }
            } catch {
                state = .failed(error as? DictationError ?? .failed(error.localizedDescription))
                return
            }
            state = .listening
            armSilence(initialTimeout)
        }
    }

    /// Ends dictation, keeping the words already inserted. A no-op when idle; clears an error.
    func stop() {
        session += 1
        silence?.cancel()
        silence = nil
        if state == .listening { engine.stop() }
        insertion = nil
        written = nil
        if state != .idle { state = .idle }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    private func apply(_ update: DictationUpdate) {
        guard state == .listening else { return }
        switch update {
        case .partial(let words):
            insert(words)
            armSilence(silenceTimeout)
        case .final(let words):
            insert(words)
            stop()
        case .ended:
            stop()
        case .failed(let e):
            stop()
            state = .failed(e)
        }
    }

    private func insert(_ words: String) {
        guard let insertion, state == .listening else { return }
        if let written, read() != written {
            stop()  // the user changed the text: their edit wins
            return
        }
        let text = insertion.text(with: words)
        written = text
        write(text)
        caret = insertion.caret(with: words)
    }

    private func armSilence(_ seconds: TimeInterval) {
        silence?.cancel()
        let current = session
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, current == self.session, self.state == .listening else { return }
            self.stop()
        }
    }
}

/// The composer's caret, read from and put back into the field editor (the NSTextView that edits a
/// focused SwiftUI text field), only when it is editing exactly this text.
@MainActor
enum DictationCaret {
    static func current(text: String) -> NSRange? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text else { return nil }
        return editor.selectedRange()
    }

    /// After SwiftUI has pushed the new text into the field editor (next runloop turn).
    static func place(_ offset: Int, text: String) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text else { return }
            let length = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: min(offset, length), length: 0))
        }
    }
}
