import AppKit
import HermesGatewayKit
import SwiftUI

// Settings sections for roadmap E1 (Background) and K8 (Kanban dispatcher). Models:
// BackgroundServeSettingsModel.swift, DispatcherStatusModel.swift (shared with the board chip). Layout: native grouped Form (DESIGN.md).

extension SettingsTone {
    var color: Color {
        switch self {
        case .ok: return DS.Palette.statusOK
        case .attention: return DS.Palette.attention
        case .danger: return DS.Palette.danger
        case .neutral: return DS.Palette.muted
        }
    }
}

/// "Status" row: dot + label, or a spinner while busy.
private struct SettingsStatusRow: View {
    let title: String
    let tone: SettingsTone
    let busy: Bool

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: DS.Space.s2) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    StatusDot(color: tone.color)
                }
                Text(title).foregroundStyle(tone == .neutral ? DS.Palette.muted : DS.Palette.ink)
            }
        }
    }
}

/// Error line: danger colour, selectable (already redacted by the model).
private struct SettingsErrorText: View {
    let text: String
    var body: some View {
        Label { Text(verbatim: text).textSelection(.enabled) } icon: { Image(systemName: "xmark.octagon") }
            .font(DS.Typeface.meta)
            .foregroundStyle(DS.Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFootnote: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Background (E1)

struct BackgroundServeSection: View {
    @ObservedObject var model: BackgroundServeSettingsModel

    var body: some View {
        Section {
            Toggle("Keep Hermes running in the background", isOn: Binding(
                get: { model.isOn },
                set: { on in Task { await model.setEnabled(on) } }))
                .disabled(!model.canToggle)
            SettingsStatusRow(title: model.summary.title, tone: model.summary.tone,
                              busy: model.busy && model.status != nil)
            if let detail = model.detail {
                Label { Text(verbatim: detail) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(DS.Typeface.meta)
                    .foregroundStyle(DS.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsReinstall {
                actionRow("Reinstall", hint: "Removes the LaunchAgent and installs it again.") {
                    await model.reinstall()
                }
            }
            if model.canStart {
                actionRow("Start", hint: "Starts the installed LaunchAgent again.") {
                    await model.start()
                }
            }
            if model.pendingNextLaunch {
                Label("Starts the next time you open the app (or at login); the app will then attach to it.", systemImage: "info.circle")
                    .font(DS.Typeface.meta)
                    .foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { SettingsErrorText(text: error) }
        } header: {
            Text("Background")
        } footer: {
            SettingsFootnote(text: """
                Installs a LaunchAgent that starts `hermes serve` at login and restarts it if it crashes; \
                the app then attaches to it instead of starting its own, so Group Chat rounds and routines \
                keep running after you quit. Turning it off stops that Hermes and removes the LaunchAgent. \
                Off by default. Log: \(Self.tilde(model.control.logFile.path))
                """)
        }
        .task { await model.load() }
        .confirmationDialog(promptTitle, isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.cancelPrompt() } }),
                            titleVisibility: .visible) {
            switch model.prompt {
            case .enable(let hermes, _, let offerSwitch)?:
                if offerSwitch {
                    Button("Switch Now") { Task { await model.confirmEnable(.switchNow, hermes: hermes) } }
                    Button("At Next Launch") { Task { await model.confirmEnable(.atNextLaunch, hermes: hermes) } }
                } else {
                    Button("Turn On") { Task { await model.confirmEnable(.now, hermes: hermes) } }
                }
            case .disableWhileAttached?:
                Button("Turn Off", role: .destructive) { Task { await model.confirmDisable() } }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { model.cancelPrompt() }
        } message: {
            Text(verbatim: model.prompt.map { BackgroundServeSettingsModel.promptText($0).message } ?? "")
        }
    }

    private var promptTitle: String { model.prompt.map { BackgroundServeSettingsModel.promptText($0).title } ?? "" }

    private func actionRow(_ title: String, hint: String, _ action: @escaping () async -> Void) -> some View {
        HStack(spacing: DS.Space.s3) {
            Text(hint).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            Button(title) { Task { await action() } }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .disabled(model.busy)
        }
    }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Kanban dispatcher (K8)

struct GatewaySection: View {
    @ObservedObject var model: DispatcherStatusModel

    var body: some View {
        Section {
            SettingsStatusRow(title: model.starting ? "Starting…" : model.summary.title, tone: model.summary.tone,
                              busy: model.starting)
            switch model.state {
            case .installedNotRunning?:
                HStack(spacing: DS.Space.s3) {
                    Text("Ready, assigned tasks wait until it runs.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.s2)
                    Button("Start") { Task { await model.start() } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(!model.canStart)
                }
            case .notInstalled?:
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text("Hermes' gateway service is not installed. Run this once in Terminal; the app never installs it.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: GatewayStatus.installCommand)
                            .font(DS.Typeface.code)
                            .textSelection(.enabled)
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.inline, style: .continuous))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(GatewayStatus.installCommand, forType: .string)
                        }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
            case .unknown(let reason)?:
                Text(verbatim: reason)
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .running?, nil:
                EmptyView()
            }
            if let output = model.output {
                Text(verbatim: output)
                    .font(DS.Typeface.code).foregroundStyle(DS.Palette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { SettingsErrorText(text: error) }
            HStack {
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .disabled(model.starting)
            }
        } header: {
            Text("Kanban dispatcher")
        } footer: {
            SettingsFootnote(text: "`hermes gateway` hands ready, assigned Kanban tasks to their bots. It is Hermes' own service, separate from the background Hermes above.")
        }
        .task { await model.refresh() }
    }
}
