import AppKit
import SwiftUI

// Design tokens from DESIGN.md (repo root). Every colour, size, radius and curve used by the views comes
// from here; DESIGN.md is the source of truth and this file mirrors it one to one. Views never use a raw
// number or colour literal: a value with no token here is a design change and goes into DESIGN.md first.

enum DS {
    // MARK: colour

    enum Palette {
        static let primary = dynamic(light: 0x1D1D1F, dark: 0xF2F2F4)
        /// Primary button under the pointer: graphite at 86%.
        static let primaryHover = dynamic(light: (0x1D1D1F, 0.86), dark: (0xF2F2F4, 0.86))
        static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x1D1D1F)
        static let primarySoft = dynamic(light: 0xEEEEF0, dark: 0x34343A)
        static let window = dynamic(light: 0xFFFFFF, dark: 0x232326)
        static let surface = dynamic(light: 0xF7F6F3, dark: 0x2A2A2E)
        static let ink = dynamic(light: 0x1D1D1F, dark: 0xF2F2F4)
        static let muted = dynamic(light: 0x6B6B70, dark: 0xAEAEB5)
        static let danger = dynamic(light: 0xB3261E, dark: 0xF2B8B5)
        static let dangerSoft = dynamic(light: 0xFBE9E7, dark: 0x3B2422)
        /// "Waiting on you": approvals and retries only (DESIGN.md `attention`).
        static let attention = dynamic(light: 0x955A00, dark: 0xF0BE5E)
        static let attentionSoft = dynamic(light: 0xFDF3E1, dark: 0x3A2F1A)
        static let statusOK = Color(hex: 0x1C7A82)
        /// Translucent so they also read over the sidebar material (solid equivalents in DESIGN.md).
        static let hairline = dynamic(light: (0x000000, 0.09), dark: (0xFFFFFF, 0.10))
        static let hover = dynamic(light: (0x000000, 0.045), dark: (0xFFFFFF, 0.06))
        static let selected = dynamic(light: (0x000000, 0.075), dark: (0xFFFFFF, 0.10))
        /// Composer focus ring: graphite at 40%.
        static let ring = dynamic(light: (0x1D1D1F, 0.40), dark: (0xF2F2F4, 0.40))
        static let dangerRing = dynamic(light: (0xB3261E, 0.35), dark: (0xF2B8B5, 0.40))
        static let attentionRing = dynamic(light: (0x955A00, 0.45), dark: (0xF0BE5E, 0.50))
        /// Monogram letters on a bot-colour tile (every bot colour passes 5:1 with white).
        static let onBot = Color.white
        /// Shadow colours (DESIGN.md "Elevation & Depth").
        static let shadow = Color.black

