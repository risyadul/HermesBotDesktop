import HermesGatewayKit
import SwiftUI

// K6: AI actions on a card (Estimate, Decompose, Specify) and the per-card model override. One
// `KanbanCardAIModel` per board (`KanbanBoardModel.ai`); results are kept per card id, so switching cards
// while a slow call runs neither loses nor misplaces its answer. Reassign is the card's Assignee menu
// (`KanbanBoardModel.reassign`: `POST /tasks/{id}/reassign {reclaim_first: true}`).
//
// Decompose and Specify act on triage cards only and the server applies their result itself (no proposal
// comes back), so both are confirmed before they are sent. Estimate only reads.

enum KanbanAIAction: String, Equatable, CaseIterable {
    case estimate, decompose, specify

    var menuTitle: String {
        switch self {
        case .estimate: return "Estimate Effort"
        case .decompose: return "Decompose into Subtasks…"
        case .specify: return "Specify…"
        }
    }

    var buttonTitle: String {
        switch self {
        case .estimate: return "Estimate"
        case .decompose: return "Decompose…"
        case .specify: return "Specify…"
        }
    }

    var progress: String {
        switch self {
        case .estimate: return "Estimating…"
        case .decompose: return "Decomposing…"
        case .specify: return "Specifying…"
        }
    }

    var failure: String {
        switch self {
        case .estimate: return "Estimate"
        case .decompose: return "Decompose"
        case .specify: return "Specify"
        }
    }
}

/// Pure rules and words of the AI actions and the model override.
enum KanbanAIRules {
    static let triage = "triage"

    /// Estimate works on any card; Decompose and Specify only on a triage card (`_load_triage_task`).
    static func isAvailable(_ action: KanbanAIAction, status: String) -> Bool {
        action == .estimate || status == triage
    }

    static func help(_ action: KanbanAIAction, status: String) -> String {
        switch action {
        case .estimate:
            return "A rough token and complexity guess from Hermes' auxiliary model. Makes a model call; not a bill."
        case .decompose:
            return isAvailable(action, status: status)
                ? "Split this card into subtasks with Hermes' auxiliary model, assigned across your bots."
                : "Only triage cards can be decomposed."
        case .specify:
            return isAvailable(action, status: status)
                ? "Rewrite this card's title and description into a proper spec and move it to Todo."
                : "Only triage cards can be specified."
        }
    }

    static func confirmTitle(_ action: KanbanAIAction, card: String) -> String {
        switch action {
        case .estimate: return "Estimate “\(card)”?"
        case .decompose: return "Decompose “\(card)” into subtasks?"
        case .specify: return "Specify “\(card)”?"
        }
    }

    static func confirmMessage(_ action: KanbanAIAction) -> String {
        switch action {
        case .estimate: return ""
        case .decompose:
            return "Hermes' auxiliary model splits the card into new subtasks on this board and makes this card their parent. The subtasks are created at once; this can take a few minutes."
        case .specify:
            return "Hermes' auxiliary model rewrites the card's title and description and moves it from Triage to Todo. The current text is replaced; this can take a minute or two."
        }
    }

    static func confirmButton(_ action: KanbanAIAction) -> String {
        switch action {
        case .estimate: return "Estimate"
        case .decompose: return "Decompose"
        case .specify: return "Specify"
        }
    }

    /// 950, 1.2k, 120k, 1.5M (Desktop `compactNumber`).
    static func compact(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            let text = v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch max(0, n) {
        case ..<1000: return "\(max(0, n))"
        case ..<1_000_000: return short(Double(n) / 1000, "k")
        default: return short(Double(n) / 1_000_000, "M")
        }
    }

    static func complexity(_ c: String?) -> String? {
        switch c {
        case "S": return "Small"
        case "M": return "Medium"
        case "L": return "Large"
        default: return nil
        }
    }

