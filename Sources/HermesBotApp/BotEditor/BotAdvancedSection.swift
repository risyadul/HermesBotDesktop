import HermesGatewayKit
import SwiftUI

/// A9: the Advanced part of the Edit sheet, model and provider first (Desktop's `ModelPicker` over
/// `model.options`, with Inherit and free-text entry), then skills, toolsets and MCP servers from
/// `profiles.describe`, then the SOUL.
struct BotAdvancedSection: View {
    @ObservedObject var model: BotEditorModel

    var body: some View {
        switch model.advancedPhase {
        case .idle, .loading:
            HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Loading settings…").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                BotEditorErrorLine(text: "Could not load the settings: \(why)")
                Button("Try Again") { model.loadAdvanced() }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
        case .loaded:
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                modelSection
                skillsSection
                toolsetsSection
                mcpSection
                soulSection
            }
        }
    }

    // MARK: model

    private var modelSection: some View {
        section("Model", .model, trailing: model.loadingModels ? AnyView(ProgressView().controlSize(.mini)) : nil) {
            if model.usesFreeTextModel {
                HStack(spacing: DS.Space.s2) {
                    TextField("Provider", text: $model.provider, prompt: Text("Provider"))
                    TextField("Model", text: $model.model, prompt: Text("Model"))
                }
                .textFieldStyle(.roundedBorder)
                if !model.providers.isEmpty {
                    Button("Choose from the list") { model.manualModelEntry = false }
                        .buttonStyle(.link).font(DS.Typeface.meta)
                }
                Text("Leave both empty to inherit the model of the main Hermes profile.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            } else {
                Picker("Provider", selection: Binding(get: { model.providerTag }, set: { model.chooseProvider($0) })) {
                    Text("Inherit from main profile").tag(BotEditorModel.inheritTag)
                    ForEach(model.providers) { p in Text(p.label).tag(p.slug) }
                    Text("Enter manually…").tag(BotEditorModel.manualTag)
                }
                if let active = model.activeProvider, !active.models.isEmpty {
                    Picker("Model", selection: $model.model) {
                        if model.model.isEmpty { Text("Choose a model").tag("") }
                        ForEach(active.models, id: \.self) { Text($0).tag($0) }
                        if !model.model.isEmpty && !active.models.contains(model.model) { Text(model.model).tag(model.model) }
                    }
                } else if model.activeProvider != nil {
                    TextField("Model", text: $model.model, prompt: Text("Model name")).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: capabilities

    private var skillsSection: some View {
        let on = model.skills.filter(\.enabled).count
        return section("Skills (\(on) of \(model.skills.count) on)", .skills) {
            if model.skills.isEmpty {
                empty("No skills installed.")
            } else {
                TextField("Filter skills", text: $model.skillFilter, prompt: Text("Filter skills")).textFieldStyle(.roundedBorder)
                box {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: DS.Space.s1) {
                        ForEach(model.visibleSkills) { s in
                            toggle(s.name, help: s.name, isOn: Binding(get: { s.enabled }, set: { model.setSkill(s.name, $0) }))
                        }
                    }
                }
            }
        }
    }

    private var toolsetsSection: some View {
        let on = model.toolsets.filter(\.enabled).count
        return section("Toolsets (\(on) of \(model.toolsets.count) on)", .toolsets) {
            if model.toolsets.isEmpty {
                empty("No toolsets to configure.")
            } else {
                box {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        ForEach(model.toolsets) { t in
                            let count = t.toolCount.map { " · \($0) tools" } ?? ""
                            toggle((t.label?.isEmpty == false ? t.label! : t.name) + count, help: t.detail ?? t.name,
                                   isOn: Binding(get: { t.enabled }, set: { model.setToolset(t.name, $0) }))
                        }
                    }
                }
            }
        }
    }

    private var mcpSection: some View {
        section("MCP servers", .mcp) {
            if model.mcpServers.isEmpty {
                empty("No MCP servers configured for this bot.")
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(model.mcpServers) { m in
                        toggle(m.name + (m.detail.map { " · \($0)" } ?? ""), help: m.name,
                               isOn: Binding(get: { m.enabled }, set: { model.setMcp(m.name, $0) }))
                    }
                }
            }
        }
    }

    // MARK: SOUL

    private var soulSection: some View {
        section("SOUL", .soul) {
            TextEditor(text: $model.soul)
                .font(DS.Typeface.code)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s1)
                .frame(height: BotEditorLayout.soulHeight)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                .accessibilityLabel("SOUL")
            Text("The section that lets this bot message other bots is kept when you save.")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
    }

    // MARK: parts

    private func section<C: View>(_ title: String, _ field: BotEditorModel.Field, trailing: AnyView? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Text(title).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                if let trailing { trailing }
            }
            content()
            BotEditorErrorLine(text: model.errors[field])
        }
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { content().padding(DS.Space.s2).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(height: BotEditorLayout.listHeight)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func toggle(_ label: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).lineLimit(1).truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .help(help)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
    }
}
