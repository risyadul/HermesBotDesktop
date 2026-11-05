import AppKit
import HermesGatewayKit
import SwiftUI
import UniformTypeIdentifiers

/// The Edit sheet (A8 + A9, A10 avatar picker): avatar, title, description, then an Advanced disclosure with model and
/// provider first, skills, toolsets, MCP servers and SOUL. Presented by `motionSheet`, so it closes through
/// the model (`onClose`), not `\.dismiss`.
///
/// The fields scroll between the pinned header and the pinned Cancel / Save row. The sheet is as tall as its
/// content, at most `maxHeight` (the parent window's height less a margin; `CappedHeightLayout`): a fixed
/// 340 pt body left the sheet 484 pt tall in any window, with skills, toolsets, MCP and SOUL out of reach (live
/// UI test 2026-11-06, round 2; BotEditorLayoutTests).
struct BotEditorView: View {
    @ObservedObject var model: BotEditorModel
    let identity: BotIdentity
    /// The tallest the sheet may be (`BotEditorLayout.sheetMaxHeight`); the minimum window's by default.
    var maxHeight: CGFloat = BotEditorLayout.sheetMaxHeight(windowHeight: DS.Size.windowMinHeight)

    var body: some View {
        CappedHeightLayout(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text("Edit \(model.bot.title)").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                    Text("@\(model.bot.name)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
                // Takes the height left between the header and the footer once the sheet is capped.
                ScrollView { fields.padding(.trailing, DS.Space.s3) }
                    .frame(maxHeight: .infinity, alignment: .top)
                footer
            }
            .padding(DS.Space.s5)
            .frame(width: DS.Size.sheetWidth, alignment: .top)
        }
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
                TextField("Title", text: $model.title, prompt: Text(model.titlePlaceholder))
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
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s3) {
                preview
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(spacing: DS.Space.s2) {
                        Button(model.avatarPickerOpen ? "Hide Avatars" : "Change Avatar…") { model.toggleAvatarPicker() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                        if model.avatar != .unchanged {
                            Button("Undo") { model.keepAvatar() }.buttonStyle(DSButtonStyle(kind: .secondary))
                        } else if model.hadAvatar {
                            Button("Remove") { model.removeAvatar() }.buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                    }
                    Text("A shape face, a picture, a generated image or a pet.")
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    errorLine(.avatar)
                }
            }
            if model.avatarPickerOpen {
                BotAvatarPickerView(picker: model.picker, staged: model.avatar, chooseImage: chooseImage)
            }
        }
    }

    private var preview: some View {
        BotAvatarPreview(staged: model.avatar, identity: identity, hasCurrentImage: model.hadAvatar, faceName: model.bot.name)
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
    /// The sheet keeps this much of its parent window's height free (the sheet hangs below the toolbar).
    static let windowMargin: CGFloat = 80
    /// The sheet's height limit in a window `windowHeight` tall: the window less `windowMargin`.
    static func sheetMaxHeight(windowHeight: CGFloat) -> CGFloat {
        max(windowHeight, DS.Size.windowMinHeight) - windowMargin
    }
    static let listHeight: CGFloat = 150
    static let soulHeight: CGFloat = 160
}

/// The bot sheets' height: their content's own height, capped at `maxHeight` (the parent window less its
/// margin), where the fields' scroll view takes what is left between the pinned header and footer. A fixed
/// sheet height left a large gap above Cancel / Create while Advanced was collapsed (live UI test 2026-11-06,
/// round 5); a sheet window only grows to a size its content requires, so the cap is a layout, not a
/// `maxHeight` frame.
struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        // A vertical scroll view proposed no height reports its content's height: the sheet's natural height.
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
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
