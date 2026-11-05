import AppKit
import HermesGatewayKit
import SwiftUI
import UniformTypeIdentifiers

/// The Edit sheet (A8 + A9): avatar, title, description, then an Advanced disclosure with model and
/// provider first, skills, toolsets, MCP servers and SOUL. Presented by `motionSheet`, so it closes through
/// the model (`onClose`), not `\.dismiss`.
struct BotEditorView: View {
    @ObservedObject var model: BotEditorModel
    let identity: BotIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text("Edit \(model.bot.title)").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                Text("@\(model.bot.name)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            if model.advancedOpen {
                ScrollView { fields.padding(.trailing, DS.Space.s3) }
                    .frame(height: BotEditorLayout.scrollHeight)
            } else {
                fields
            }
            footer
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .disabled(model.saving)
        // The buttons answer; the binding's setter does nothing, so dismissing never races the chosen action.
        .alert("Use this model?", isPresented: Binding(get: { model.pendingConfirm != nil }, set: { _ in })) {
            Button("Use Model") { Task { await model.confirmModel() } }
            Button("Cancel", role: .cancel) { model.declineModel() }
        } message: {
            Text(model.pendingConfirm?.message ?? "")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            avatarRow
            labeled("Title", .title) {
                TextField("Title", text: $model.title, prompt: Text(model.bot.displayName ?? model.bot.name))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            labeled("Description", .description) {
                TextField("Description", text: $model.description, prompt: Text("What this bot is for"), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            Button { model.toggleAdvanced() } label: {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: model.advancedOpen ? "chevron.down" : "chevron.right").font(DS.Typeface.meta)
                    Text("Advanced: model, skills, toolsets, MCP, SOUL").font(DS.Typeface.metaStrong)
                }
                .foregroundStyle(DS.Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.advancedOpen ? "expanded" : "collapsed")
            if model.advancedOpen { BotAdvancedSection(model: model) }
        }
    }

    private var avatarRow: some View {
        HStack(spacing: DS.Space.s3) {
            preview
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Button("Choose Image…") { chooseImage() }.buttonStyle(DSButtonStyle(kind: .secondary))
                    if model.avatar != .unchanged {
                        Button("Undo") { model.keepAvatar() }.buttonStyle(DSButtonStyle(kind: .secondary))
                    } else if model.hadAvatar {
                        Button("Remove") { model.removeAvatar() }.buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
                Text("PNG or JPEG, up to 15 MB. Saved as a 256 px square.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                errorLine(.avatar)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous)
        if let image = model.avatarPreview {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: BotEditorLayout.preview, height: BotEditorLayout.preview).clipShape(shape)
                .accessibilityLabel("New avatar")
        } else if model.showsAvatarImage {
            AvatarView(identity: identity, size: BotEditorLayout.preview)
        } else {
            // The monogram the bot shows without an image (a profile key with no stored image).
            AvatarView(identity: BotIdentity(profile: "", title: identity.title, slot: identity.slot,
                                             uniqueMonogram: identity.monogram), size: BotEditorLayout.preview)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an avatar image for \(model.bot.title)"
        if panel.runModal() == .OK, let url = panel.url { model.pickAvatar(url) }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            if model.saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { model.cancel() }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
        }
    }

    private func labeled<C: View>(_ label: String, _ field: BotEditorModel.Field, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
            content()
            errorLine(field)
        }
    }

    @ViewBuilder func errorLine(_ field: BotEditorModel.Field) -> some View {
        BotEditorErrorLine(text: model.errors[field])
    }
}

enum BotEditorLayout {
    /// The avatar preview tile (the empty-state size step above the inspector's 36).
    static let preview: CGFloat = DS.Size.avatarEmpty
    /// The scrolling body while Advanced is open: header + body + footer stay inside the 520 pt window minimum.
    static let scrollHeight: CGFloat = 340
    static let listHeight: CGFloat = 150
    static let soulHeight: CGFloat = 160
}

/// One field's failure, in danger `meta`, selectable.
struct BotEditorErrorLine: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
