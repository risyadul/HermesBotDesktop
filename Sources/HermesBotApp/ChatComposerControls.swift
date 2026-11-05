import HermesGatewayKit
import SwiftUI

/// The Bot Chat composer's control row (left of the status row): model, reasoning effort, context gauge.
/// Each is a quiet caption-size control that tints on hover; the menus list what `model.options` reports.
struct ComposerControls: View {
    @ObservedObject var chat: ChatModel
    /// Narrow row: the effort menu shows its symbol only (the level stays in its tooltip).
    var compact = false

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            ModelMenu(chat: chat)
            if chat.showsReasoning { ReasoningMenu(chat: chat, compact: compact) }
            if let mode = chat.approvalMode { ApprovalModeMenu(chat: chat, mode: mode, compact: compact) }
            if let usage = chat.contextUsage { ContextGauge(chat: chat, usage: usage) }
        }
        .disabled(!chat.canChangeControls)
        // The controls keep their width before the busy text; only the model name truncates.
        .layoutPriority(1)
    }
}

/// The plain look of the composer controls: caption text, muted, hover tint (`IconButtonStyle` grammar).
struct ComposerControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(DS.Typeface.caption)
                .foregroundStyle(hovering && isEnabled ? DS.Palette.ink : DS.Palette.muted)
                .padding(.horizontal, DS.Space.s1).padding(.vertical, DS.Space.s0)
                .background((hovering && isEnabled) || configuration.isPressed ? DS.Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
    }
}

/// Text plus a small chevron, the label of a composer menu.
private struct MenuLabel: View {
    let symbol: String?
    let text: String
    var showsText = true
    /// The model name may truncate (middle) when the row is narrow; the effort label never does.
    var compressible = false
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if let symbol { Image(systemName: symbol).font(DS.Typeface.iconSmall) }
            if compressible {
                Text(text).lineLimit(1).truncationMode(.middle)
            } else if showsText {
                Text(text).lineLimit(1).fixedSize()
            }
            Image(systemName: "chevron.down").font(DS.Typeface.iconSmall).imageScale(.small)
        }
        .frame(maxWidth: compressible ? DS.Size.controlLabelMax : nil)
    }
}