    /// "~120k tokens · Medium".
    static func estimateText(_ e: KanbanEstimate) -> String {
        (["~\(compact(e.estTokens)) tokens"] + [complexity(e.complexity)].compactMap { $0 }).joined(separator: " · ")
    }

    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "": return "Profile default"
        case "none": return "Thinking off"
        case "xhigh": return "Extra high"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// The model field's title: "Profile default", "openrouter: model-a · High", "Profile default · Low".
    static func overrideLabel(_ o: KanbanModelOverride) -> String {
        if o.isInherited { return "Profile default" }
        let model = o.model.trimmingCharacters(in: .whitespaces), provider = o.provider.trimmingCharacters(in: .whitespaces)
        let base = model.isEmpty ? "Profile default" : (provider.isEmpty ? model : "\(provider): \(model)")
        let effort = o.effort.trimmingCharacters(in: .whitespaces)
        return effort.isEmpty ? base : "\(base) · \(effortLabel(effort))"
    }

    /// A model typed by hand: `provider/model` is not split (model ids contain `/`); only the model is set.
    static func typedOverride(_ text: String, keeping current: KanbanModelOverride) -> KanbanModelOverride? {
        let model = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return KanbanModelOverride(model: model, provider: "", effort: current.effort)
    }
}

@MainActor
final class KanbanCardAIModel: ObservableObject {
    /// The last finished (or refused) action of a card, in plain words.
    struct Outcome: Equatable {
        let action: KanbanAIAction
        let ok: Bool
        let text: String
        /// Decompose: the subtasks created.
        var childIds: [String] = []
    }

    /// A Decompose or Specify waiting for the user's yes.
    struct Confirmation: Equatable, Identifiable {
        let taskId: String
        let card: String
        let action: KanbanAIAction
        var id: String { "\(action.rawValue).\(taskId)" }
    }

    @Published private(set) var running: [String: KanbanAIAction] = [:]
    @Published private(set) var estimates: [String: KanbanEstimate] = [:]
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published var confirmation: Confirmation?
    @Published private(set) var modelOptions: [KanbanModelProvider] = []
    @Published private(set) var modelOptionsLoaded = false
    @Published private(set) var modelSaving: Set<String> = []
    @Published private(set) var modelErrors: [String: String] = [:]

    private weak var board: KanbanBoardModel?

    init(board: KanbanBoardModel) { self.board = board }

    func isRunning(_ taskId: String) -> Bool { running[taskId] != nil }
    func dismissOutcome(_ taskId: String) { outcomes[taskId] = nil }

    private func card(_ taskId: String) -> KanbanTask? {
        guard let b = board else { return nil }
        return b.task(taskId) ?? (b.detail?.task.id == taskId ? b.detail?.task : nil)
    }

    /// The menu / button entry point: Estimate runs at once, Decompose and Specify ask first.
    func request(_ action: KanbanAIAction, taskId: String) {
        guard let t = card(taskId), running[taskId] == nil else { return }
        if action == .estimate {
            Task { await run(.estimate, taskId: taskId) }
        } else if KanbanAIRules.isAvailable(action, status: t.status) {
            confirmation = Confirmation(taskId: taskId, card: t.title.isEmpty ? t.id : t.title, action: action)
        } else {
            outcomes[taskId] = Outcome(action: action, ok: false, text: KanbanAIRules.help(action, status: t.status))
        }
    }

    /// The user said yes to `confirmation`.
    func confirm() {
        guard let c = confirmation else { return }
        confirmation = nil
        Task { await run(c.action, taskId: c.taskId) }
    }

    /// Sends one action for a card and keeps its answer. One action per card at a time.
    func run(_ action: KanbanAIAction, taskId: String) async {
        guard let b = board, let t = card(taskId), running[taskId] == nil else { return }
        guard b.state != .gone else {
            outcomes[taskId] = Outcome(action: action, ok: false, text: "\(action.failure) failed: \(KanbanBoardModel.goneMessage)")
            return
        }
        guard KanbanAIRules.isAvailable(action, status: t.status) else {
            outcomes[taskId] = Outcome(action: action, ok: false, text: KanbanAIRules.help(action, status: t.status))
            return
        }
        running[taskId] = action
        outcomes[taskId] = nil
        defer { running[taskId] = nil }
        let api = b.api, slug = b.slug, author = KanbanAPI.commentAuthor
        do {
            switch action {
            case .estimate:
                let e = try await api.estimate(taskId: taskId, board: slug)
                if e.ok {
                    estimates[taskId] = e
                } else {
                    outcomes[taskId] = Outcome(action: action, ok: false, text: "Couldn't estimate: \(e.reason ?? "no estimate came back")")
                }
            case .decompose:
                let r = try await api.decompose(taskId: taskId, board: slug, author: author)
                outcomes[taskId] = Self.outcome(r)
                if r.ok { await reload(b, taskId) }
            case .specify:
                let r = try await api.specify(taskId: taskId, board: slug, author: author)
                outcomes[taskId] = r.ok
                    ? Outcome(action: action, ok: true, text: r.newTitle.map { "Specified as “\($0)” and moved to Todo." } ?? "Specified and moved to Todo.")
                    : Outcome(action: action, ok: false, text: "Couldn't specify: \(r.reason ?? "no reason given")")
                if r.ok { await reload(b, taskId) }
            }
        } catch {
            outcomes[taskId] = Outcome(action: action, ok: false, text: "\(action.failure) failed: \(KanbanBoardModel.describe(error))")
            if KanbanBoardModel.isBoardGone(error) { await b.refresh() }
        }
    }

