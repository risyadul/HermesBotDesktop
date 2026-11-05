import AppKit
import HermesGatewayKit
import SwiftUI

/// Native inspector: identity header (name, @handle, a "Default profile" tag when it is the default),
/// then About / Model / Provider / Skills. The handle already names the profile, so there is no separate
/// Profile field repeating it.
struct BotInspector: View {
    let bot: Bot
    let identity: BotIdentity
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                HStack(alignment: .top, spacing: DS.Space.s3) {
                    AvatarView(identity: identity, size: DS.Size.avatarInspector)
                    VStack(alignment: .leading, spacing: DS.Space.s0) {
                        Text(bot.title).font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink).lineLimit(1)
                        Text("@\(bot.name)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                        if bot.isDefault { DefaultTag(text: "Default profile").padding(.top, DS.Space.s0) }
                    }
                }
                Hairline()
                if let d = bot.description, !d.isEmpty { field("About", d) }
                field("Model", bot.model ?? "Not set in profile")
                if let p = bot.provider { field("Provider", p) }
                if let n = bot.skillCount { field("Skills", "\(n)") }
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s0) {
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            Text(value).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small neutral tag for the default profile (sidebar row, inspector).
struct DefaultTag: View {
    var text = "default"
    var body: some View {
        Text(text).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            .padding(.horizontal, DS.Space.s1 + DS.Space.s0 / 2).padding(.vertical, DS.Space.s0 / 2)
            .background(DS.Palette.selected, in: RoundedRectangle(cornerRadius: DS.Radius.inline, style: .continuous))
    }
}
