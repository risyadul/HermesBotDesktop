import HermesGatewayKit
import SwiftUI

/// B6: whether the Bot Chat transcript follows new output, from the content's top and bottom edges in the
/// scroll view's own coordinates. The user scrolling up (the top edge moves down) stops following; reaching
/// the bottom again (within `slack`) resumes it. Content growing below the viewport while following (a reply
/// streaming in before the follow scroll lands) moves only the bottom edge, so it never stops following.
/// Unit tested (TranscriptFollowTests).
struct TranscriptFollow: Equatable {
    /// How close to the end still counts as "at the bottom".
    static let slack: CGFloat = 48

    private(set) var following = true
    private var lastTop: CGFloat?

    /// Distance from the viewport's bottom to the end of the content.
    static func distance(bottom: CGFloat, viewport: CGFloat) -> CGFloat { max(0, bottom - viewport) }

    /// Returns true when `following` changed.
    @discardableResult
    mutating func update(top: CGFloat, bottom: CGFloat, viewport: CGFloat) -> Bool {
        let before = following
        let scrolledUp = lastTop.map { top > $0 + 0.5 } ?? false
        lastTop = top
        if Self.distance(bottom: bottom, viewport: viewport) <= Self.slack {
            following = true
        } else if scrolledUp {
            following = false
        }
        return following != before
    }

    /// Jump to bottom / the user sent a message: follow again.
    mutating func resume() { following = true }
}

/// B6: messages that arrived while the user was scrolled up (their own messages, replies, errors), counted
/// once each, by line id. Zero again once the transcript follows. Unit tested (TranscriptFollowTests).
struct UnreadCounter: Equatable {
    private var seen: Set<UUID> = []
    private(set) var count = 0

    static func counts(_ line: ChatLine) -> Bool { line.role == .user || line.role == .bot || line.role == .error }

    mutating func update(_ lines: [ChatLine], following: Bool) {
        let ids = lines.filter(Self.counts).map(\.id)
        if following {
            seen = Set(ids)
            count = 0
        } else {
            count = ids.filter { !seen.contains($0) }.count
        }
    }
}

/// Scroll geometry for one Bot Chat view, kept in a reference so a scroll tick does not re-render the
/// transcript: the view publishes only `following` changes.
@MainActor final class TranscriptScrollTracker {
    var follow = TranscriptFollow()
    var edges = TranscriptEdges()
    var viewport: CGFloat = 0
}

/// The transcript content's top and bottom edges in the scroll view's coordinate space (`space`).
struct TranscriptEdges: Equatable, Sendable {
    static let space = "hba.transcript"
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

/// B6: the floating "jump to bottom" control (Desktop `scroll-to-bottom-button.tsx`): centred above the
/// composer while the user is scrolled up, with the count of messages that arrived below.
struct ScrollToBottomButton: View {
    let unread: Int
    let action: () -> Void

    static func label(_ unread: Int) -> String {
        unread > 0 ? "\(unread) new message\(unread == 1 ? "" : "s")" : "Scroll to bottom"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "arrow.down").font(DS.Typeface.iconSmall)
                Text(Self.label(unread)).font(DS.Typeface.caption).monospacedDigit()
            }
            .padding(.horizontal, DS.Space.s3).frame(height: DS.Size.controlHeight)
            .background(DS.Palette.window, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
            .dsShadow(DS.Elevation.popover)
            .contentShape(Capsule())
        }
        .buttonStyle(ScrollToBottomStyle())
        .accessibilityLabel(unread > 0 ? "Scroll to bottom, \(Self.label(unread))" : "Scroll to bottom")
        .help("Scroll to the latest message")
    }
}

private struct ScrollToBottomStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering ? DS.Palette.ink : DS.Palette.muted)
                .scaleEffect(configuration.isPressed ? DS.Motion.pressedScale : 1)
        }
    }
}

/// B5: message time and turn duration texts (Desktop `formatMessageTimestamp`, `formatElapsed`).
enum MessageTime {
    /// "3:27 PM" today, "Yesterday, 3:27 PM", else "Sep 28, 3:27 PM".
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock)"
        }
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day())
        return "\(day), \(clock)"
    }

    /// The tooltip: the full date and time.
    static func full(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .standard, locale: locale))
    }

    /// "12s", "2:05".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// VoiceOver: "12 seconds", "2 minutes 5 seconds".
    static func spokenElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let m = s / 60, r = s % 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if m == 0 { return unit(r, "second") }
        return r == 0 ? unit(m, "minute") : "\(unit(m, "minute")) \(unit(r, "second"))"
    }
}

/// B5: the turn duration under a finished reply ("12s"), muted caption with a timer symbol.
struct TurnDurationLabel: View {
    let seconds: TimeInterval
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: "timer").font(DS.Typeface.iconSmall)
            Text(MessageTime.elapsed(seconds)).font(DS.Typeface.caption).monospacedDigit()
        }
        .foregroundStyle(DS.Palette.muted)
        .help("Turn took \(MessageTime.elapsed(seconds))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Replied in \(MessageTime.spokenElapsed(seconds))")
    }
}