    static func outcome(_ r: KanbanDecomposeResult) -> Outcome {
        guard r.ok else { return Outcome(action: .decompose, ok: false, text: "Couldn't decompose: \(r.reason ?? "no reason given")") }
        guard r.fanout, !r.childIds.isEmpty else {
            return Outcome(action: .decompose, ok: true,
                           text: r.newTitle.map { "Kept as one task: “\($0)”." } ?? "Kept as one task; no subtasks were needed.")
        }
        let n = r.childIds.count
        return Outcome(action: .decompose, ok: true, text: n == 1 ? "Created 1 subtask:" : "Created \(n) subtasks:", childIds: r.childIds)
    }

    /// The board and the open card's details after the server changed cards.
    private func reload(_ b: KanbanBoardModel, _ taskId: String) async {
        await b.refresh()
        if b.selectedTaskId == taskId { await b.loadDetail() }
    }

    // MARK: model override

    /// `GET /model-options`, once per board model (an empty catalog still offers a typed model).
    func loadModelOptions() async {
        guard !modelOptionsLoaded, let api = board?.api else { return }
        modelOptions = (try? await api.modelOptions()) ?? []
        modelOptionsLoaded = true
    }

    /// PATCHes the card's override; the answered card shows at once. False (with `modelErrors`) on failure.
    @discardableResult
    func setModelOverride(_ taskId: String, _ override: KanbanModelOverride) async -> Bool {
        guard let b = board, !modelSaving.contains(taskId) else { return false }
        guard b.state != .gone else {
            modelErrors[taskId] = "Model not changed: \(KanbanBoardModel.goneMessage)"
            return false
        }
        modelSaving.insert(taskId)
        defer { modelSaving.remove(taskId) }
        do {
            if let t = try await b.api.setModelOverride(taskId, override, board: b.slug) { b.adopt(t) } else { await b.refresh() }
            modelErrors[taskId] = nil
            if b.selectedTaskId == taskId { await b.loadDetail() }
            return true
        } catch {
            modelErrors[taskId] = "Model not changed: \(KanbanBoardModel.describe(error))"
            return false
        }
    }
}

// MARK: - views

