import HermesGatewayKit
import SwiftUI

/// A model that holds a provider / model pick over a `model.options` catalog: the Edit sheet (A9) and New Bot (A7)
/// share Desktop's `ModelPicker` rules through this.
@MainActor
protocol BotModelChoosing: ObservableObject {
    var provider: String { get set }
    var model: String { get set }
    /// The user chose free-text provider/model entry; nil = follow the catalog (Desktop's `manualEntry`).
    var manualModelEntry: Bool? { get set }
    var providers: [BotProfileAPI.ModelProvider] { get }
    var loadingModels: Bool { get }
}

enum BotModelTag {
    static let inherit = "\u{0}inherit"
    static let manual = "\u{0}manual"
}

extension BotModelChoosing {
    /// The catalog row matching the current provider (slug or alias), if any.
    var activeProvider: BotProfileAPI.ModelProvider? { providers.first { $0.matches(provider) } }

    private var trimmedProvider: String { provider.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Free-text entry when the user chose it, when there is no catalog, or when the provider is not in it.
    var usesFreeTextModel: Bool {
        if providers.isEmpty { return true }
        if let manualModelEntry { return manualModelEntry }
        return !(trimmedProvider.isEmpty || activeProvider != nil)
    }

    /// The provider menu's selection.
    var providerTag: String {
        if let p = activeProvider { return p.slug }
        return trimmedProvider.isEmpty ? BotModelTag.inherit : BotModelTag.manual
    }

    /// Desktop's provider `onValueChange`: Inherit clears both; a provider keeps the model when it offers it,
    /// else takes its first model.
    func chooseProvider(_ tag: String) {
        switch tag {
        case BotModelTag.inherit:
            provider = ""; model = ""
        case BotModelTag.manual:
            manualModelEntry = true
        default:
            guard let p = providers.first(where: { $0.slug == tag }) else { return }
            model = p.models.contains(model) ? model : (p.models.first ?? "")
            provider = p.slug
        }
    }
}

/// Desktop's `ModelPicker`: provider menu (Inherit, the catalog, Enter manually…), then the provider's models, or
/// two text fields when typing by hand.
struct BotModelPicker<M: BotModelChoosing>: View {
    @ObservedObject var model: M
    var inheritLabel = "Inherit from main profile"

    var body: some View {
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
                Text(inheritLabel).tag(BotModelTag.inherit)
                ForEach(model.providers) { p in Text(p.label).tag(p.slug) }
                Text("Enter manually…").tag(BotModelTag.manual)
            }
            .accessibilityLabel("Provider")
            if let active = model.activeProvider, !active.models.isEmpty {
                Picker("Model", selection: $model.model) {
                    if model.model.isEmpty { Text("Choose a model").tag("") }
                    ForEach(active.models, id: \.self) { Text($0).tag($0) }
                    if !model.model.isEmpty && !active.models.contains(model.model) { Text(model.model).tag(model.model) }
                }
                .accessibilityLabel("Model")
            } else if model.activeProvider != nil {
                TextField("Model", text: $model.model, prompt: Text("Model name")).textFieldStyle(.roundedBorder)
            }
        }
    }
}
