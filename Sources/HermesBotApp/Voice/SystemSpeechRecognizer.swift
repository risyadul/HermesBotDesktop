@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// B17: dictation with the Speech framework: the microphone through AVAudioEngine into an
/// SFSpeechAudioBufferRecognitionRequest, on this Mac when the language supports it (nothing leaves the
/// Mac then), with partial results and automatic punctuation. The recognizer follows the user's language
/// (System Settings › General › Language & Region). Permissions are asked on the first use only.
@MainActor
final class SystemSpeechRecognizer: SpeechRecognizing {
    private var recognizer: SFSpeechRecognizer?
    private var audio: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// The Info.plist usage strings macOS requires before it shows either permission prompt; without them
    /// (a `swift run` build) the request would end the process.
    nonisolated static func bundleDeclaresUsage(_ info: [String: Any]?) -> Bool {
        info?["NSMicrophoneUsageDescription"] is String && info?["NSSpeechRecognitionUsageDescription"] is String
    }

    func authorize() async -> DictationError? {
        guard Self.bundleDeclaresUsage(Bundle.main.infoDictionary) else { return .outsideApp }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        switch speech {
        case .authorized: break
        case .restricted: return .restricted
        default: return .speechDenied
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? nil : .microphoneDenied
        case .restricted: return .restricted
        default: return .microphoneDenied
        }
    }

    func start(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws(DictationError) {
        stop()
        guard let recognizer = SFSpeechRecognizer() else {
            let id = Locale.current.identifier
            throw .unsupportedLanguage(Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        guard recognizer.isAvailable else { throw .recognizerUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw .noMicrophone }
        Self.installTap(on: input, format: format, feeding: Box(request))
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            throw .failed(error.localizedDescription)
        }
        self.recognizer = recognizer
        self.audio = audio
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(onUpdate))
    }

    func stop() {
        if let audio {
            audio.stop()
            audio.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        audio = nil
        request = nil
        task = nil
        recognizer = nil
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               feeding box: Box<SFSpeechAudioBufferRecognitionRequest>) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in box.value.append(buffer) }
    }

    /// Built outside the main actor: the recognizer calls it on its own queue. Updates reach the main actor
    /// in order (FIFO on the main queue).
    nonisolated private static func handler(_ onUpdate: @escaping @MainActor (DictationUpdate) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        let deliver = Box(onUpdate)
        return { result, error in
            let update: DictationUpdate?
            if let result {
                let words = result.bestTranscription.formattedString
                update = result.isFinal ? .final(words) : .partial(words)
            } else if let error {
                update = Self.update(for: error as NSError)
            } else {
                update = nil
            }
            guard let update else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver.value(update) } }
        }
    }

    /// The recognizer's errors in words. "No speech detected" (1110) and a cancelled task (216, 301) are
    /// not failures.
    nonisolated static func update(for error: NSError) -> DictationUpdate? {
        let quiet: Set<Int> = [203, 216, 301, 1110]
        if quiet.contains(error.code) { return .ended }
        return .failed(.failed(error.localizedDescription))
    }
}

/// Hands a value the frameworks only touch from one thread at a time to their callbacks.
private final class Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
