import AppKit
import HermesGatewayKit
import SwiftUI

/// A7 sheet: the fields scroll between the pinned header and the Cancel / Create row. The sheet is as tall as
/// its content, at most `maxHeight` (`CappedHeightLayout`, `BotEditorLayout.sheetMaxHeight`); after a create
/// with something to report it shows the result.
struct BotCreateView: View {
    @ObservedObject var model: BotCreateModel
    var maxHeight: CGFloat = BotEditorLayout.sheetMaxHeight(windowHeight: DS.Size.windowMinHeight)
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        CappedHeightLayout(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text("New Bot").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                    Text("A named teammate with its own memory, skills and chat. It can message your other bots.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if case .created(let outcome) = model.phase {
                    result(outcome)
                    Spacer(minLength: 0)
                    resultFooter(outcome)
                } else {
                    ScrollView { fields.padding(.trailing, DS.Space.s3) }
                        .frame(maxHeight: .infinity, alignment: .top)
                    footer
                }
            }
            .padding(DS.Space.s5)
            .frame(width: DS.Size.sheetWidth, alignment: .top)
        }
        .background(DS.Palette.window)
    }

    // MARK: fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            avatarRow
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                TextField("Name", text: $model.name, prompt: Text("inbox-triage")).textFieldStyle(.roundedBorder).labelsHidden()
                if let problem = model.nameProblem {
                    BotEditorErrorLine(text: problem)
                } else if !model.slug.isEmpty {
                    Text("Profile name: @\(model.slug)").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                } else {
                    Text("Becomes the profile name and the bot's @handle.").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            labeled("Title") {
                TextField("Title", text: $model.title, prompt: Text("Inbox Triage")).textFieldStyle(.roundedBorder).labelsHidden()
            }
            labeled("Description") {
                TextField("Description", text: $model.description, prompt: Text("What this bot is for"), axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).labelsHidden()
            }
            Toggle("Say hello when its Bot Chat opens", isOn: $model.sayHello)
                .toggleStyle(.checkbox).font(DS.Typeface.meta)
                .help("Sends “\(BotCreate.kickoff)” so the bot introduces itself.")
            Button { model.toggleAdvanced() } label: {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: model.advancedOpen ? "chevron.down" : "chevron.right").font(DS.Typeface.meta)
                    Text("Advanced: clone from, model, SOUL, keys, skills").font(DS.Typeface.metaStrong)
                }
                .foregroundStyle(DS.Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.advancedOpen ? "expanded" : "collapsed")
            if model.advancedOpen { advanced }
        }
        .disabled(model.isWorking)
    }

    private var avatarRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s3) {
                BotAvatarPreview(staged: model.effectiveAvatar,
                                 identity: avatars.identity(profile: model.slug, title: model.botTitle.isEmpty ? model.slug : model.botTitle),
                                 hasCurrentImage: false, faceName: model.slug.isEmpty ? "agent" : model.slug)
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(spacing: DS.Space.s2) {
                        Button(model.avatarPickerOpen ? "Hide Avatars" : "Change Avatar…") { model.toggleAvatarPicker() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                        if model.avatar != .unchanged {
                            Button("Reset") { model.resetAvatar() }.buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                    }
                    Text("A face in the name's colour unless you choose one.")
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    BotEditorErrorLine(text: model.avatarError)
                }
            }
            if model.avatarPickerOpen {
                BotAvatarPickerView(picker: model.picker, staged: model.effectiveAvatar, chooseImage: chooseImage)
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            labeled("Clone from") {
                Picker("Clone from", selection: Binding(get: { model.cloneFrom ?? BotCreateView.freshTag },
                                                        set: { model.cloneFrom = $0 == BotCreateView.freshTag ? nil : $0 })) {
                    Text("Fresh profile (bundled skills)").tag(BotCreateView.freshTag)
                    ForEach(model.cloneSources, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Text("A clone starts with that profile's settings, keys and skills; memory and chats start empty.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s2) {
                    Text("Model").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                    if model.loadingModels { ProgressView().controlSize(.mini) }
                }
                BotModelPicker(model: model)
            }
            labeled("SOUL (optional)") {
                TextEditor(text: $model.soul)
                    .font(DS.Typeface.code)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.s1)
                    .frame(height: BotCreateLayout.soulHeight)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                    .accessibilityLabel("SOUL")
                Text("Replaces the generated persona. The section that lets it message other bots is added.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Toggle("Share keys & accounts with the main profile", isOn: $model.shareKeys)
                    .toggleStyle(.checkbox).font(DS.Typeface.meta)
                Text("Subscriptions, OAuth logins and API keys stay shared (not copied), so token refreshes never invalidate each other. Uncheck for an isolated copy.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Space.s5)
                Toggle("Create empty (skip bundled skills)", isOn: $model.skipBundledSkills)
                    .toggleStyle(.checkbox).font(DS.Typeface.meta)
                    .disabled(model.cloneFrom != nil)
                    .help(model.cloneFrom != nil ? "Only for a fresh profile: a clone copies its source's skills." : "")
            }
        }
    }

    private static let freshTag = "\u{0}fresh"

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
            content()
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an avatar image for the new bot"
        if panel.runModal() == .OK, let url = panel.url { model.pickAvatar(url) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            BotEditorErrorLine(text: model.error)
            HStack(spacing: DS.Space.s2) {
                if case .working(let step) = model.phase {
                    ProgressView().controlSize(.small)
                    Text(step).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isWorking)
                Button(model.isWorking ? "Creating…" : "Create Bot") { Task { await model.create() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
        }
    }

    // MARK: result

    private func result(_ o: BotCreateModel.Outcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                Label("Created @\(o.name).", systemImage: "checkmark.circle").font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                if !o.path.isEmpty {
                    Text(o.path).font(DS.Typeface.code).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                }
                ForEach(o.warnings, id: \.self) { BotEditorErrorLine(text: $0) }
                if let reason = o.needsModel {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("No model provider is ready for it yet, so it will not introduce itself. Pick a provider and model with Set Up Model….")
                            .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink).fixedSize(horizontal: false, vertical: true)
                        if !reason.isEmpty {
                            Text(reason).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultFooter(_ o: BotCreateModel.Outcome) -> some View {
        HStack(spacing: DS.Space.s2) {
            Spacer()
            Button("Done") { model.onClose() }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            if o.needsModel != nil {
                Button("Set Up Model…") { model.editModel() }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
            Button("Open Bot Chat") { model.openCreated() }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}

enum BotCreateLayout {
    static let soulHeight: CGFloat = 120
}
