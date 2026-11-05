import HermesGatewayKit
import SwiftUI

/// A4: a static graphite dot, the bot has activity the user has not opened (a breathing dot means a reply
/// runs).
struct UnreadDot: View {
    var body: some View {
        ZStack { StatusDot(color: DS.Palette.primary) }
            .help("New activity")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New activity")
    }
}

/// A6: the "needs attention" badge, an attention-role warning symbol; the tooltip says what to do.
struct BotAttentionBadge: View {
    let attention: BotAttention

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.attention)
            .help(attention.reason.hint)
            .accessibilityLabel("Needs attention: \(attention.reason.hint)")
    }
}

/// A4 row text.
enum BotRowText {
    /// The preview line: a bot-to-bot message is prefixed with its sender's @handle.
    static func preview(_ p: BotPreview) -> String {
        p.fromBot.map { "@\($0): \(p.text)" } ?? p.text
    }
}