        /// Bot identity colours (`bot-rose` … `bot-olive`), in slot order.
        static let bots: [UInt32] = [0xB0436A, 0xB3362F, 0x1C7A82, 0x8A5526, 0x3B7535, 0x2A6FA0, 0x6E4FA8, 0x6B6A1F]
        /// Avatar image backdrop: bot colour at 22% over the window.
        static let avatarTint: Double = 0.22
        /// Monogram gradient: base colour at the top, base mixed 14% with black at the bottom (never
        /// lighter than the base, so white letters keep ≥ 5:1 everywhere on the tile).
        static let monogramShade: CGFloat = 0.14
        /// Dark-mode member names: bot colour mixed 45% with white (≥ 5.5:1 on the dark window).
        static let nameLiftDark: CGFloat = 0.45
        /// `waiting` ribbon chip border: bot colour at 45%.
        static let waitingBorder: Double = 0.45

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            dynamic(light: (light, 1), dark: (dark, 1))
        }

        private static func dynamic(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let (hex, alpha) = isDark ? dark : light
                return NSColor(hex: hex, alpha: alpha)
            })
        }
    }

    // MARK: spacing, radius, size

    enum Space {
        static let s0: CGFloat = 2
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 24
        static let s6: CGFloat = 40
        /// Avatar → text gap in messages and rows; chip trailing padding.
        static let gutter: CGFloat = 10
        /// Gap between timeline items.
        static let timeline: CGFloat = 14
    }

    enum Radius {
        static let inline: CGFloat = 4
        static let control: CGFloat = 6
        static let chip: CGFloat = 8
        static let avatar: CGFloat = 8
        /// Avatar tiles of chip size and below (18-20 pt), where 8 would read as a circle.
        static let avatarSmall: CGFloat = 5
        static let card: CGFloat = 10
        static let bubble: CGFloat = 12
        static let sheet: CGFloat = 14
    }

    enum Size {
        /// `media-thumb` / `media-chip` (DESIGN.md Components): inline image bounds (aspect fit, never
        /// upscaled), file chip maximum width, and the decode size (2x the bounds, sharp on Retina).
        static let mediaThumb = CGSize(width: 320, height: 240)
        static let mediaChipMax: CGFloat = 320
        static let mediaDecodePixels: CGFloat = 640
        /// Approval / sudo command box: taller commands scroll inside it (indicator always visible).
        static let commandMaxHeight: CGFloat = 220
        static let sidebarWidth: CGFloat = 260
        static let sidebarMin: CGFloat = 220
        /// The sidebar column is the setting + 8 (measured, macOS 26). 272 + 8 + `detailMin` 540 fills the
        /// 820 pt minimum exactly, so a dragged sidebar never pushes the split past the window
        /// (SidebarLayoutTests).
        static let sidebarMax: CGFloat = 272
        static let detailMin: CGFloat = 540
        static let windowMinWidth: CGFloat = 820
        static let windowMinHeight: CGFloat = 520
        static let windowDefault = CGSize(width: 1120, height: 720)
        static let rowHeight: CGFloat = 44
        static let sectionHeader: CGFloat = 24
        static let controlHeight: CGFloat = 28
        static let buttonMinWidth: CGFloat = 72
        static let statusDot: CGFloat = 7
        static let workingDot: CGFloat = 5
        static let workingDotGap: CGFloat = 3
        static let caret = CGSize(width: 7, height: 14)

        // avatar sizes (DESIGN.md `avatar`)
        static let avatarPass: CGFloat = 18
        static let avatarChip: CGFloat = 20
        static let avatarSuggestion: CGFloat = 22
        static let avatarRow: CGFloat = 28
        static let avatarHero: CGFloat = 28
        static let avatarMessage: CGFloat = 32
        static let avatarInspector: CGFloat = 36
        static let avatarEmpty: CGFloat = 44
        /// Room stack: two 18 pt tiles, the second offset by 10 pt, inside the 28 pt row slot.
        static let stackTile: CGFloat = 18
        static let stackOffset: CGFloat = 10
        static let stackCutout: CGFloat = 1.5

        /// Left edge of message content: avatar column + gutter. Passes, status lines and cards align here.
        static var contentInset: CGFloat { avatarMessage + Space.gutter }

        static let memberWidth: CGFloat = 720
        static let userWidth: CGFloat = 520
        /// Minimum free space left of a user bubble.
        static let userBubbleInset: CGFloat = 80
        static let cardWidth: CGFloat = 560
        static let inspectorWidth: CGFloat = 240
        static let inspectorMin: CGFloat = 200
        /// The inspector split lays out at least sidebar column + 410 + inspector / 2 (measured, macOS 26),
        /// so at the 820 pt minimum with the widest sidebar column that still fits (280) the inspector may
        /// grow to 260 at most before it runs past the window edge (InspectorLayoutTests).
        static let inspectorMax: CGFloat = 260
        static let popoverWidth: CGFloat = 280
        static let sheetWidth: CGFloat = 460
        static let settingsWidth: CGFloat = 420
        /// Reading measure for empty-state sentences.
        static let proseNarrow: CGFloat = 380
        static let emptyRoomMinHeight: CGFloat = 280
        static let memberToggleHeight: CGFloat = 40
        /// Composer text field vertical inset so one line sits centred on the 28 pt Send button.
        static let fieldInset: CGFloat = 5
        static let composerLines = 1...6
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let ring: CGFloat = 1
        static let focus: CGFloat = 1.5
        static let keyboardFocus: CGFloat = 2
        static let selectedToggle: CGFloat = 1.5
    }

    // MARK: type

    enum Typeface {
        static let titlePane = Font.system(size: 15, weight: .semibold)
        static let titleState = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let meta = Font.system(size: 12)
        static let metaStrong = Font.system(size: 12, weight: .semibold)
        static let caption = Font.system(size: 11, weight: .medium)
        static let captionStrong = Font.system(size: 11, weight: .semibold)
        static let code = Font.system(size: 12, design: .monospaced)
        /// SF Symbols beside body text and in icon buttons.
        static let icon = Font.system(size: 13, weight: .medium)
        /// SF Symbols beside meta/caption text.
        static let iconSmall = Font.system(size: 11, weight: .semibold)
        /// Empty-state SF Symbol.
        static let symbolEmpty = Font.system(size: 28, weight: .regular)
        static func monogram(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
        /// Monogram letters scale with the tile (0.39 × size, never under 8 pt).
        static func monogramSize(for tile: CGFloat) -> CGFloat { max(8, tile * 0.39) }
        static let proseLineSpacing: CGFloat = 2
        static let codeLineSpacing: CGFloat = 3
    }

    // MARK: elevation

    struct Shadow { let opacity: Double; let radius: CGFloat; let y: CGFloat }

    enum Elevation {
        /// Action cards: the only timeline items waiting for the user.
        static let card = Shadow(opacity: 0.08, radius: 1, y: 1)
        /// Mention suggestions popover.
        static let popover = Shadow(opacity: 0.16, radius: 14, y: 6)
    }

    // MARK: motion

    enum Motion {
        /// Things that arrive (messages, cards, sheets, selection).
        static let spring = Animation.spring(response: 0.38, dampingFraction: 0.72)
        /// State changes.
        static let ease = Animation.easeOut(duration: 0.25)
        /// Control press feedback.
        static let press = Animation.easeOut(duration: 0.12)
        /// Popover growing from the caret.
        static let pop = Animation.spring(response: 0.18, dampingFraction: 0.8)
        /// Streaming text growth.
        static let stream = Animation.easeOut(duration: 0.22)
        static let pressedScale: CGFloat = 0.96
        static let disabledOpacity: Double = 0.45
        /// Arrival: rises this far from this scale.
        static let arriveOffset: CGFloat = 10
        static let arriveScale: CGFloat = 0.97
        static let paneOffset: CGFloat = 12
        /// Approval ring: one ripple, growing this far, starting after the card settled.
        static let ringGrow: CGFloat = 10
        static let ringDelay: Double = 0.45
        static let ringDuration: Double = 1.1
        /// Ring stroke opacity at the start of the ripple; it fades to 0 as it grows.
        static let ringOpacity: Double = 0.6
        static let chipBounce: CGFloat = 1.06
        static let dotsStep: Double = 0.4
        static let breathe: Double = 1.2
        static let caretBlink: Double = 0.5
        /// UserDefaults key of the in-app "Animate interface changes" setting (default on).
        static let settingKey = "hba.motion"
    }
}

