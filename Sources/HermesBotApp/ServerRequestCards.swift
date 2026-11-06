import HermesGatewayKit
import SwiftUI

/// The requests the bot waits on, as cards at the bottom of the transcript (above the composer). Each is
/// removed when answered, or when the backend cancels it (`request.cancel`, `approval.cancelled`).
struct ServerRequestCards: View {
    @ObservedObject var chat: ChatModel
    let identity: BotIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(chat.requests) { r in
                ServerRequestRow(chat: chat, identity: identity, request: r)
            }
        }
    }

}

/// A top-level list row keeps each approval/clarification an independent scroll target.
struct ServerRequestRow: View {
    @ObservedObject var chat: ChatModel
    let identity: BotIdentity
    let request: ServerRequest

    var body: some View {
        card(request).onAppear { chat.cardShown(request) }.id("request-\(request.id)")
    }

    @ViewBuilder private func card(_ r: ServerRequest) -> some View {
        let busy = chat.answering.contains(r.id)
        let error = chat.requestErrors[r.id]
        switch r.kind {
        case .approval(let a):
            ApprovalRequestCard(bot: chat.bot.title, identity: identity, prompt: a, busy: busy, error: error) { choice in
                chat.respond(r, .approval(choice))
            }
        case .clarify(let c):
            ClarifyRequestCard(bot: chat.bot.title, prompt: c, busy: busy, error: error,
                               onSubmit: { chat.respond(r, .clarify($0)) },
                               onCancel: { chat.respond(r, .clarifyCancel) })
        case .value(let v):
            ValueRequestCard(prompt: v, busy: busy, error: error) { chat.respond(r, .value($0)) }
        case .notShown, .unknown:
            EmptyView()  // declined by the kit's router; never routed here
        }
    }
}

/// `action-card` chrome in the `attention` role, as the Group Chat approval card (`attentionCard()`).
private struct AttentionCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .attentionCard()
            .padding(.leading, DS.Size.contentInset)
            .accessibilityElement(children: .contain)
    }
}

/// The exact command a card asks about, as `VisibleText` shows it: hidden and bidi characters as
/// `⟨U+XXXX⟩`, long whitespace padding as `␠×N`, each line forced left-to-right (display only) so
/// right-to-left letters cannot reorder it. Long lines wrap (nothing hides past the right edge) and a
/// tall command scrolls inside a capped box with the scroll indicator always visible. Any non-ASCII
/// character is flagged with a small badge above the box.
struct ApprovalCommandView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            if VisibleText.hasNonASCII(text) {
                Label("Contains non-ASCII characters", systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.attention)
                    .accessibilityLabel("The command contains non-ASCII characters")
            }
            ScrollView(.vertical) {
                Text(VisibleText.forcedLeftToRight(text))
                    .environment(\.layoutDirection, .leftToRight)
                    .font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.codeLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.gutter)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: DS.Size.commandMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
    }
}

private struct CardHeader: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: symbol).font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention).accessibilityHidden(true)
            Text(VisibleText.reveal(title)).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CardError: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ApprovalRequestCard: View {
    let bot: String
    let identity: BotIdentity
    let prompt: ApprovalPrompt
    let busy: Bool
    let error: String?
    let onChoose: (ApprovalPrompt.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "hand.raised.fill").font(DS.Typeface.icon).foregroundStyle(DS.Palette.attention)
                    .accessibilityHidden(true)
                AvatarView(identity: identity, size: DS.Size.avatarChip)
                Text("\(bot) needs your approval").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
            }
            if !prompt.description.isEmpty {
                Text("Flagged: \(VisibleText.reveal(prompt.description))").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.command.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(prompt.toolName.map { "Command (\(VisibleText.reveal($0)))" } ?? "Command")
                        .font(DS.Typeface.captionStrong).foregroundStyle(DS.Palette.muted)
                    ApprovalCommandView(text: prompt.command)
                }
            }
            HStack(spacing: DS.Space.s2) {
                ForEach(ApprovalButtons.ordered(prompt.choices), id: \.self) { c in
                    Button(ApprovalButtons.title(c), role: c == .deny ? .destructive : nil) { onChoose(c) }
                        .buttonStyle(DSButtonStyle(kind: ApprovalButtons.kind(c)))
                        .disabled(busy)
                        .accessibilityLabel(ApprovalButtons.title(c))
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, DS.Space.s1)
            CardError(text: error)
        }
        .modifier(AttentionCard())
        .accessibilityLabel("\(bot) needs your approval")
    }
}

