import AppKit
import HermesGatewayKit
import SwiftUI

// The Group Chat Activity inspector (roadmap C1.3 + C1.10), shown beside the room with ⌥⌘I like Bot Chat's
// details. One section per member: avatar, name, status chips, what it is doing now, then its recent
// activity newest first. Live rows come from the `bot-activity` plugin (`RoomActivityModel`); the ribbon's
// turn state stays beside the live phase. Without the plugin the chips are the ribbon's turn states, a
// "This round" list tells the latest round from the room log, and an opt-in card offers to enable tracking.
// Polling pauses while the window is occluded or the app hidden.

struct RoomActivityPanel: View {
    @ObservedObject var room: RoomModel
    let activity: RoomActivityModel?

    var body: some View {
        if let activity {
            LiveActivityPanel(room: room, activity: activity, gate: activity.gate)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    ActivityPanelHeader(menu: nil, busy: false)
                    ActivityMemberList(room: room, activity: nil, limits: .constant([:]))
                    RoundFeedSection(room: room)
                }
                .padding(DS.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LiveActivityPanel: View {
    @ObservedObject var room: RoomModel
    @ObservedObject var activity: RoomActivityModel
    /// An action in flight (possibly from another room) disables the others.
    @ObservedObject var gate: BotActivityActionGate
    @State private var confirmEnable = false
    @State private var confirmTurnOff = false
    @State private var confirmReinstall = false
    /// Rows shown per member ("Show more" raises it).
    @State private var limits: [String: Int] = [:]
    @Environment(\.motionEnabled) private var motion

    private var trackingOn: Bool {
        switch activity.pluginState {
        case .ready, .needsRollOut: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                ActivityPanelHeader(menu: trackingOn ? { confirmTurnOff = true } : nil, busy: gate.isBusy)
                ActivityStateBanner(activity: activity, gate: gate, onEnable: { confirmEnable = true },
                                    onReinstall: { confirmReinstall = true })
                ActivityMemberList(room: room, activity: activity, limits: $limits)
                if !activity.loaded { RoundFeedSection(room: room) }
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(motion ? DS.Motion.ease : nil, value: activity.pluginState)
            .animation(motion ? DS.Motion.ease : nil, value: activity.actionError)
        }
        .environmentObject(activity.disclosure)
        .background(WindowVisibilityObserver { activity.setVisible($0) })
        .onAppear {
            activity.setMembers(room.room.members)
            activity.start()
        }
        .onDisappear { activity.stop() }
        .onChange(of: room.room.members) { _, m in activity.setMembers(m) }
        // Not `.sheet`: its slide and dimmer fade ignore the motion gate (MotionSheet.swift).
        .motionSheet(isPresented: $confirmEnable, motion: motion) {
            EnableActivitySheet(onEnable: {
                confirmEnable = false
                Task { await activity.enable() }
            }, onClose: { confirmEnable = false })
        }
        .confirmationDialog("Turn off activity tracking?", isPresented: $confirmTurnOff) {
            Button("Turn Off", role: .destructive) { Task { await activity.turnOff() } }
        } message: {
            Text(ActivityPresentation.turnOffConfirmation)
        }
        .confirmationDialog("Reinstall the reviewed version?", isPresented: $confirmReinstall) {
            Button("Reinstall Pinned Version") { Task { await activity.reinstallPinned() } }
        } message: {
            Text(ActivityPresentation.reinstallConfirmation)
        }
    }
}

extension RoomActivityModel {
    /// Polling runs only while this is true.
    nonisolated static func isOnScreen(occlusion: NSWindow.OcclusionState, appHidden: Bool) -> Bool {
        !appHidden && occlusion.contains(.visible)
    }
}

/// Reports whether the hosting window is on screen (not fully occluded, app not hidden), on attach and on
/// every occlusion / hide / unhide change. Observers are selector-based, so they go away with the view.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private weak var observed: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let nc = NotificationCenter.default
            if let observed { nc.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observed) }
            nc.removeObserver(self, name: NSApplication.didHideNotification, object: nil)
            nc.removeObserver(self, name: NSApplication.didUnhideNotification, object: nil)
            observed = window
            guard let window else { return }
            nc.addObserver(self, selector: #selector(changed), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            nc.addObserver(self, selector: #selector(changed), name: NSApplication.didHideNotification, object: nil)
            nc.addObserver(self, selector: #selector(changed), name: NSApplication.didUnhideNotification, object: nil)
            changed()
        }

        @objc private func changed() {
            guard let window else { return }
            onChange?(RoomActivityModel.isOnScreen(occlusion: window.occlusionState, appHidden: NSApp.isHidden))
        }
    }
}

/// "Activity" title, and the panel menu while tracking is on.
private struct ActivityPanelHeader: View {
    let menu: (() -> Void)?
    /// A plugin action is in flight: the menu is disabled.
    let busy: Bool

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Text("Activity").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let menu {
                Menu {
                    Button("Turn Off Activity Tracking…", role: .destructive, action: menu)
                } label: {
                    Image(systemName: "ellipsis.circle").font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
                .accessibilityLabel("Activity options")
                .help("Activity options")
            }
        }
    }
}

