import HermesGatewayKit
import SwiftUI

/// A11 sheet: the step that runs, then the new bot (Open / Done) or the failure.
struct BotDuplicateView: View {
    @ObservedObject var model: BotDuplicateModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Duplicate \(model.source.title)").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            switch model.phase {
            case .running(let step):
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(step).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                }
                Text("The copy gets this bot's settings, skills, SOUL and memory, and its look.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            case .done(let result):
                Label("Created @\(result.name).", systemImage: "checkmark.circle")
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                if !result.path.isEmpty {
                    Text(result.path).font(DS.Typeface.code).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                }
                ForEach(result.warnings, id: \.self) { BotEditorErrorLine(text: $0) }
            case .failed(let why):
                BotEditorErrorLine(text: "Could not duplicate @\(model.source.name): \(why)")
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                if case .done(let result) = model.phase {
                    Button("Done") { model.onClose() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Open @\(result.name)") { model.onOpen(result.name) }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.isRunning ? "Working…" : "Close") { model.onClose() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isRunning)
                }
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .task { await model.start() }
    }
}

/// A12 sheet: a destructive confirmation that names the bot and its profile folder.
struct BotDeleteView: View {
    @ObservedObject var model: BotDeleteModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Delete \(model.bot.title)?").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text("This permanently deletes the bot @\(model.bot.name) and its Hermes profile, with its settings, skills, memory and chats:")
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).fixedSize(horizontal: false, vertical: true)
                Text(model.profilePath)
                    .font(DS.Typeface.code).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This cannot be undone.").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.danger)
            }
            BotEditorErrorLine(text: model.error.map { "Could not delete the bot: \($0)" })
            HStack(spacing: DS.Space.s2) {
                if model.deleting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.deleting)
                // No default (Return) shortcut: a destructive action is never one keypress away.
                Button(model.deleting ? "Deleting…" : "Delete Bot") { Task { await model.confirm() } }
                    .buttonStyle(DSButtonStyle(kind: .danger))
                    .disabled(model.deleting)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
    }
}

/// The bot sheet `RootView` presents (`AppModel.botSheet`).
struct BotSheetContent: View {
    let sheet: BotSheet?
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        switch sheet {
        case .edit(let m)?: BotEditorView(model: m, identity: avatars.identity(profile: m.bot.name, title: m.bot.title))
        case .duplicate(let m)?: BotDuplicateView(model: m)
        case .delete(let m)?: BotDeleteView(model: m)
        case nil: EmptyView()
        }
    }
}