struct ClarifyRequestCard: View {
    let bot: String
    let prompt: ClarifyPrompt
    let busy: Bool
    let error: String?
    let onSubmit: ([String: String?]) -> Void
    let onCancel: () -> Void
    @State private var draft: ClarifyDraft?

    private var current: ClarifyDraft { draft ?? ClarifyDraft(prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            CardHeader(symbol: "questionmark.bubble.fill", title: "\(bot) has a question")
            ForEach(prompt.questions) { q in question(q) }
            HStack(spacing: DS.Space.s2) {
                Button("Answer") { onSubmit(current.answers(prompt)) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(busy || !current.canSubmit(prompt))
                Button("Dismiss") { onCancel() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(busy)
                    .help("Answer nothing; the bot continues without it")
                if busy { ProgressView().controlSize(.small) }
            }
            CardError(text: error)
        }
        .modifier(AttentionCard())
        .accessibilityLabel("\(bot) has a question")
    }

    @ViewBuilder private func question(_ q: ClarifyPrompt.Question) -> some View {
        let entry = current.entry(q.qid)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(VisibleText.reveal(q.question)).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !q.choices.isEmpty {
                FlowChoices(choices: q.choices, picked: entry.picked, multi: q.multiSelect, disabled: busy) { c in
                    var d = current; d.toggle(c, in: q); draft = d
                }
            }
            HStack(spacing: DS.Space.s2) {
                TextField(q.choices.isEmpty ? "Your answer" : "Or type an answer", text: Binding(
                    get: { current.entry(q.qid).text },
                    set: { var d = current; d.setText($0, for: q); draft = d }))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typeface.body)
                    .disabled(busy)
                    .accessibilityLabel("Answer to: \(VisibleText.reveal(q.question))")
                Button(entry.skipped ? "Skipped" : "Skip") { var d = current; d.skip(q); draft = d }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(busy || entry.skipped)
                    .accessibilityLabel("Skip: \(VisibleText.reveal(q.question))")
            }
        }
    }
}

/// Choice buttons for one clarify question; selected ones use the selected fill and a check.
private struct FlowChoices: View {
    let choices: [String]
    let picked: [String]
    let multi: Bool
    let disabled: Bool
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(choices, id: \.self) { c in
                let on = picked.contains(c)
                Button { onToggle(c) } label: {
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .font(DS.Typeface.icon).foregroundStyle(on ? DS.Palette.ink : DS.Palette.muted)
                        Text(VisibleText.reveal(c)).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SuggestionRowStyle(highlighted: on))
                .disabled(disabled)
                .accessibilityLabel(VisibleText.reveal(c))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// sudo / secret: a masked field. Submit sends the value (never logged); Cancel sends "" (declined).
struct ValueRequestCard: View {
    let prompt: ValuePrompt
    let busy: Bool
    let error: String?
    let onAnswer: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            CardHeader(symbol: prompt.kind == .sudo ? "lock.fill" : "key.fill", title: ValuePromptCopy.title(prompt))
            if let c = prompt.command, !c.isEmpty { ApprovalCommandView(text: c) }
            SecureField(ValuePromptCopy.fieldLabel(prompt), text: $value)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .onSubmit(submit)
                .accessibilityLabel(ValuePromptCopy.fieldLabel(prompt))
            HStack(spacing: DS.Space.s2) {
                Button("Submit", action: submit)
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(busy || value.isEmpty)
                Button("Cancel") { value = ""; onAnswer("") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            CardError(text: error)
        }
        .modifier(AttentionCard())
        .accessibilityLabel(ValuePromptCopy.title(prompt))
    }

    private func submit() {
        guard !value.isEmpty, !busy else { return }
        let v = value
        value = ""
        onAnswer(v)
    }
}