// MARK: - plugin state

/// The opt-in card, progress, roll-out and error lines above the members.
private struct ActivityStateBanner: View {
    @ObservedObject var activity: RoomActivityModel
    /// Observed for the stage of an enable in flight (possibly started from another room); while any action
    /// runs, the action buttons are disabled.
    @ObservedObject var gate: BotActivityActionGate
    let onEnable: () -> Void
    let onReinstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            switch activity.pluginState {
            case .unknown:
                progress("Checking for live activity…")
            case .pluginMissing:
                enableCard
            case .enabling:
                progress(activity.enableStage == .rollingOut ? "Turning it on for every bot…" : "Installing the Bot Activity plugin…")
            case .removing:
                progress("Turning off activity tracking for every bot…")
            case .unpinnedCopy:
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    failure("An installed Bot Activity copy isn't the reviewed version")
                    paragraph("It was not installed from the reviewed commit \(BotActivityPluginManager.pinnedRef.prefix(7)), so it was left off.")
                    Button("Reinstall Pinned Version…", action: onReinstall)
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(gate.isBusy)
                        .help("Replace it with the reviewed commit and turn it on for every bot")
                }
            case .needsRollOut(let bots):
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    paragraph("\(bots.count) \(bots.count == 1 ? "bot isn't" : "bots aren't") tracked yet: \(bots.joined(separator: ", ")).")
                    Button("Enable for \(bots.count) More \(bots.count == 1 ? "Bot" : "Bots")") { Task { await activity.rollOut() } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(gate.isBusy)
                }
            case .error(let message):
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    failure("Can't load activity: \(message)")
                    Button("Try Again") { activity.retry() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            case .ready:
                EmptyView()
            }
            if let error = activity.actionError {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    failure(error)
                    IconButton(symbol: "xmark", label: "Dismiss") { activity.dismissActionError() }
                }
            }
        }
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Live activity is off").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
            paragraph("See each bot's tool calls, reasoning and errors as they happen. Until then, this shows each bot's turn status.")
            Button("Enable Tracking…", action: onEnable)
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(gate.isBusy)
                .padding(.top, DS.Space.s1)
                .help("Install the Bot Activity plugin and turn it on for every bot")
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: DS.Space.s2) {
            ProgressView().controlSize(.mini).accessibilityHidden(true)
            paragraph(text)
        }
        .accessibilityElement(children: .combine)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failure(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The opt-in confirmation: what gets installed, from where, and that it can be turned off.
struct EnableActivitySheet: View {
    let onEnable: () -> Void
    /// The sheet is presented by `motionSheet`, not SwiftUI, so `\.dismiss` would not reach it.
    let onClose: () -> Void

    nonisolated static let sourceURL = URL(string: BotActivityPluginManager.repository + "/tree/" + BotActivityPluginManager.pinnedRef)!

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Turn on activity tracking?").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                text("To show what each bot in a group chat is doing (tool calls, reasoning, errors), Hermes Bot installs the open-source Bot Activity plugin into Hermes and turns it on for every bot, including bots where it was turned off.")
                Link(destination: Self.sourceURL) {
                    Text("github.com/risyadul/hermes-bot-activity").font(DS.Typeface.body).underline()
                }
                .foregroundStyle(DS.Palette.link)
                .help(Self.sourceURL.absoluteString)
                Text("Pinned to the reviewed commit \(BotActivityPluginManager.pinnedRef.prefix(7)).")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                text("Activity stays on this Mac, in Hermes. You can turn it off later from the Activity panel menu.")
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Enable", action: onEnable)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
    }

    private func text(_ s: String) -> some View {
        Text(s).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - members

private struct ActivityMemberList: View {
    @ObservedObject var room: RoomModel
    let activity: RoomActivityModel?
    @Binding var limits: [String: Int]
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        let live = activity?.loaded == true
        let turns = RoomPresentation.memberStates(room: room.room, timeline: room.timeline, driver: room.driver)
        let fallback = ActivityPresentation.fallbackStatuses(room: room.room, turns: turns)
        let byMember = Dictionary((activity?.memberActivity ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            ForEach(Array(room.room.members.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Hairline() }
                let identity = avatars.identity(profile: m.profile, title: m.title)
                if live, let activity, let a = byMember[m.memberId] {
                    MemberActivitySection(identity: identity, title: m.title, activity: a, turn: turns[m.memberId],
                                          now: { activity.now },
                                          limit: Binding(get: { limits[m.memberId] ?? Self.pageSize },
                                                         set: { limits[m.memberId] = $0 }))
                } else {
                    MemberHeader(identity: identity, title: m.title, statuses: [fallback[m.memberId] ?? ActivityPresentation.status(.idle)])
                }
            }
        }
    }

    static let pageSize = 30
}

private struct MemberHeader: View {
    let identity: BotIdentity
    let title: String
    let statuses: [ActivityStatus]

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            AvatarView(identity: identity, size: DS.Size.avatarSuggestion)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(title).font(DS.Typeface.bodyStrong).foregroundStyle(identity.nameColor).lineLimit(1)
                HStack(spacing: DS.Space.s1) {
                    ForEach(statuses, id: \.label) { ActivityStatusChip(status: $0, identity: identity) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + statuses.map(\.label)).joined(separator: ", "))
    }
}

/// "This round" without the plugin: the latest round from the room log, newest first (C1.3).
private struct RoundFeedSection: View {
    @ObservedObject var room: RoomModel
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        let entries = ActivityPresentation.roundFeed(room: room.room, timeline: room.timeline, driver: room.driver)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Hairline()
                Text("This round").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                ForEach(entries) { e in
                    let member = room.room.member(e.memberId)
                    let identity = member.map { avatars.identity(profile: $0.profile, title: $0.title) }
                    HStack(spacing: DS.Space.s2) {
                        Text(e.title).font(DS.Typeface.meta)
                            .foregroundStyle(identity?.nameColor ?? DS.Palette.muted).lineLimit(1)
                        Spacer(minLength: DS.Space.s1)
                        ActivityStatusChip(status: e.status, identity: identity)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(e.title), \(e.status.label)")
                }
            }
        }
    }
}

