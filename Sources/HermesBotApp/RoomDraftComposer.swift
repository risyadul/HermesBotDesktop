import HermesGatewayKit
import SwiftUI

/// Only this field and its completions subscribe to a room draft. The room timeline, ribbon,
/// footer and thread projection do not observe text edits.
struct RoomDraftComposer: View {
    @ObservedObject var state: ComposerDraftState
    let placeholder: String
    let members: [RoomMember]
    let acceptsMessages: Bool
    let identity: (RoomMember) -> BotIdentity
    let focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    var onAttach: (() -> Void)? = nil
    var attachments: [PendingAttachment] = []
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    var dictation: DictationController? = nil

    private var draft: Binding<String> { $state.text }

    var body: some View {
        ComposerBox(placeholder: placeholder, draft: draft,
                    canSend: acceptsMessages && (!state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                 || attachments.contains(where: \.isReady)),
                    onSend: onSend, focus: focus,
                    onTab: { MentionSuggestions.acceptFirst(&state.text, members: members) },
                    onAttach: onAttach, attachments: attachments,
                    onRemoveAttachment: onRemoveAttachment, dictation: dictation)
            .overlay(alignment: .topLeading) {
                MentionSuggestions(draft: draft, members: members, identity: identity)
                    .alignmentGuide(.top) { $0[.bottom] + DS.Space.s1 }
            }
    }
}
