import SwiftUI

/// Streaming may update the surrounding buttons and status, but the native text editor depends only
/// on its draft and configuration. Its owner is deliberately unobserved. The parent handlers read the
/// same live ChatModel and SwiftUI State/FocusState locations, never captured catalog/menu snapshots.
/// Equality therefore ignores new closure allocations from otherwise unrelated parent updates.
struct ChatDraftField: View, Equatable {
    private let ownerID: ObjectIdentifier
    private let stateID: ObjectIdentifier
    @ObservedObject var state: ComposerDraftState
    let placeholder: String
    let label: String
    let focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onUp: () -> KeyPress.Result
    let onDown: () -> KeyPress.Result
    let onTab: () -> KeyPress.Result
    let onEscape: () -> KeyPress.Result

    init(owner: ChatModel, state: ComposerDraftState, placeholder: String, label: String,
         focus: FocusState<Bool>.Binding, onSend: @escaping () -> Void,
         onUp: @escaping () -> KeyPress.Result, onDown: @escaping () -> KeyPress.Result,
         onTab: @escaping () -> KeyPress.Result, onEscape: @escaping () -> KeyPress.Result) {
        ownerID = ObjectIdentifier(owner)
        stateID = ObjectIdentifier(state)
        self.state = state
        self.placeholder = placeholder
        self.label = label
        self.focus = focus
        self.onSend = onSend
        self.onUp = onUp
        self.onDown = onDown
        self.onTab = onTab
        self.onEscape = onEscape
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ownerID == rhs.ownerID && lhs.stateID == rhs.stateID
            && lhs.placeholder == rhs.placeholder && lhs.label == rhs.label
    }

    var body: some View {
        TextField(placeholder, text: $state.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(DS.Typeface.body)
            .lineLimit(DS.Size.composerLines)
            .padding(.vertical, DS.Size.fieldInset)
            .focused(focus)
            .onSubmit(onSend)
            .onKeyPress(.upArrow, action: onUp)
            .onKeyPress(.downArrow, action: onDown)
            .onKeyPress(.tab, action: onTab)
            .onKeyPress(.escape, action: onEscape)
            .accessibilityLabel(label)
    }
}
