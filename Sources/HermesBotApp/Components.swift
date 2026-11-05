import AppKit
import HermesGatewayKit
import SwiftUI

// Shared components from DESIGN.md "Components": buttons, empty state, round divider, working dots,
// status dot, composer box. The message body (markdown + fenced code) is in MessageBody.swift.

// MARK: - buttons

enum DSButtonKind { case primary, secondary, danger }

/// `button-primary` / `button-secondary` / `button-danger`. Hover tint, pressed scale 0.96. Disabled is a
/// designed state (soft fill, muted label), not a fade, so it stays legible in both modes. Primary and
/// danger share weight and minimum width: a destructive choice is never visually smaller than its
/// alternative.
struct DSButtonStyle: ButtonStyle {
    var kind: DSButtonKind = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motionEnabled) private var motion

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            let hover = hovering && isEnabled
            configuration.label
                .font(kind == .secondary ? DS.Typeface.body : DS.Typeface.bodyStrong)
                .foregroundStyle(foreground)
                .padding(.horizontal, DS.Space.s3)
                .frame(minWidth: kind == .secondary ? nil : DS.Size.buttonMinWidth, minHeight: DS.Size.controlHeight)
                .background(background(hovering: hover), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay {
                    if let border {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(border, lineWidth: kind == .danger && isEnabled ? DS.Stroke.ring : DS.Stroke.hairline)
                    }
                }
                .scaleEffect(configuration.isPressed && isEnabled && motion ? DS.Motion.pressedScale : 1)
                .animation(motion ? DS.Motion.press : nil, value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }

    private var foreground: Color {
        guard isEnabled else { return DS.Palette.muted }
        switch kind {
        case .primary: return DS.Palette.onPrimary
        case .secondary: return DS.Palette.ink
        case .danger: return DS.Palette.danger
        }
    }

    private func background(hovering: Bool) -> Color {
        switch kind {
        case .primary:
            guard isEnabled else { return DS.Palette.primarySoft }
            return hovering ? DS.Palette.primaryHover : DS.Palette.primary
        case .secondary: return hovering ? DS.Palette.selected : DS.Palette.surface
        case .danger: return hovering ? DS.Palette.dangerSoft : DS.Palette.window
        }
    }

    private var border: Color? {
        switch kind {
        case .primary: return nil
        case .secondary: return DS.Palette.hairline
        case .danger: return isEnabled ? DS.Palette.dangerRing : DS.Palette.hairline
        }
    }
}

/// Icon-only toolbar/inline button: 28 pt hit area, hover tint, accessible label required.
struct IconButton: View {
    let symbol: String
    let label: String
    var pressed = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(DS.Typeface.icon)
                .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
        }
        .buttonStyle(IconButtonStyle(pressed: pressed))
        .accessibilityLabel(label)
        .help(label)
    }
}

struct IconButtonStyle: ButtonStyle {
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering || pressed ? DS.Palette.ink : DS.Palette.muted)
                .background((hovering && isEnabled) || pressed || configuration.isPressed ? DS.Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .opacity(isEnabled ? 1 : DS.Motion.disabledOpacity)
                .contentShape(Rectangle())
        }
    }
}

/// Tracks pointer hover for a style body.
struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: - structure

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(DS.Palette.hairline)
            .frame(width: vertical ? DS.Stroke.ring : nil, height: vertical ? nil : DS.Stroke.ring)
    }
}

/// `empty-state`: SF Symbol, heading, one sentence, optional actions.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            Image(systemName: symbol)
                .font(DS.Typeface.symbolEmpty)
                .foregroundStyle(DS.Palette.muted)
                .padding(.bottom, DS.Space.s1)
            Text(title).font(DS.Typeface.titleState).foregroundStyle(DS.Palette.ink)
            Text(message).font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: DS.Size.proseNarrow)
                .textSelection(.enabled)
            actions.padding(.top, DS.Space.s1)
        }
        .padding(DS.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// `round-divider`: hairline, caption, hairline. The two rules take equal flexible widths, so the label
/// sits on the centre of the timeline column. Drawn outward from the centre when it arrives live.
struct RoundDivider: View {
    let text: String
    var body: some View {
        HStack(spacing: DS.Space.s3) {
            Hairline().frame(minWidth: DS.Space.s4, maxWidth: .infinity)
            // Wraps instead of fixedSize: a long label must never widen the timeline past the pane, and
            // lineLimit bounds its height even when the pane is measured at a near-zero width
            // (the BotChatLayoutTests failure mode).
            Text(text).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                .multilineTextAlignment(.center).lineLimit(3).layoutPriority(1)
            Hairline().frame(minWidth: DS.Space.s4, maxWidth: .infinity)
        }
        .padding(.vertical, DS.Space.s1)
        .accessibilityElement(children: .combine)
    }
}

/// Insertion transition for a divider: both rules scale out from the label.
struct DrawFromCentre: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content.mask(Rectangle().scaleEffect(x: max(0.001, progress), anchor: .center)).opacity(progress < 0.05 ? 0 : 1)
    }
}

