import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - ribbon

/// The turn ribbon (DESIGN.md motif): room status chip, then one chip per member with its real state.
struct TurnRibbon: View {
    @ObservedObject var model: RoomModel
    let states: [String: RoomPresentation.MemberState]
    @ObservedObject var memory: RoomMotionMemory
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s2) {
                RoomStatusChip(status: RoomPresentation.roomStatus(model))
                ForEach(model.room.members) { m in
                    MemberChip(identity: avatars.identity(profile: m.profile, title: m.title), title: m.title,
                               state: states[m.memberId] ?? .idle, bump: memory.bumps[m.memberId] ?? 0)
                }
            }
            .padding(.leading, DS.Space.s4).padding(.trailing, DS.Space.s5).padding(.vertical, DS.Space.gutter)
        }
        // More chips than fit (a 6-bot room) scroll sideways: the trailing edge fades so the cut-off chip
        // reads as "more", not as a clipped layout.
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: DS.Space.s5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn status")
    }
}

/// The room-level chip: the single place that says the room is working.
struct RoomStatusChip: View {
    let status: RoomPresentation.RoomStatus
    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch status.tone {
            case .working: WorkingDots(color: DS.Palette.ink)
            case .blocked: Image(systemName: "exclamationmark.octagon.fill").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.danger)
            case .quiet: StatusDot(color: DS.Palette.muted)
            }
            Text(status.text)
                .font(DS.Typeface.meta.weight(.medium))
                .foregroundStyle(status.tone == .blocked ? DS.Palette.danger : DS.Palette.ink)
                .contentTransition(.identity)
        }
        .padding(.horizontal, DS.Space.gutter).frame(height: DS.Size.controlHeight)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(status.tone == .blocked ? DS.Palette.dangerRing : .clear, lineWidth: DS.Stroke.ring))
        // No width animation: a label that changes length mid-animation truncates ("Working · 1 q…").
        // The text swaps at once; the dots carry the motion.
        .accessibilityElement(children: .combine)
    }
}

/// `status-chip`. Bounces once when `bump` changes (a real state change after the baseline).
/// `needs approval` / `needs retry` use the `attention` role (fill, ring, label and a symbol), so the one
/// state that waits on the user is never confused with `waiting` (a bot-colour hairline only).
struct MemberChip: View {
    let identity: BotIdentity
    let title: String
    let state: RoomPresentation.MemberState
    let bump: Int
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            AvatarView(identity: identity, size: DS.Size.avatarChip)
            Text(title).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
            HStack(spacing: DS.Space.s1) {
                if let symbol { Image(systemName: symbol).font(DS.Typeface.iconSmall) }
                Text(state.label).font(state.needsUser ? DS.Typeface.metaStrong : DS.Typeface.meta)
            }
            .foregroundStyle(labelColor)
            .contentTransition(.identity)
        }
        .padding(.leading, DS.Space.s1).padding(.trailing, DS.Space.gutter).frame(height: DS.Size.controlHeight)
        .background(state.needsUser ? DS.Palette.attentionSoft : DS.Palette.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(border, lineWidth: DS.Stroke.ring))
        .keyframeAnimator(initialValue: CGFloat(1), trigger: bump) { [motion] content, scale in
            content.scaleEffect(motion ? scale : 1)
        } keyframes: { _ in
            SpringKeyframe(DS.Motion.chipBounce, duration: 0.17)
            SpringKeyframe(1.0, duration: 0.25)
        }
        // The bounce is the state-change motion; label and width swap at once (see RoomStatusChip).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state.label)")
    }

    private var symbol: String? {
        switch state {
        case .needsApproval: return "hand.raised.fill"
        case .deferred: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle.fill"
        case .replied: return "checkmark"
        default: return nil
        }
    }

    private var labelColor: Color {
        switch state {
        case .needsApproval, .deferred: return DS.Palette.attention
        case .failed: return DS.Palette.danger
        case .replied: return DS.Palette.ink
        default: return DS.Palette.muted
        }
    }

    private var border: Color {
        switch state {
        case .needsApproval, .deferred: return DS.Palette.attentionRing
        case .waiting: return identity.color.opacity(DS.Palette.waitingBorder)
        case .failed: return DS.Palette.dangerRing
        default: return .clear
        }
    }
}

