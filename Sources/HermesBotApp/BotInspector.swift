import AppKit
import HermesGatewayKit
import SwiftUI

/// Native inspector: identity header (name, @handle, a "Default profile" tag when it is the default),
/// with a menu for Edit… / Duplicate / Delete… (A8, A11, A12), then About / Model / Provider / Skills.
/// The handle already names the profile, so there is no separate Profile field repeating it.
struct BotInspector: View {
    let bot: Bot
    let identity: BotIdentity
    /// The app model the Edit / Duplicate / Delete actions go to (the one `RootView` shows).
    @ObservedObject var app: AppModel = .shared
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
                    Spacer(minLength: 0)
                    actions
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

    /// Edit…, Duplicate and Delete… in one header menu: a separate button row pushed the last field out of
    /// the inspector at the 520 pt minimum window height (InspectorLayoutTests).
    private var actions: some View {
        Menu {
            Button("Edit…") { app.editBot(bot.name) }
            Button("Duplicate") { app.duplicateBot(bot.name) }
            if BotDeleteModel.canDelete(bot) {
                Divider()
                Button("Delete…", role: .destructive) { app.deleteBot(bot.name) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(app.backend == nil || app.botSheet != nil)
        .help("Edit, duplicate or delete this bot")
        .accessibilityLabel("Bot actions for \(bot.title)")
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