/// B7: the chat's model. Picking one switches THIS chat only (`config.set model … --session`).
struct ModelMenu: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        Menu {
            let providers = chat.modelCatalog?.providers ?? []
            if providers.isEmpty {
                Text(chat.modelCatalog == nil ? "Loading models…" : "No models available")
            }
            ForEach(providers) { p in
                Section(p.name) {
                    ForEach(p.models, id: \.self) { m in
                        Button {
                            chat.selectModel(provider: p.slug, model: m)
                        } label: {
                            if Self.isCurrent(m, provider: p.slug, chat: chat) { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh Models") { chat.loadModelOptions() }
        } label: {
            MenuLabel(symbol: nil, text: chat.currentModel.isEmpty ? "Model" : chat.currentModel, compressible: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ComposerControlStyle())
        .help(Self.help(chat))
        .accessibilityLabel("Model: \(chat.currentModel.isEmpty ? "unknown" : chat.currentModel)")
        // B10: an error card's Switch Provider opens the same choices beside the pill.
        .popover(isPresented: $chat.modelPickerShown, arrowEdge: .top) { ModelPickerList(chat: chat) }
    }

    private static func isCurrent(_ m: String, provider: String, chat: ChatModel) -> Bool {
        m == chat.currentModel && chat.modelCatalog?.row(for: chat.currentProvider)?.slug == provider
    }

    static func help(_ chat: ChatModel) -> String {
        let provider = chat.currentProvider.isEmpty ? "" : " · \(chat.currentProvider)"
        return "Model for this chat: \(chat.currentModel)\(provider). Changing it affects this chat only."
    }
}

/// B10: the model choices as a list (Switch Provider on an error card); a pick closes it.
struct ModelPickerList: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("Switch model for this chat").font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                let providers = chat.modelCatalog?.providers ?? []
                if providers.isEmpty {
                    Text(chat.modelCatalog == nil ? "Loading models…" : "No models available")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
                ForEach(providers) { p in
                    Text(p.name).font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.ink).padding(.top, DS.Space.s1)
                    ForEach(p.models, id: \.self) { m in
                        Button {
                            chat.modelPickerShown = false
                            chat.selectModel(provider: p.slug, model: m)
                        } label: {
                            HStack {
                                Text(m).font(DS.Typeface.body).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if m == chat.currentModel && chat.modelCatalog?.row(for: chat.currentProvider)?.slug == p.slug {
                                    Image(systemName: "checkmark").font(DS.Typeface.iconSmall)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ComposerControlStyle())
                    }
                }
            }
            .padding(DS.Space.s3)
        }
        .frame(width: DS.Size.popoverWidth)
        .frame(maxHeight: DS.Size.commandMaxHeight * 2)
    }
}

/// B14: the bot's approval mode (`approvals.mode` of its profile), as Hermes Desktop's status bar menu:
/// Manual (ask before actions that need approval), Smart (assess and ask when needed), Off (no prompts).
struct ApprovalModeMenu: View {
    @ObservedObject var chat: ChatModel
    let mode: ApprovalMode
    var compact = false

    var body: some View {
        Menu {
            Section("Approval mode") {
                ForEach(ApprovalMode.allCases, id: \.self) { m in
                    Button {
                        chat.selectApprovalMode(m)
                    } label: {
                        if m == mode { Label("\(m.label): \(m.detail)", systemImage: "checkmark") } else { Text("\(m.label): \(m.detail)") }
                    }
                }
            }
        } label: {
            MenuLabel(symbol: mode == .off ? "bolt.fill" : "bolt", text: mode.label, showsText: !compact)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ComposerControlStyle())
        .help(Self.help(mode))
        .accessibilityLabel(Self.help(mode))
    }

    nonisolated static func help(_ mode: ApprovalMode) -> String {
        "Approval mode: \(mode.label). \(mode.detail). Applies to every chat of this bot."
    }
}

/// B7: reasoning effort for this chat (`config.set reasoning`, session scope). Hidden when the catalog says
/// the model has no reasoning control.
struct ReasoningMenu: View {
    @ObservedObject var chat: ChatModel
    var compact = false

    var body: some View {
        Menu {
            ForEach(chat.reasoningOptions, id: \.self) { level in
                Button {
                    chat.selectReasoning(level)
                } label: {
                    if level == Self.shownLevel(chat) { Label(ReasoningEffort.label(level), systemImage: "checkmark") } else {
                        Text(ReasoningEffort.label(level))
                    }
                }
            }
        } label: {
            MenuLabel(symbol: "brain", text: Self.label(chat.reasoningEffort, wire: chat.modelInfo?.reasoningEffortWire ?? ""),
                      showsText: !compact)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ComposerControlStyle())
        .help(Self.help(chat.reasoningEffort, wire: chat.modelInfo?.reasoningEffortWire ?? ""))
        .accessibilityLabel(Self.help(chat.reasoningEffort, wire: chat.modelInfo?.reasoningEffortWire ?? ""))
    }

    private static func shownLevel(_ chat: ChatModel) -> String {
        chat.reasoningEffort.isEmpty ? ReasoningEffort.fallback : chat.reasoningEffort
    }

    /// `Ultra→Max` when the route clamps the level, like Desktop's pill.
    nonisolated static func label(_ effort: String, wire: String) -> String {
        let shown = effort.isEmpty ? ReasoningEffort.fallback : effort
        guard !wire.isEmpty, wire != shown, shown != "none" else { return ReasoningEffort.label(shown) }
        return "\(ReasoningEffort.label(shown))→\(ReasoningEffort.label(wire))"
    }

    nonisolated static func help(_ effort: String, wire: String) -> String {
        let shown = effort.isEmpty ? ReasoningEffort.fallback : effort
        var s = "Reasoning effort for this chat: \(ReasoningEffort.label(shown))"
        if !wire.isEmpty, wire != shown, shown != "none" { s += " (this model sends \(ReasoningEffort.label(wire)))" }
        return s
    }
}

/// B9: how full the context window is. A short ink bar on a hairline track and the percentage; click for
/// the breakdown by category (`session.context_breakdown`).
struct ContextGauge: View {
    @ObservedObject var chat: ChatModel
    let usage: ContextUsage
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: DS.Space.s1) {
                ContextBar(fraction: Double(usage.percent) / 100)
                    .frame(width: DS.Size.gaugeWidth, height: DS.Size.gaugeHeight)
                Text(Self.percentText(usage)).monospacedDigit().lineLimit(1).fixedSize()
            }
            .fixedSize()
        }
        .buttonStyle(ComposerControlStyle())
        .help(Self.summary(usage))
        .accessibilityLabel("Context: \(Self.summary(usage))")
        .popover(isPresented: $shown, arrowEdge: .top) {
            ContextUsagePanel(usage: chat.contextUsage ?? usage, breakdown: chat.contextBreakdown, loading: chat.breakdownLoading)
        }
        .onChange(of: shown) { _, open in if open { chat.loadContextBreakdown() } }
    }

    nonisolated static func percentText(_ u: ContextUsage) -> String { (u.estimated ? "~" : "") + "\(u.percent)%" }

    nonisolated static func summary(_ u: ContextUsage) -> String {
        let approx = u.estimated ? "~" : ""
        return "\(approx)\(compact(u.used)) of \(compact(u.max)) tokens · \(approx)\(u.percent)% full"
    }

    /// 1234 → "1.2k", 200000 → "200k", 1500000 → "1.5M".
    nonisolated static func compact(_ n: Int) -> String {
        func trim(_ v: Double) -> String {
            let s = String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000) + "M" }
        if n >= 1_000 { return trim(Double(n) / 1_000) + "k" }
        return "\(n)"
    }
}

