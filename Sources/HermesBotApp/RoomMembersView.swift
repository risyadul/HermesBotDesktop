import HermesGatewayKit
import SwiftUI

// MARK: - change members sheet

/// Room menu → Change Members… (C2.2). Step 1 is the create-room form prefilled with this room's name and
/// members; once the new room exists (RoomMemberChange) the sheet asks what happens to this room: Keep
/// (default, optionally renamed "… (old)") or Disband. There is no Cancel on that step: the new room is
/// already made, and Keep leaves everything else as it was.
struct ChangeMembersSheet: View {
    @ObservedObject var change: RoomMemberChange
    let bots: [Bot]
    /// Presented by `motionSheet`, so `\.dismiss` would not reach it (CreateRoomView.swift).
    let onClose: () -> Void

    var body: some View {
        switch change.phase {
        case .editing, .creating:
            CreateRoomView(bots: bots, replacing: change.old.room,
                           onCreate: { name, members in await change.create(name: name, members: members) },
                           onClose: onClose)
        case .deciding, .finishing, .done:
            OldRoomChoiceView(change: change, onClose: onClose)
        }
    }
}

/// Step 2: the new room's summary, then Keep / Disband for the old one.
private struct OldRoomChoiceView: View {
    @ObservedObject var change: RoomMemberChange
    let onClose: () -> Void

    private var busy: Bool { change.phase != .deciding }

    /// Long names and errors are cut at a few lines (full text in the tooltip), so the sheet stays inside the
    /// 520 pt window minimum (ChangeMembersLayoutTests).
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("New group chat ready").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            summary
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("What about the previous room?").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                Picker("Previous room", selection: $change.choice) {
                    Text("Keep it in the sidebar").tag(RoomMemberChange.OldRoom.keep)
                    Text("Disband it").tag(RoomMemberChange.OldRoom.disband)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .accessibilityLabel("Previous room")
                .disabled(busy)
                switch change.choice {
                case .keep:
                    Toggle(isOn: $change.renameOld) {
                        Text("Rename it to \u{201C}\(change.oldName)\u{201D}").lineLimit(2).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox).font(DS.Typeface.meta)
                    .accessibilityLabel("Rename it to \u{201C}\(change.oldName)\u{201D}")
                    .help(change.oldName)
                    .disabled(busy)
                case .disband:
                    Text("Its room id is retired for good and the file copies made for it are deleted. This cannot be undone.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = change.finishError {
                errorLine("Could not disband it: \(error)")
            }
            HStack(spacing: DS.Space.s2) {
                if change.phase == .finishing { ProgressView().controlSize(.small) }
                Spacer()
                switch change.choice {
                case .keep:
                    Button("Open New Room", action: finish)
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                case .disband:
                    // No default (Return) shortcut: a destructive action is never one keypress away.
                    Button(change.phase == .finishing ? "Disbanding…" : "Disband and Open New Room", action: finish)
                        .buttonStyle(DSButtonStyle(kind: .danger))
                        .disabled(busy)
                }
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
    }

    @ViewBuilder private var summary: some View {
        let members = change.created?.members.map(\.title).joined(separator: ", ") ?? ""
        let created = "Created \u{201C}\(change.created?.name ?? "")\u{201D} with \(members)."
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Label(created, systemImage: "checkmark.circle")
                .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                .lineLimit(3).truncationMode(.middle)
                .help(created)
            if let error = change.carryOverError {
                errorLine("The context message was not posted, so the new room starts empty: \(error)")
            } else {
                Text(change.quoted == 0
                     ? "Its first message says where it continues from."
                     : "Its first message quotes the previous room's last \(change.quoted == 1 ? "message" : "\(change.quoted) messages").")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .lineLimit(3).truncationMode(.tail)
            .help(text)
    }

    private func finish() {
        Task {
            // `finish` selects the new room, which replaces this room's pane (the sheet's host); the host's
            // teardown ends the sheet too, `onClose` keeps the binding in step.
            if await change.finish() { onClose() }
        }
    }
}
