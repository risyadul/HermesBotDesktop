import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - action cards

/// `action-card`: a pending approval or retry from `groups.state`, drawn in the `attention` role (it
/// waits on the user). Buttons keep the M2 gating (`busyActions` key + room open) and call the same
/// `RoomModel` actions.
///
/// The card names the member, the reason (`description`) and the exact command. The approval payload
/// carries no tool name (`hosted_room_driver.py` `_report_pending_action` forwards `command`,
/// `description`, `pattern_key(s)`, `choices`, `request_id`; `tools/approval.py` builds it), so the
/// command block is labelled by what the payload holds instead of guessing a tool.
/// The command is drawn with `Text` in SF Mono, which never substitutes characters: an ASCII `-` stays
/// U+002D (SF Mono draws it wide; it is not an en dash).
struct ActionCard: View {
    @ObservedObject var model: RoomModel
    let action: RoomPendingAction
    @ObservedObject var memory: RoomMotionMemory
    let identity: (String?) -> BotIdentity
    @Environment(\.motionEnabled) private var motion
    /// When this card's one ripple started; nil when there is none (already played, or motion off).
    @State private var rippleStart: Date?

    var body: some View {
        card
            .attentionCard()
            .background {
                // One ring ripple per approval request id (RoomMotionMemory), never on reopen. Drawn from
                // the clock on every frame instead of a scheduled `withAnimation`, so it is gone in the
                // same frame the motion gate closes, including during its start delay.
                if let start = rippleStart {
                    TimelineView(.animation(paused: !motion)) { context in
                        if let p = ApprovalRipple.progress(at: context.date, start: start, motion: motion) {
                            RoundedRectangle(cornerRadius: DS.Radius.card + p * DS.Motion.ringGrow, style: .continuous)
                                .stroke(DS.Palette.attention.opacity(Double(1 - p) * DS.Motion.ringOpacity), lineWidth: DS.Stroke.ring)
                                .padding(-p * DS.Motion.ringGrow)
                        }
                    }
                }
            }
            .padding(.leading, DS.Size.contentInset)
            .onAppear {
                guard case .approval(let a) = action, memory.shouldRing(a.requestId), motion else { return }
                rippleStart = Date()
            }
            // Motion off cancels the ripple for good: turning motion back on does not replay it.
            .onChange(of: motion) { _, on in if !on { rippleStart = nil } }
            .task(id: rippleStart) {
                guard rippleStart != nil else { return }
                try? await Task.sleep(for: .seconds(ApprovalRipple.total))
                if !Task.isCancelled { rippleStart = nil }
            }
    }

    @ViewBuilder private var card: some View {
        switch action {
        case .approval(let a):
            let who = model.room.member(a.memberId)?.title ?? a.memberId
            let busy = model.busyActions.contains("approval:\(a.requestId)") || !model.composer.isOpen
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "hand.raised.fill").font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention)
                    AvatarView(identity: identity(a.memberId), size: DS.Size.avatarChip)
                    Text("\(who) needs your approval").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                }
                if let d = a.description, !d.isEmpty {
                    Text("Flagged: \(d)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                }
                if let c = a.command {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("Command").font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                        CodeBlock(text: c, header: false)
                    }
                }
                HStack(spacing: DS.Space.s2) {
                    if a.choices.contains("once") {
                        Button("Approve once") { model.approve(a, choice: "once") }
                            .buttonStyle(DSButtonStyle(kind: .primary)).disabled(busy)
                    }
                    if a.choices.contains("deny") {
                        Button("Deny", role: .destructive) { model.approve(a, choice: "deny") }
                            .buttonStyle(DSButtonStyle(kind: .danger)).disabled(busy)
                    }
                    if busy && model.composer.isOpen { ProgressView().controlSize(.small) }
                }
                .padding(.top, DS.Space.s1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(who) needs your approval")
        case .retry(let taskId):
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "arrow.clockwise").font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention)
                    Text("A bot turn needs a retry").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                }
                // `indeterminate` (its process died mid-turn) or `deferred` (gave up after that): the
                // backend never re-runs it on its own because it may have had side effects.
                Text("The turn ended without a confirmed result. Retry runs it again, so its side effects may repeat.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { model.retry(taskId) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(model.busyActions.contains("retry:\(taskId)") || !model.composer.isOpen)
                    .padding(.top, DS.Space.s1)
            }
        case .other(let kind):
            Text("Pending: \(kind)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
        }
    }
}

// MARK: - mentions

/// Suggestions while the draft ends in `@prefix`: room members whose handle or name starts with it.
/// Click (or Tab for the first match) replaces the prefix with `@handle `. Only edits the draft.
struct MentionSuggestions: View {
    @Binding var draft: String
    let members: [RoomMember]
    let identity: (RoomMember) -> BotIdentity
    @Environment(\.motionEnabled) private var motion

    private var matches: [RoomMember] { Self.matches(draft, members: members) }

    static func matches(_ draft: String, members: [RoomMember]) -> [RoomMember] {
        guard let r = draft.range(of: "(?:^|\\s)@([A-Za-z0-9._:-]*)$", options: .regularExpression) else { return [] }
        let q = String(draft[r].drop(while: { $0 != "@" }).dropFirst()).lowercased()
        return members.filter { q.isEmpty || $0.handle.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q) }
    }

    /// Tab in the composer: accept the first (highlighted) match. False when no suggestion is showing.
    static func acceptFirst(_ draft: inout String, members: [RoomMember]) -> Bool {
        guard let m = matches(draft, members: members).first else { return false }
        insert(m, into: &draft)
        return true
    }

    var body: some View {
        let list = matches
        VStack(alignment: .leading, spacing: 0) {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        Button { insert(m) } label: {
                            HStack(spacing: DS.Space.s2) {
                                AvatarView(identity: identity(m), size: DS.Size.avatarSuggestion)
                                Text(m.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                                Spacer(minLength: DS.Space.s3)
                                Text("@\(m.handle)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            }
                            .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Size.fieldInset)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SuggestionRowStyle(highlighted: i == 0))
                    }
                }
                .padding(DS.Space.s1)
                .frame(width: DS.Size.popoverWidth)
                .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                .dsShadow(DS.Elevation.popover)
                .transition(motion ? .scale(scale: DS.Motion.pressedScale, anchor: .bottomLeading).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion ? DS.Motion.pop : nil, value: list.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention suggestions")
    }

    private func insert(_ m: RoomMember) { Self.insert(m, into: &draft) }

    static func insert(_ m: RoomMember, into draft: inout String) {
        guard let r = draft.range(of: "@[A-Za-z0-9._:-]*$", options: .regularExpression) else { return }
        draft.replaceSubrange(r, with: "@\(m.handle) ")
    }
}

struct SuggestionRowStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .background(hovering || highlighted || configuration.isPressed ? DS.Palette.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
    }
}