/// A filled share of a hairline track (graphite ink; the chrome stays neutral).
private struct ContextBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(DS.Palette.hairline)
                RoundedRectangle(cornerRadius: DS.Space.s0 / 2).fill(DS.Palette.ink).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The context popover: total, compaction count, and the window by category.
struct ContextUsagePanel: View {
    let usage: ContextUsage
    let breakdown: ContextBreakdown?
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                Spacer()
                Text(ContextGauge.summary(usage)).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
            ContextBar(fraction: Double(usage.percent) / 100).frame(height: DS.Size.gaugeHeight)
            if let n = usage.compressions, n > 0 {
                Label(n == 1 ? "Compacted once" : "Compacted \(n) times", systemImage: "square.stack.3d.down.right")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
            let categories = breakdown?.categories.filter { $0.tokens > 0 } ?? []
            if !categories.isEmpty {
                let total = max(1, categories.reduce(0) { $0 + $1.tokens })
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(categories) { c in
                        HStack(spacing: DS.Space.s2) {
                            Text(c.label).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                            Spacer(minLength: DS.Space.s2)
                            ContextBar(fraction: Double(c.tokens) / Double(total))
                                .frame(width: DS.Size.gaugeWidth, height: DS.Size.gaugeHeight)
                            Text("~" + ContextGauge.compact(c.tokens)).font(DS.Typeface.meta).monospacedDigit()
                                .foregroundStyle(DS.Palette.ink)
                        }
                    }
                }
            } else {
                Text(loading ? "Loading the breakdown…" : "No breakdown yet. It appears after the bot's first reply.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
        }
        .padding(DS.Space.s4)
        .frame(width: DS.Size.popoverWidth)
    }
}
