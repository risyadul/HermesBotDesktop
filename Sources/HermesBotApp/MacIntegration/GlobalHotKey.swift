import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// D4: the global "Quick Ask" shortcut. Registered with Carbon's RegisterEventHotKey, which needs no
// Accessibility permission (unlike a global NSEvent monitor). Default ⌃⌥Space (⌥Space alone is commonly
// taken). The registrar is injected: tests use a recorder and never register a real hot key.

/// A key plus modifiers, stored as the Carbon virtual key code and Carbon modifier mask.
struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's label ("Space", "K").
    var key: String

    static let `default` = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")

    /// "⌃⌥Space": modifiers in the system's order (⌃⌥⇧⌘), then the key.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// A shortcut from a key press while recording, or nil when it cannot be a global shortcut: it needs ⌘, ⌃
    /// or ⌥ (Shift alone would swallow typing everywhere), and a bare modifier key is not a key.
    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> HotKeyShortcut? {
        let mods = carbonModifiers(flags)
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        guard let key = keyName(keyCode: keyCode, characters: characters) else { return nil }
        return HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: mods, key: key)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    static let modifierKeys: Set<Int> = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option,
                                         kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function]

    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        let code = Int(keyCode)
        guard !modifierKeys.contains(code), code != kVK_Escape else { return nil }
        if let name = named[code] { return name }
        guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty,
              c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return c.uppercased()
    }
}

/// Registers one global hot key. Production: `CarbonHotKeyRegistrar`; tests: a recorder.
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Registers `shortcut` (replacing any earlier one); false when the system refused it (taken by another app).
    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// RegisterEventHotKey on the application event target; the press arrives as a Carbon event on the main thread.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (@MainActor () -> Void)?
    private static let signature: OSType = 0x4842_5141  // "HBQA"

    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { CarbonHotKeyRegistrar.action?() } }
                return noErr
            }
            guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handler) == noErr else {
                handler = nil
                return false
            }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// The Quick Ask shortcut setting (UserDefaults) and its registration. `apply()` re-registers after a change.
@MainActor
final class QuickAskHotKey: ObservableObject {
    static let enabledKey = "hba.quickAsk.enabled"
    static let shortcutKey = "hba.quickAsk.shortcut"

    @Published private(set) var enabled: Bool
    @Published private(set) var shortcut: HotKeyShortcut
    /// The system refused the shortcut (another app holds it); nil when registered or off.
    @Published private(set) var problem: String?
    private(set) var registered = false

    private let registrar: any HotKeyRegistering
    private let defaults: UserDefaults
    private let action: @MainActor () -> Void

    init(registrar: any HotKeyRegistering, defaults: UserDefaults, action: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.defaults = defaults
        self.action = action
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        shortcut = defaults.data(forKey: Self.shortcutKey).flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) }
            ?? .default
    }

    func apply() {
        registrar.unregister()
        registered = false
        guard enabled else { problem = nil; return }
        registered = registrar.register(shortcut, action: action)
        problem = registered ? nil : "\(shortcut.display) is in use by another app. Pick another shortcut."
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        apply()
    }

    func setShortcut(_ s: HotKeyShortcut) {
        shortcut = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.shortcutKey) }
        apply()
    }

    func resetShortcut() { setShortcut(.default) }

    /// Stops listening (app quit).
    func stop() {
        registrar.unregister()
        registered = false
    }
}

/// "Click to record" shortcut field for Settings: the next key press with ⌘, ⌃ or ⌥ becomes the shortcut;
/// Escape cancels. Local key monitor only while recording (no Accessibility permission involved).
struct ShortcutRecorder: View {
    let shortcut: HotKeyShortcut
    let onChange: (HotKeyShortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type a shortcut…" : shortcut.display) { recording ? stop() : start() }
            .monospacedDigit()
            .help(recording ? "Press keys with ⌘, ⌃ or ⌥, or Escape to cancel" : "Click to record a new shortcut")
            .accessibilityLabel(recording ? "Recording a shortcut" : "Quick Ask shortcut \(shortcut.display)")
            .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let s = HotKeyShortcut.recorded(keyCode: event.keyCode, flags: event.modifierFlags,
                                               characters: event.charactersIgnoringModifiers) {
                onChange(s)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