/// The inspector's "AI actions" section: the three buttons, progress, the estimate and the last outcome
/// (Decompose lists the subtasks it created; each opens).
struct KanbanAISection: View {
    @ObservedObject var ai: KanbanCardAIModel
    let task: KanbanTask
    let onOpenTask: (String) -> Void
    let title: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1 + DS.Space.s0) {
            Text("AI actions").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s2) { buttons }
                VStack(alignment: .leading, spacing: DS.Space.s1) { buttons }
            }
            if let action = ai.running[task.id] {
                HStack(spacing: DS.Space.s1) {
                    ProgressView().controlSize(.mini)
                    Text(action.progress).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
            }
            if let e = ai.estimates[task.id] {
                VStack(alignment: .leading, spacing: DS.Space.s0) {
                    Text(KanbanAIRules.estimateText(e)).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                    if let why = e.rationale {
                        Text(why).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(["Rough guess, not a bill", e.model].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
                .textSelection(.enabled)
            }
            if let o = ai.outcomes[task.id] { outcome(o) }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(KanbanAIAction.allCases, id: \.self) { action in
            Button(action.buttonTitle) { ai.request(action, taskId: task.id) }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .disabled(ai.isRunning(task.id) || !KanbanAIRules.isAvailable(action, status: task.status))
                .help(KanbanAIRules.help(action, status: task.status))
        }
    }

    private func outcome(_ o: KanbanCardAIModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .top, spacing: DS.Space.s1) {
                Label(o.text, systemImage: o.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(o.ok ? DS.Palette.muted : DS.Palette.danger)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Dismiss") { ai.dismissOutcome(task.id) }
            }
            ForEach(o.childIds, id: \.self) { id in
                Button { onOpenTask(id) } label: {
                    Text(title(id)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.link).lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Open \(id)")
            }
        }
    }
}

/// The inspector's Model field: Profile default, the providers' models, a typed model, and the reasoning
/// effort. Each choice is saved at once (Desktop's drawer PATCHes on change).
struct KanbanModelMenu: View {
    @ObservedObject var ai: KanbanCardAIModel
    let task: KanbanTask
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        let current = task.modelOverride
        VStack(alignment: .leading, spacing: DS.Space.s0) {
            HStack(spacing: DS.Space.s1) {
                Menu(KanbanAIRules.overrideLabel(current)) {
                    Button { save(.inherit) } label: {
                        if current.isInherited { Label("Profile Default", systemImage: "checkmark") } else { Text("Profile Default") }
                    }
                    Divider()
                    ForEach(ai.modelOptions) { provider in
                        Menu(provider.label) {
                            ForEach(provider.models, id: \.self) { m in
                                Button {
                                    save(KanbanModelOverride(model: m, provider: provider.slug, effort: current.effort))
                                } label: {
                                    if current.model == m && current.provider == provider.slug { Label(m, systemImage: "checkmark") } else { Text(m) }
                                }
                            }
                        }
                    }
                    Button("Other Model…") { typed = current.model; typing = true }
                    Divider()
                    Menu("Reasoning") {
                        ForEach([""] + KanbanModelOverride.efforts, id: \.self) { effort in
                            Button {
                                save(KanbanModelOverride(model: current.model, provider: current.provider, effort: effort))
                            } label: {
                                let text = KanbanAIRules.effortLabel(effort)
                                if current.effort == effort { Label(text, systemImage: "checkmark") } else { Text(text) }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(ai.modelSaving.contains(task.id))
                .help("The model and reasoning effort this card's worker runs with. Profile default uses the assigned bot's own.")
                if ai.modelSaving.contains(task.id) { ProgressView().controlSize(.mini) }
            }
            if let e = ai.modelErrors[task.id] {
                Text(e).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await ai.loadModelOptions() }
        .alert("Model for this card", isPresented: $typing) {
            TextField("Model name", text: $typed)
            Button("Set") {
                if let o = KanbanAIRules.typedOverride(typed, keeping: current) { save(o) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model id as Hermes knows it. The assigned bot's provider is used.")
        }
    }

    private func save(_ o: KanbanModelOverride) {
        guard o != task.modelOverride else { return }
        Task { await ai.setModelOverride(task.id, o) }
    }
}

/// Card context menu entries for the AI actions; the card opens so the answer shows in its details.
struct KanbanAIMenuItems: View {
    let task: KanbanTask
    let ai: KanbanCardAIModel
    var onOpen: (() -> Void)?

    var body: some View {
        ForEach(KanbanAIAction.allCases, id: \.self) { action in
            Button(action.menuTitle) {
                onOpen?()
                ai.request(action, taskId: task.id)
            }
            .disabled(!KanbanAIRules.isAvailable(action, status: task.status))
        }
    }
}

/// Asks before Decompose / Specify (attached to the board pane, so it works from the menu and the inspector).
struct KanbanAIConfirmation: ViewModifier {
    @ObservedObject var ai: KanbanCardAIModel

    func body(content: Content) -> some View {
        content.confirmationDialog(ai.confirmation.map { KanbanAIRules.confirmTitle($0.action, card: $0.card) } ?? "",
                                   isPresented: Binding(get: { ai.confirmation != nil }, set: { if !$0 { ai.confirmation = nil } })) {
            if let c = ai.confirmation {
                Button(KanbanAIRules.confirmButton(c.action)) { ai.confirm() }
            }
        } message: {
            Text(ai.confirmation.map { KanbanAIRules.confirmMessage($0.action) } ?? "")
        }
    }
}
