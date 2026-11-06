import HermesGatewayKit
import SwiftUI

/// B8: messages waiting for the running turn, above the composer. Each row: the message (two lines), then
/// Edit, Send now and Delete. A header says how many wait and, after Stop paused the queue, offers Resume.
struct ChatQueuePanel: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(chat.queue) { entry in row(entry) }
                }
            }
            .frame(maxHeight: DS.Size.queueMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.s2)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: chat.queueParked ? "pause.circle" : "tray.full").font(DS.Typeface.iconSmall)
            Text(Self.title(count: chat.queue.count, parked: chat.queueParked)).font(DS.Typeface.captionStrong)
                .lineLimit(1)
                .help(chat.queueParked ? "Stop paused the queue. Resume, or send a message now."
                                       : "Sent one at a time when the reply finishes.")
            Spacer()
            if chat.queueParked {
                Button("Resume") { chat.resumeQueue() }
                    .buttonStyle(ComposerControlStyle())
                    .help("Send the queued messages again, one at a time")
            }
        }
        .foregroundStyle(DS.Palette.muted)
        .padding(.horizontal, DS.Space.s1)
    }

    nonisolated static func title(count: Int, parked: Bool) -> String {
        return parked ? "\(count) queued · paused" : "\(count) queued"
    }

    private func row(_ entry: QueuedMessage) -> some View {
        let editing = chat.editingQueueId == entry.id
        return HStack(alignment: .top, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text(entry.preview).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editing {
                    Text("Editing in the composer · Return saves, Esc cancels")
                        .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            HStack(spacing: 0) {
                MessageActionButton(symbol: "pencil", label: "Edit") { chat.beginQueueEdit(entry.id) }
                    .disabled(chat.editingQueueId != nil)
                MessageActionButton(symbol: "arrow.up.circle",
                                    label: chat.busy ? "Send now (stops the current reply)" : "Send now") {
                    chat.sendQueuedNow(entry.id)
                }
                .disabled(editing || !chat.isReady)
                MessageActionButton(symbol: "xmark", label: "Delete") { chat.deleteQueued(entry.id) }
            }
        }
        .padding(.horizontal, DS.Space.s1).padding(.vertical, DS.Space.s1)
        .background(editing ? DS.Palette.selected : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.ring, lineWidth: DS.Stroke.ring)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued: \(entry.preview)")
    }
}

/// A small icon button for message and queue rows (22 pt, the `IconButton` hover grammar).
struct MessageActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(DS.Typeface.iconSmall)
                .frame(width: DS.Size.messageAction, height: DS.Size.messageAction)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}
