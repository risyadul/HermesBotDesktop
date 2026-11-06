import AppKit
import HermesGatewayKit
import SwiftUI

// Threads and per-message actions in Group Chat (roadmap C1.2, C1.6). The room timeline stays one
// arrival-ordered conversation (as in Hermes Desktop): a message in another thread carries a thread label,
// and a message a thread hangs off carries its reply count. Either opens the thread pane (the room's
// inspector column), which shows that thread only and has its own composer posting with its `thread_id`.

/// The thread label above a thread message, or the reply count under a message a thread hangs off.
struct RoomThreadLink: View {
    enum Style { case label, replies }
    let style: Style
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: style == .label ? "text.bubble" : "arrowshape.turn.up.left")
                    .font(DS.Typeface.iconSmall)
                Text(style == .label ? "Thread · \(text)" : text)
                    .font(DS.Typeface.caption).lineLimit(1)
                if style == .replies { Image(systemName: "chevron.right").font(DS.Typeface.iconSmall) }
            }
        }
        .buttonStyle(ThreadLinkStyle())
        .help(style == .label ? "Open this thread" : "Open the thread on this message")
        .accessibilityLabel(style == .label ? "Open thread \(text)" : "Open thread, \(text)")
    }
}

private struct ThreadLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? DS.Palette.ink : DS.Palette.muted)
                .padding(.horizontal, DS.Space.s1).padding(.vertical, DS.Space.s0)
                .background(hovering || configuration.isPressed ? DS.Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
    }
}

/// The actions a message row offers, as a hover strip and as its context menu.
struct RoomMessageActions {
    /// "Reply to @handle" (member messages whose author is a room member).
    let replyHandle: String?
    let onReply: () -> Void
    /// Nil inside the thread pane (the pane's composer already posts to the thread).
    let onReplyInThread: (() -> Void)?
    let copyText: String?
    /// K9: "Create Task from Message…" (nil: not offered).
    var onCreateTask: (() -> Void)?

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Hover strip (over the top trailing corner of the message) plus the same actions
/// in the row's context menu. The strip only appears while the pointer is over the row.
struct MessageActionsModifier: ViewModifier {
    let actions: RoomMessageActions
    let alignment: Alignment

    func body(content: Content) -> some View {
        HoverReader { hovering in
            content
                .overlay(alignment: alignment) {
                    if hovering { strip.offset(y: -DS.Space.s3) }
                }
        }
        .contextMenu { menu }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            if let handle = actions.replyHandle {
                IconButton(symbol: "at", label: "Reply to @\(handle)", action: actions.onReply)
            }
            if let thread = actions.onReplyInThread {
                IconButton(symbol: "text.bubble", label: "Reply in thread", action: thread)
            }
            if let text = actions.copyText {
                IconButton(symbol: "doc.on.doc", label: "Copy") { RoomMessageActions.copy(text) }
            }
        }
        .padding(DS.Space.s0)
        .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
    }

    @ViewBuilder private var menu: some View {
        if let handle = actions.replyHandle {
            Button("Reply to @\(handle)", action: actions.onReply)
        }
        if let thread = actions.onReplyInThread {
            Button("Reply in Thread", action: thread)
        }
        if let text = actions.copyText {
            Button("Copy") { RoomMessageActions.copy(text) }
        }
        if let create = actions.onCreateTask {
            Divider()
            Button("Create Task from Message…", action: create)
        }
    }
}

extension View {
    func messageActions(_ actions: RoomMessageActions, alignment: Alignment) -> some View {
        modifier(MessageActionsModifier(actions: actions, alignment: alignment))
    }
}

/// The thread pane: the message the thread hangs off (when it is in the log), the thread's rows, and a
/// composer that posts with the thread's `thread_id` and keeps its own draft.
struct RoomThreadPane<Row: View>: View {
    @ObservedObject var model: RoomModel
    let thread: String
    let row: (RoomRow) -> Row
    let identity: (RoomMember) -> BotIdentity
    @FocusState private var focused: Bool
    @State private var scroll = TranscriptScrollTracker()
    @State private var following = true
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        let presentation = model.threadPresentation(thread: thread)
        let summary = presentation.summary
        let rows = presentation.rows
        let anchor = presentation.anchor
        VStack(spacing: 0) {
            header(summary, anchorOnly: rows.isEmpty)
            Hairline()
            let data = ThreadTimelineRows(anchor: anchor, messages: rows,
                                          divider: rows.isEmpty ? "Reply to start the thread" : RoomPresentation.replyCount(summary?.messageCount ?? rows.count))
            TranscriptTable(items: data, revision: UUID(), structureRevision: ObjectIdentifier(presentation),
                            tracker: scroll, onFollowChange: { following = $0 }, sameContent: ==) { item in
                Group {
                    switch item {
                    case .anchor(let anchor): row(anchor)
                    case .divider(let text): RoundDivider(text: text)
                    case .message(let message): row(message)
                    }
                }
                .padding(.horizontal, DS.Space.s3).padding(.top, DS.Space.timeline)
                .padding(.bottom, item.id == data.last?.id ? DS.Space.s3 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.motionEnabled, motion)
            }
            .onChange(of: thread) { _, _ in
                scroll.follow.resume()
                following = true
                scroll.scrollToLatest?()
            }
            .overlay(alignment: .bottom) {
                if !following {
                    ScrollToBottomButton(unread: 0) {
                        scroll.follow.resume()
                        following = true
                        scroll.scrollToLatest?()
                    }
                    .padding(.bottom, DS.Space.s3)
                }
            }
            composer
        }
        .background(DS.Palette.window)
        .onAppear { focused = model.focusRequest?.thread == thread }
        .onChange(of: model.focusRequest) { _, r in if r?.thread == thread { focused = true } }
    }

    private func header(_ summary: RoomThreadSummary?, anchorOnly: Bool) -> some View {
        HStack(spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text("Thread").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                if !anchorOnly {
                    Text(RoomPresentation.threadTitle(summary)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s2)
            IconButton(symbol: "xmark", label: "Close thread") { model.closeThread() }
        }
        .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
    }

    private var composer: some View {
        RoomDraftComposer(state: model.draftStates.state(for: thread), placeholder: "Reply in thread",
                          members: model.room.members, acceptsMessages: model.composer.canSend,
                          identity: identity, focus: $focused, onSend: { _ = model.submit(thread: thread) })
            .padding(DS.Space.s3)
    }
}
