import AppKit
import SwiftUI

/// B17: the composer's mic button. Toggles dictation into `text` at the caret; while listening it shows a
/// filled, pressed mic that pulses (with motion on). Starting dictation stops
/// Read Aloud, so the reply is not dictated back.
struct DictationButton: View {
    @ObservedObject var dictation: DictationController
    @Binding var text: String
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        IconButton(symbol: dictation.isActive ? "mic.fill" : "mic", label: Self.label(dictation.isActive),
                   pressed: dictation.isActive) {
            if !dictation.isActive { ReadAloudController.shared.stop() }
            dictation.toggle(text: $text, caret: DictationCaret.current(text: text))
        }
        .symbolEffect(.pulse, isActive: motion && dictation.state == .listening)
        .onChange(of: dictation.caret) { _, offset in
            if let offset { DictationCaret.place(offset, text: text) }
        }
        .onDisappear { dictation.stop() }
    }

    nonisolated static func label(_ active: Bool) -> String { active ? "Stop dictation" : "Dictate" }
}

/// B17: why dictation did not start or stopped, above the composer field, with the System Settings pane
/// that fixes it when there is one.
struct DictationErrorBanner: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        if let error = dictation.error {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: "mic.slash").font(DS.Typeface.iconSmall)
                Text(error.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: DS.Space.s2)
                if let url = error.settingsURL {
                    Button("Open System Settings") { NSWorkspace.shared.open(url) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                IconButton(symbol: "xmark", label: "Dismiss") { dictation.dismissError() }
            }
            .font(DS.Typeface.meta)
            .foregroundStyle(DS.Palette.danger)
            .accessibilityElement(children: .contain)
        }
    }
}

/// B17: a reply's Read Aloud hover button. Click reads the reply, Shift-click its whole turn; while that
/// reply is being read it stops it.
struct ReadAloudButton: View {
    let item: ReadAloudItem
    @ObservedObject private var speech = ReadAloudController.shared

    var body: some View {
        let speaking = speech.speakingId == item.id
        MessageActionButton(symbol: speaking ? "stop.circle" : "speaker.wave.2",
                            label: speaking ? "Stop reading" : "Read aloud (Shift-click: whole turn)") {
            if speaking {
                speech.stop()
            } else {
                let whole = NSEvent.modifierFlags.contains(.shift)
                speech.speak(whole ? item.turn : item.reply, id: item.id)
            }
        }
    }
}

/// B17: Read Aloud in a reply's context menu.
struct ReadAloudMenuItems: View {
    let item: ReadAloudItem
    @ObservedObject private var speech = ReadAloudController.shared

    var body: some View {
        if speech.isSpeaking {
            Button("Stop Reading") { speech.stop() }
        }
        Button("Read Aloud") { speech.speak(item.reply, id: item.id) }
        if item.hasLongerTurn {
            Button("Read Turn Aloud") { speech.speak(item.turn, id: item.id) }
        }
    }
}

/// Settings › Voice: "Read replies aloud automatically" (off by default).
struct VoiceSection: View {
    @AppStorage private var autoRead: Bool

    init(store: UserDefaults = .standard) { _autoRead = Self.setting(store) }

    /// The stored setting, shared with `ReadAloudController.autoReadEnabled`.
    static func setting(_ store: UserDefaults) -> AppStorage<Bool> {
        AppStorage(wrappedValue: ReadAloudController.autoReadByDefault, ReadAloudController.autoReadKey, store: store)
    }

    static let footnote: LocalizedStringKey = """
        Speaks each new Bot Chat reply when it finishes, in the system voice (System Settings › Accessibility › \
        Spoken Content). Code blocks and tool activity are skipped; Esc or sending a message stops it. The mic \
        in the composer dictates with macOS speech recognition, on this Mac when your language supports it.
        """

    var body: some View {
        Section {
            Toggle("Read replies aloud automatically", isOn: $autoRead)
                .accessibilityLabel("Read replies aloud automatically")
        } header: {
            Text("Voice")
        } footer: {
            Text(Self.footnote)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