private struct MemberActivitySection: View {
    let identity: BotIdentity
    let title: String
    let activity: MemberActivity
    /// The ribbon's turn state, kept beside the live phase.
    let turn: RoomPresentation.MemberState?
    let now: () -> Double
    @Binding var limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            MemberHeader(identity: identity, title: title,
                         statuses: ActivityPresentation.chips(phase: activity.phase, current: activity.current, turn: turn))
            if let current = activity.current {
                // The elapsed time is data, not motion: it ticks with motion off too.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(ActivityPresentation.currentText(current, now: now()))
                        .font(DS.Typeface.meta.monospacedDigit()).foregroundStyle(DS.Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityLabel("Now: \(ActivityPresentation.currentLabel(current))")
            }
            if activity.items.isEmpty {
                Text("No activity yet").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(activity.items.prefix(limit)) { item in ActivityItemRow(item: item) }
                }
                if activity.items.count > limit {
                    Button("Show More (\(activity.items.count - limit))") { limit += ActivityMemberList.pageSize }
                        .buttonStyle(.link)
                        .font(DS.Typeface.meta)
                        .accessibilityHint("Shows older activity of \(title)")
                }
            }
        }
    }
}

/// `status-chip` without avatar and name (the section header carries them).
private struct ActivityStatusChip: View {
    let status: ActivityStatus
    /// Tints the `waiting` hairline; nil (a room-level entry) uses the muted colour.
    let identity: BotIdentity?

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if status.tone == .working { WorkingDots(color: DS.Palette.ink) }
            if let symbol = status.symbol { Image(systemName: symbol).font(DS.Typeface.iconSmall) }
            Text(status.label).font(status.tone == .attention ? DS.Typeface.metaStrong : DS.Typeface.meta)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s0)
        .background(status.tone == .attention ? DS.Palette.attentionSoft : DS.Palette.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(border, lineWidth: DS.Stroke.ring))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }

    private var foreground: Color {
        switch status.tone {
        case .attention: return DS.Palette.attention
        case .danger: return DS.Palette.danger
        case .done, .working: return DS.Palette.ink
        case .quiet, .waiting: return DS.Palette.muted
        }
    }

    private var border: Color {
        switch status.tone {
        case .attention: return DS.Palette.attentionRing
        case .danger: return DS.Palette.dangerRing
        case .waiting: return (identity?.color ?? DS.Palette.muted).opacity(DS.Palette.waitingBorder)
        default: return .clear
        }
    }
}