extension AnyTransition {
    static var drawFromCentre: AnyTransition {
        .modifier(active: DrawFromCentre(progress: 0), identity: DrawFromCentre(progress: 1))
    }
    /// New message: rises 10 pt from 0.97, anchored to the sender side.
    static func arrive(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .scale(scale: DS.Motion.arriveScale, anchor: anchor).combined(with: .offset(y: DS.Motion.arriveOffset)).combined(with: .opacity),
                    removal: .opacity)
    }
}

// MARK: - live indicators

/// Three dots pulsing in sequence while something works; static at mid opacity with motion off.
struct WorkingDots: View {
    var color: Color = DS.Palette.muted
    @Environment(\.motionEnabled) private var motion
    var body: some View {
        if motion {
            PhaseAnimator([0, 1, 2]) { phase in
                dots(active: phase)
            } animation: { _ in .easeInOut(duration: DS.Motion.dotsStep) }
        } else {
            dots(active: nil)
        }
    }

    private func dots(active: Int?) -> some View {
        HStack(spacing: DS.Size.workingDotGap) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color).frame(width: DS.Size.workingDot, height: DS.Size.workingDot)
                    .opacity(active == nil ? 0.6 : (active == i ? 1 : 0.3))
            }
        }
        .frame(height: DS.Size.caret.height)
        .accessibilityHidden(true)
    }
}

/// 7 pt dot; breathes while `live` (a round runs) when motion is on.
struct StatusDot: View {
    var color: Color = DS.Palette.primary
    var live = false
    @Environment(\.motionEnabled) private var motion
    var body: some View {
        Group {
            if live && motion {
                PhaseAnimator([false, true]) { small in
                    Circle().fill(color).scaleEffect(small ? 0.6 : 1).opacity(small ? 0.5 : 1)
                } animation: { _ in .easeInOut(duration: DS.Motion.breathe) }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
        .accessibilityHidden(true)
    }
}

// MARK: - composer

/// `composer`: surface box, graphite focus ring, primary Send. The send gate stays with the caller:
/// Return and the button both call `onSend`, which goes through the model's gate.
struct ComposerBox: View {
    let placeholder: String
    @Binding var draft: String
    let canSend: Bool
    let onSend: () -> Void
    var focus: FocusState<Bool>.Binding
    /// Tab while the field is focused: return true when handled (accepting a mention suggestion);
    /// otherwise Tab moves focus as usual.
    var onTab: (() -> Bool)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s2) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Typeface.body)
                .lineLimit(DS.Size.composerLines)
                .padding(.vertical, DS.Size.fieldInset)
                .focused(focus)
                .onSubmit(onSend)
                .onKeyPress(.tab) { onTab?() == true ? .handled : .ignored }
            Button("Send", action: onSend)
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, DS.Space.s3).padding(.trailing, DS.Space.s2).padding(.vertical, DS.Space.s2)
        .composerSurface(focused: focus.wrappedValue)
    }
}

extension View {
    /// `composer` surface: surface fill, hairline border that becomes the graphite focus ring.
    func composerSurface(focused: Bool) -> some View {
        background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(focused ? DS.Palette.ring : DS.Palette.hairline,
                                  lineWidth: focused ? DS.Stroke.focus : DS.Stroke.hairline)
            )
    }

    /// `action-card` chrome in the `attention` role (Group Chat approvals, Bot Chat request cards): padding,
    /// card width, attention fill and ring, card shadow. Callers add the content inset after their own
    /// backgrounds (the Group Chat ripple sits between).
    func attentionCard() -> some View {
        padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
            .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
            .background(DS.Palette.attentionSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.ring))
            .dsShadow(DS.Elevation.card)
    }
}

/// `kbd` hint in the composer hint row.
struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Text(keys).font(DS.Typeface.caption).foregroundStyle(DS.Palette.ink)
                .padding(.horizontal, DS.Space.s1).padding(.vertical, DS.Space.s0 / 2)
                .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.inline))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.inline).strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
    }
}

// MARK: - pane arrival

/// The incoming detail pane fades in from `DS.Motion.paneOffset` to the right, as an animation the pane runs
/// when it appears, not as a transition of the selection change: a transition would keep the outgoing pane
/// on screen until it finished. Each `.id` change creates a new pane, so the arrival runs once per switch.
struct PaneArrival: ViewModifier {
    let motion: Bool
    @State private var arrived = false

    /// Opacity and x offset before and after arriving; with motion off the pane is in place at once. It
    /// starts part-visible: from 0 every switch showed a frame of empty window, which read as a flicker
    /// when switching quickly.
    static let startOpacity = 0.4
    static func state(arrived: Bool, motion: Bool) -> (opacity: Double, offset: CGFloat) {
        arrived || !motion ? (1, 0) : (startOpacity, DS.Motion.paneOffset)
    }

    func body(content: Content) -> some View {
        let s = Self.state(arrived: arrived, motion: motion)
        content
            .opacity(s.opacity)
            .offset(x: s.offset)
            .onAppear {
                guard motion else { arrived = true; return }
                withAnimation(DS.Motion.pane) { arrived = true }
            }
    }
}

extension View {
    func paneArrival(motion: Bool) -> some View { modifier(PaneArrival(motion: motion)) }
}
