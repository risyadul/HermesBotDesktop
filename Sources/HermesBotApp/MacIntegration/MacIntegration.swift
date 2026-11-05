import AppKit
import SwiftUI

// Launch wiring for the macOS integration (D3, D4, D6; D7 intents need none, D12 lives in the room
// toolbar): one call from `AppDelegate.applicationDidFinishLaunching`. Registrars are injected, so tests can
// build a `MacIntegration` without touching the system's hot keys or Services.

@MainActor
final class MacIntegration {
    static let shared = MacIntegration(hotKeys: CarbonHotKeyRegistrar(), services: AppServicesRegistrar(), defaults: .standard)

    let hotKey: QuickAskHotKey
    private let services: any ServicesRegistering
    private let startBadge: @MainActor () -> Void
    /// Retained: `NSApp.servicesProvider` does not keep a strong reference everywhere it is used.
    private(set) var provider: HermesServicesProvider?
    private(set) var installed = false

    init(hotKeys: any HotKeyRegistering, services: any ServicesRegistering, defaults: UserDefaults,
         toggleQuickAsk: @escaping @MainActor () -> Void = { QuickAskPanelController.shared.toggle() },
         presentChooser: @escaping @MainActor (ServiceInput) -> Void = { SendChooserPresenter.shared.present($0) },
         startBadge: @escaping @MainActor () -> Void = { MenuBarBadge.shared.start { AppModel.shared.menuBarStatus } }) {
        hotKey = QuickAskHotKey(registrar: hotKeys, defaults: defaults, action: toggleQuickAsk)
        self.services = services
        self.startBadge = startBadge
        provider = HermesServicesProvider(present: presentChooser)
    }

    /// Registers the Quick Ask shortcut (when on) and the Services provider, and starts the menu bar count.
    /// Once per launch.
    func install() {
        guard !installed else { return }
        installed = true
        hotKey.apply()
        if let provider { services.install(provider) }
        startBadge()
    }

    func uninstall() {
        hotKey.stop()
    }
}

// MARK: - Settings

/// Settings → Mac Integration: the menu bar extra (D3) and the Quick Ask shortcut (D4).
struct MacIntegrationSection: View {
    @AppStorage(MenuBarScene.settingKey) private var menuBar = true
    @ObservedObject var hotKey: QuickAskHotKey

    var body: some View {
        Section {
            Toggle("Show in menu bar", isOn: $menuBar)
                .onChange(of: menuBar) { _, shown in MenuBarBadge.shared.setShown(shown) }
            Toggle("Quick Ask shortcut", isOn: Binding(get: { hotKey.enabled }, set: { hotKey.setEnabled($0) }))
            if hotKey.enabled {
                LabeledContent("Shortcut") {
                    HStack(spacing: DS.Space.s2) {
                        ShortcutRecorder(shortcut: hotKey.shortcut, onChange: { hotKey.setShortcut($0) })
                        if hotKey.shortcut != .default {
                            Button("Reset") { hotKey.resetShortcut() }.buttonStyle(.link)
                        }
                    }
                }
                if let problem = hotKey.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Mac Integration")
        } footer: {
            Text("""
                The menu bar shows what each bot and group chat is doing and sends a quick message. The shortcut \
                opens Quick Ask from any app. Services → Send to Hermes Bot and the Shortcuts actions work while \
                the app runs.
                """)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
