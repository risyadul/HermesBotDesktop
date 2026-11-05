import AppKit
import HermesGatewayKit
import SwiftUI

/// B2: Copy message and Copy full response in Bot Chat.
enum ChatCopy {
    /// "Copy full response" text for each bot text line whose turn has more than one: every reply text of
    /// the turn (the bot lines between two user lines; Thought and tool rows left out), in order, separated
    /// by a blank line. A turn with a single reply text has no entry (Copy message already copies it all).
    static func fullResponses(_ lines: [ChatLine]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        var turn: [ChatLine] = []
        func flush() {
            let texts = turn.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if texts.count > 1 {
                let joined = texts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
                for l in texts { out[l.id] = joined }
            }
            turn = []
        }
        for l in lines {
            switch l.role {
            case .user: flush()
            case .bot: turn.append(l)
            default: break
            }
        }
        flush()
        return out
    }

    /// Whether a transcript line offers copy actions: settled bot text and the user's own messages.
    static func copyable(_ line: ChatLine) -> Bool {
        switch line.role {
        case .bot: return !line.streaming && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .user: return !line.text.isEmpty
        default: return false
        }
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// B3/B4: a per-message action beside Copy (Regenerate, Edit, Restore from Here, Branch into New Chat).
/// `hover` actions also get a button on the hover plate; all of them are in the context menu.
struct MessageAction: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var hover = false
    var enabled = true
    let action: () -> Void
}

/// Hover buttons (top trailing) and a context menu with Copy and, for a reply in several parts, Copy Full
/// Response. The buttons sit on a window-colour plate so they stay legible over text.
struct MessageCopyActions: ViewModifier {
    let text: String
    let fullResponse: String?
    /// K9: "Create Task from Message…" (nil: not offered).
    var onCreateTask: (() -> Void)?
    /// B5: when the message landed, shown on hover before the buttons (the full date is its tooltip).
    var time: Date?
    /// B3/B4: Bot Chat message actions (empty elsewhere).
    var actions: [MessageAction] = []
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 0) {
                        if let time {
                            Text(MessageTime.short(time))
                                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).monospacedDigit()
                                .padding(.horizontal, DS.Space.s2)
                                .help(MessageTime.full(time))
                                .accessibilityLabel("Sent \(MessageTime.full(time))")
                        }
                        MessageActionButton(symbol: "doc.on.doc", label: "Copy message") { ChatCopy.copy(text) }
                        if let fullResponse {
                            MessageActionButton(symbol: "doc.on.clipboard", label: "Copy full response") {
                                ChatCopy.copy(fullResponse)
                            }
                        }
                        ForEach(actions.filter(\.hover)) { a in
                            MessageActionButton(symbol: a.symbol, label: a.title, action: a.action).disabled(!a.enabled)
                        }
                    }
                    .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy Message") { ChatCopy.copy(text) }
                if let fullResponse { Button("Copy Full Response") { ChatCopy.copy(fullResponse) } }
                if !actions.isEmpty {
                    Divider()
                    ForEach(actions) { a in Button(a.title, action: a.action).disabled(!a.enabled) }
                }
                if let onCreateTask { Divider(); Button("Create Task from Message…", action: onCreateTask) }
            }
    }
}

extension View {
    func messageCopyActions(_ line: ChatLine, fullResponse: String?, onCreateTask: (() -> Void)? = nil,
                            actions: [MessageAction] = []) -> some View {
        modifier(MessageCopyActions(text: line.text, fullResponse: fullResponse, onCreateTask: onCreateTask, time: line.at,
                                    actions: actions))
    }
}