// MARK: - rows

/// "Turn finished · 4.2s" between two hairlines. The label never shrinks: the trailing rule gives way.
struct ActivityTurnDivider: View {
    /// Tool titles in the narrow panel wrap to this many lines (ToolActivityRow `titleLines`).
    static let toolTitleLines = 2

    let title: String?
    let finished: Bool
    let duration: String?

    static func label(finished: Bool, duration: String?) -> String {
        finished ? "Turn finished" + (duration.map { " · \($0)" } ?? "") : "Turn started"
    }

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Hairline().frame(width: DS.Space.s3)
            Text(Self.label(finished: finished, duration: duration))
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
                .fixedSize()
            Hairline()
        }
        .padding(.vertical, DS.Space.s1)
        .help(title ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(finished: finished, duration: duration))
    }
}

private struct ActivityItemRow: View {
    let item: ActivityItem

    var body: some View {
        switch item.kind {
        case .tool(let line):
            ToolActivityRow(line: line, titleLines: ActivityTurnDivider.toolTitleLines)
                .padding(.leading, -DS.Space.s2)
                .background(item.isError ? DS.Palette.dangerSoft : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        case .reasoning(let line):
            ThoughtRow(line: line, opensWhileStreaming: false).padding(.leading, -DS.Space.s2)
        case .message(let text, let streaming):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: streaming ? "ellipsis.bubble" : "text.bubble").font(DS.Typeface.iconSmall)
                    .foregroundStyle(DS.Palette.muted).accessibilityHidden(true)
                Text(text.isEmpty ? "Writing…" : text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                    .lineLimit(3).truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel((streaming ? "Writing: " : "Wrote: ") + text)
        case .turn(let title, let finished, let duration):
            ActivityTurnDivider(title: title, finished: finished, duration: duration)
        case .error(let title, let detail):
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Label(title, systemImage: "exclamationmark.triangle.fill").font(DS.Typeface.metaStrong)
                if let detail, !detail.isEmpty {
                    Text(detail).font(DS.Typeface.meta).lineLimit(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(DS.Palette.danger)
            .padding(DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(title)")
        case .approval(let title, let status):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: "hand.raised.fill").font(DS.Typeface.iconSmall)
                    .foregroundStyle(status == "waiting for approval" ? DS.Palette.attention : DS.Palette.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Approval: \(title), \(status)")
        case .other(let title, let status):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: "info.circle").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                    .accessibilityHidden(true)
                Text(title + (status.map { " · \($0)" } ?? "")).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
