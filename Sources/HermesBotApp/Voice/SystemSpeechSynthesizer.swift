@preconcurrency import AVFoundation
import Foundation

/// B17: Read Aloud through AVSpeechSynthesizer with the system voice: no voice is picked, and
/// `prefersAssistiveTechnologySettings` follows System Settings › Accessibility › Spoken Content (voice and
/// rate). Never created under XCTest (`ReadAloudController.shared`).
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {
    var onFinish: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    /// Utterance → token, so the delegate reports which read ended.
    private var tokens: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, token: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        tokens[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    private func ended(_ id: ObjectIdentifier) {
        guard let token = tokens.removeValue(forKey: id) else { return }
        onFinish?(token)
    }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
    }
}