// MARK: - motion gate

private struct MotionEnabledKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False when macOS Reduce Motion is on or the in-app setting is off. Every animation in the app
    /// goes through this.
    var motionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}

/// Resolves the motion gate once at the root: system Reduce Motion AND the in-app setting.
struct MotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DS.Motion.settingKey) private var setting = true
    func body(content: Content) -> some View {
        content.environment(\.motionEnabled, setting && !reduceMotion)
    }
}

extension View {
    /// `.animation(_:value:)` that is nil while motion is off.
    func dsAnimation<V: Equatable>(_ animation: Animation, value: V, enabled: Bool) -> some View {
        self.animation(enabled ? animation : nil, value: value)
    }

    /// Token shadow.
    func dsShadow(_ s: DS.Shadow) -> some View {
        shadow(color: DS.Palette.shadow.opacity(s.opacity), radius: s.radius, y: s.y)
    }
}

/// The approval ring ripple as a pure function of time, so the view can draw it frame by frame and
/// drop it the moment the motion gate closes (a scheduled `withAnimation` cannot be recalled).
enum ApprovalRipple {
    static var total: Double { DS.Motion.ringDelay + DS.Motion.ringDuration }

    /// Eased progress in 0 < p < 1 while the ripple runs; nil before its delay ends, after it finished,
    /// or whenever motion is off.
    static func progress(at now: Date, start: Date, motion: Bool) -> CGFloat? {
        guard motion else { return nil }
        let t = (now.timeIntervalSince(start) - DS.Motion.ringDelay) / DS.Motion.ringDuration
        guard t > 0, t < 1 else { return nil }
        return CGFloat(1 - pow(1 - t, 3))  // ease-out
    }
}

/// `withAnimation` that respects the motion gate.
@MainActor func withDSAnimation<R>(_ enabled: Bool, _ animation: Animation = DS.Motion.spring, _ body: () throws -> R) rethrows -> R {
    if enabled { return try withAnimation(animation, body) }
    var t = Transaction()
    t.disablesAnimations = true
    return try withTransaction(t, body)
}

// MARK: - hex helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }
}