// MARK: - rows

struct UserBubble: View {
    let text: String
    let time: Double
    var mentionHandles: Set<String> = []
    /// Files sent with the message (Group Chat `RoomAttachments`), under its text.
    var attachments: [MediaRef] = []
    /// The room the message was sent in: its attachments are that room's copies (`RoomAttachmentList`).
    var roomId = ""
    /// Bot Chat Find in chat (B13): matches highlighted; empty elsewhere.
    @Environment(\.findQuery) private var find

    var body: some View {
        HStack {
            Spacer(minLength: DS.Size.userBubbleInset)
            VStack(alignment: .trailing, spacing: DS.Space.s0) {
                if !text.isEmpty {
                    Text(Self.mentions(text, handles: mentionHandles, find: find))
                        .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                        .tint(DS.Palette.link)
                        .lineSpacing(DS.Typeface.proseLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !attachments.isEmpty {
                    RoomAttachmentList(refs: attachments, roomId: roomId)
                        .padding(.top, text.isEmpty ? 0 : DS.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if time > 0 { TimeLabel(time: time) }
            }
            .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
            .background(DS.Palette.primarySoft, in: UnevenRoundedRectangle(
                topLeadingRadius: DS.Radius.bubble, bottomLeadingRadius: DS.Radius.bubble,
                bottomTrailingRadius: DS.Radius.inline, topTrailingRadius: DS.Radius.bubble, style: .continuous))
            .frame(maxWidth: DS.Size.userWidth, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)" + (attachments.isEmpty ? "" : ", \(attachments.count) attached file\(attachments.count == 1 ? "" : "s")"))
    }

    /// The user's text with its http(s) links clickable (blue, underlined) and @mentions of real members (and
    /// @all/@everyone) in semibold blue, as in the bots' messages.
    static func mentions(_ text: String, handles: Set<String>, find: String = "") -> AttributedString {
        var a = TextStyling.linkified(text)
        TextStyling.highlightMentions(&a, handles: handles)
        TextStyling.highlightFind(&a, query: find)
        return a
    }
}

struct MemberMessage<Content: View>: View {
    let identity: BotIdentity
    let author: String
    let time: Double
    var trailingNote: String? = nil
    /// Read as one element (default). Off when the content holds its own controls (Thought, tool rows).
    var combinesAccessibility = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.gutter) {
            AvatarView(identity: identity, size: DS.Size.avatarMessage)
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(author).font(DS.Typeface.bodyStrong).foregroundStyle(identity.nameColor)
                    if let trailingNote { Text(trailingNote).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted) }
                    if time > 0 { TimeLabel(time: time) }
                }
                content
            }
            .frame(maxWidth: DS.Size.memberWidth, alignment: .leading)
        }
        .accessibilityElement(children: combinesAccessibility ? .combine : .contain)
    }
}

struct TimeLabel: View {
    let time: Double
    var body: some View {
        Text(Date(timeIntervalSince1970: time), format: .dateTime.hour().minute())
            .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
    }
}

/// Passes folded into one thin row, starting at the message content edge (`contentInset`); each avatar
/// pops in when its pass arrives live.
struct PassLine: View {
    let passes: [RoomRow.Pass]
    @ObservedObject var memory: RoomMotionMemory
    let identity: (RoomRow.Pass) -> BotIdentity
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s0) {
                ForEach(passes) { p in
                    AvatarView(identity: identity(p), size: DS.Size.avatarPass)
                        .transition(motion && memory.isNew(p.seq) ? .scale(scale: 0.4).combined(with: .opacity) : .identity)
                }
            }
            Text(RoomPresentation.passText(passes))
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                .contentTransition(.identity)
        }
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}

struct StatusLine: View {
    let identity: BotIdentity?
    let text: String
    var body: some View {
        HStack(spacing: DS.Space.s2) {
            if let identity { AvatarView(identity: identity, size: DS.Size.avatarPass) }
            Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
        }
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}

/// `action-card-failure` for a failed turn.
struct FailureCard: View {
    let identity: BotIdentity
    let author: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.gutter) {
            Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.icon).foregroundStyle(DS.Palette.danger)
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text("\(author): turn failed").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
        .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
        .background(DS.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Palette.dangerRing, lineWidth: DS.Stroke.ring))
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .combine)
    }
}
