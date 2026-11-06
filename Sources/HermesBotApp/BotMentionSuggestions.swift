import HermesGatewayKit
import SwiftUI

/// B1: the Bot Chat composer's @ suggestions, styled like Group Chat's `MentionSuggestions`: roster bots
/// (never the bot this chat is with), avatar, title and the tag that will be inserted. Click, or Tab for the
/// first match, replaces the trailing `@query` with `@tag `. Only edits the draft.
struct BotMentionSuggestions: View {
    let matches: [Bot]
    let candidates: [Bot]
    let pick: (Bot) -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { i, bot in
                Button { pick(bot) } label: {
                    HStack(spacing: DS.Space.s2) {
                        AvatarView(identity: avatars.identity(profile: bot.name, title: bot.title), size: DS.Size.avatarSuggestion)
                        Text(bot.title).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).lineLimit(1)
                        Spacer(minLength: DS.Space.s3)
                        Text("@\(BotMentionCompletion.insertion(bot, candidates: candidates))")
                            .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                    }
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Size.fieldInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SuggestionRowStyle(highlighted: i == 0))
                .accessibilityLabel("Mention \(bot.title)")
            }
        }
        .padding(DS.Space.s1)
        .frame(width: DS.Size.popoverWidth)
        .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
        .dsShadow(DS.Elevation.popover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention suggestions")
    }
}
