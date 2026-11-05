import SwiftUI

// E3: app menu → Check for Updates… and Settings → Updates. Checks run in UpdateChecker.

/// "Check for Updates…" under About in the app menu; disabled while a check runs.
struct CheckForUpdatesCommand: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Button("Check for Updates…") { Task { await checker.check(.manual) } }
            .disabled(checker.isChecking)
    }
}

/// Settings → Updates: the daily-check switch (`UpdatePolicy.autoCheckKey`, on by default), the last check and
/// Check Now.
struct UpdatesSection: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage private var autoCheck: Bool

    init(checker: UpdateChecker, store: UserDefaults = .standard) {
        _checker = ObservedObject(wrappedValue: checker)
        _autoCheck = Self.setting(store)
    }

    /// The stored setting, shared with `UpdatePolicy.isAutoCheckOn`.
    static func setting(_ store: UserDefaults) -> AppStorage<Bool> {
        AppStorage(wrappedValue: UpdatePolicy.autoCheckByDefault, UpdatePolicy.autoCheckKey, store: store)
    }

    static let footnote: LocalizedStringKey = """
        Once a day the app asks GitHub for the latest release (no account, nothing sent but the app version). \
        Nothing is downloaded or installed: Download opens the release page in your browser.
        """

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $autoCheck)
            LabeledContent("Last checked") {
                HStack(spacing: DS.Space.s2) {
                    if checker.isChecking {
                        ProgressView().controlSize(.small)
                    } else if let last = checker.lastCheck {
                        Text(last, format: .relative(presentation: .named)).foregroundStyle(DS.Palette.muted)
                    } else {
                        Text("Never").foregroundStyle(DS.Palette.muted)
                    }
                    Button("Check Now") { Task { await checker.check(.manual) } }
                        .disabled(checker.isChecking)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(Self.footnote)
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
