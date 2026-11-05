import HermesGatewayKit
import SwiftUI

/// The dialogs a chat surface (Bot Chat or a branch sheet) presents: the rewind confirmation (B3), the edit
/// sheet (B3), Attach URL (B11) and the image zoom sheet (B11, offered to the transcript's images through
/// the `imageZoom` environment).
struct ChatSheets: ViewModifier {
    @ObservedObject var chat: ChatModel
    let motion: Bool
    @State private var zoom: ZoomTarget?

    struct ZoomTarget: Equatable {
        let ref: MediaRef
        let url: URL
    }

    func body(content: Content) -> some View {
        content
            .environment(\.imageZoom, ImageZoomAction { ref, url in zoom = ZoomTarget(ref: ref, url: url) })
            .alert(chat.rewindConfirm?.title ?? "", isPresented: Binding(
                get: { chat.rewindConfirm != nil }, set: { if !$0 { chat.cancelRewind() } }
            ), presenting: chat.rewindConfirm) { c in
                Button(c.confirmLabel, role: .destructive) { chat.confirmRewind() }
                Button("Cancel", role: .cancel) { chat.cancelRewind() }
            } message: { c in
                Text(c.message)
            }
            .motionSheet(isPresented: Binding(get: { chat.editing != nil }, set: { if !$0 { chat.cancelEdit() } }), motion: motion) {
                if let e = chat.editing {
                    MessageEditSheet(text: e.text, hadAttachments: e.hadAttachments,
                                     onSend: { chat.commitEdit($0) }, onCancel: { chat.cancelEdit() })
                }
            }
            .motionSheet(isPresented: $chat.urlDialogShown, motion: motion) {
                AttachURLSheet(onAttach: { raw in
                    guard chat.addURL(raw) else { return false }
                    chat.urlDialogShown = false
                    return true
                }, onCancel: { chat.urlDialogShown = false })
            }
            .motionSheet(isPresented: Binding(get: { zoom != nil }, set: { if !$0 { zoom = nil } }), motion: motion) {
                if let z = zoom {
                    ImageZoomSheet(ref: z.ref, url: z.url, onClose: { zoom = nil })
                }
            }
    }
}

extension View {
    func chatSheets(_ chat: ChatModel, motion: Bool) -> some View { modifier(ChatSheets(chat: chat, motion: motion)) }
}
