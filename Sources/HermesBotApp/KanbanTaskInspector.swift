import AppKit
import HermesGatewayKit
import SwiftUI

// Card details (K2) in the board's native inspector: title, status / assignee / priority (each a menu: the
// K3 actions), dates, description and latest summary as markdown, dependencies (click to open), attachments
// (open, attach with the paperclip or by dropping files, delete), comments with an add box (on a running card
// it messages the worker, with Requeue with note), runs, and the worker log tail on demand. Plus the New
// Task sheet.

/// The comment box's words by the card's state (Desktop drawer.tsx `CommentComposer`). On a running card the
/// worker folds new comments into its current turn, so the box addresses the worker and offers Requeue with
/// note (post, then reclaim: the task restarts with the note), which Desktop also offers only there.
struct KanbanComposerCopy: Equatable {
    let placeholder: String
    let send: String
    let hint: String?
    let showsRequeue: Bool

    static let requeue = "Requeue with note"

    init(running: Bool) {
        placeholder = running ? "Message the running worker…" : "Add a comment…"
        send = running ? "Send" : "Comment"
        hint = running ? "Folded into the worker’s current turn within a few seconds." : nil
        showsRequeue = running
    }
}

/// Card text rendered as markdown in the inspector is capped: a huge description, summary, result or comment
/// (the server does not bound them) would otherwise be parsed and laid out whole on the main thread.
enum KanbanMarkdown {
    static let maxCharacters = 64_000
    static let truncationNote = "_Truncated: only the first 64,000 characters are shown._"

    /// `text` unchanged when short enough, else its first `maxCharacters` characters plus a note.
    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n\n" + truncationNote
    }

    static func blocks(_ text: String) -> [MarkdownBlock] { MarkdownBlock.parse(capped(text)) }
}

struct KanbanTaskInspector: View {
    @ObservedObject var model: KanbanBoardModel
    let onArchive: (KanbanTask) -> Void
    /// K9: the assignee's Bot Chat, when that bot is in the roster.
    var openBotChat: (KanbanTask) -> (() -> Void)? = { _ in nil }
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var sending = false
    @State private var deleteCandidate: KanbanAttachment?
    @State private var dropTargeted = false

    var body: some View {
        if let task = model.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    heading(task)
                    Hairline()
                    fields(task)
                    KanbanAISection(ai: model.ai, task: task, onOpenTask: { model.select($0) },
                                    title: { id in model.task(id).map { $0.title.isEmpty ? id : $0.title } ?? id })
                    if let error = task.lastFailureError { section("Last failure") { text(error, color: DS.Palette.danger) } }
                    section("Description") {
                        if let body = (model.detail?.task.body ?? task.body), !body.isEmpty {
                            MarkdownView(blocks: KanbanMarkdown.blocks(body)).tint(DS.Palette.link).textSelection(.enabled)
                        } else {
                            text("No description", color: DS.Palette.muted)
                        }
                    }
                    if let summary = model.detail?.task.latestSummary ?? task.latestSummary {
                        section("Latest summary") { MarkdownView(blocks: KanbanMarkdown.blocks(summary)).tint(DS.Palette.link).textSelection(.enabled) }
                    }
                    if let result = model.detail?.task.result ?? task.result {
                        section("Result") { MarkdownView(blocks: KanbanMarkdown.blocks(result)).tint(DS.Palette.link).textSelection(.enabled) }
                    }
                    if let detail = model.detail { dependencies(detail) }
                    attachmentsSection
                    comments
                    if let runs = model.detail?.runs, !runs.isEmpty { self.runs(runs) }
                    workerLog
                    if let e = model.detailError { text("Details not loaded: \(e)", color: DS.Palette.danger) }
                }
                .padding(DS.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(task.id)
            .onChange(of: model.selectedTaskId) { _, _ in deleteCandidate = nil }
            .confirmationDialog("Delete “\(VisibleText.reveal(deleteCandidate?.filename ?? ""))”?",
                                isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
                Button("Delete", role: .destructive) {
                    if let a = deleteCandidate { Task { await model.delete(a) } }
                    deleteCandidate = nil
                }
            } message: { Text("The file is removed from the card in Hermes, for every app and worker.") }
        } else {
            EmptyStateView(symbol: "rectangle.portrait.on.rectangle.portrait", title: "No card selected",
                           message: "Click a card to see its description, comments and worker log here.")
        }
    }

    // MARK: parts

    private func heading(_ task: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(task.title.isEmpty ? task.id : task.title)
                .font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s1) {
                Text(task.id).font(DS.Typeface.code).foregroundStyle(DS.Palette.muted).textSelection(.enabled).lineLimit(1)
                Spacer(minLength: 0)
                IconButton(symbol: "doc.on.doc", label: "Copy task ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.id, forType: .string)
                }
                Menu {
                    if let watches = model.watches {
                        KanbanWatchToggle(watches: watches, slug: model.slug, task: task) { on in
                            watches.set(model.slug, task.id, watching: on)
                        }
                        Divider()
                    }
                    Button("Archive…", role: .destructive) { onArchive(task) }
                } label: { Image(systemName: "ellipsis.circle").font(DS.Typeface.icon) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Card actions").help("Card actions")
            }
        }
    }

    private func fields(_ task: KanbanTask) -> some View {
        let lanes = model.serverLanes.map(\.name)
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            field("Status") {
                KanbanMoveMenu(task: task, model: model, laneNames: lanes, title: KanbanColumns.label(task.status))
                    .menuStyle(.borderlessButton).fixedSize()
            }
            field("Assignee") {
                HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                    if let who = task.assignee { AvatarView(identity: avatars.identity(profile: who), size: DS.Size.avatarChip) }
                    KanbanAssignMenu(task: task, model: model, title: task.assignee.map { "@\($0)" } ?? "Unassigned")
                        .menuStyle(.borderlessButton).fixedSize()
                    if let who = task.assignee, let open = openBotChat(task) {
                        IconButton(symbol: "bubble.left.and.text.bubble.right", label: "Open Bot Chat with @\(who)", action: open)
                    }
                }
            }
            field("Priority") {
                KanbanPriorityMenu(task: task, model: model, title: task.priority == 0 ? "0 (normal)" : "\(task.priority)")
                    .menuStyle(.borderlessButton).fixedSize()
            }
            field("Model") { KanbanModelMenu(ai: model.ai, task: task) }
            if let created = task.createdAt { field("Created") { text(Self.date(created) + (task.createdBy.map { " by \($0)" } ?? "")) } }
            if let updated = model.detail?.events.compactMap(\.createdAt).max() { field("Updated") { text(Self.date(updated)) } }
            if let done = task.completedAt { field("Completed") { text(Self.date(done)) } }
        }
    }

    @ViewBuilder private func dependencies(_ d: KanbanTaskDetail) -> some View {
        if !d.parents.isEmpty || !d.children.isEmpty {
            section("Dependencies") {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    if !d.parents.isEmpty { links("Blocked by", d.parents, d) }
                    if !d.children.isEmpty { links("Blocks", d.children, d) }
                }
            }
        }
    }

    private func links(_ label: String, _ ids: [String], _ d: KanbanTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            ForEach(ids, id: \.self) { id in
                let linked = d.linkTasks.first { $0.id == id }
                Button { model.select(id) } label: {
                    HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                        Text(linked?.title.isEmpty == false ? linked!.title : id).lineLimit(2)
                            .foregroundStyle(DS.Palette.link)
                        if let status = linked?.status, !status.isEmpty {
                            Text(KanbanColumns.label(status)).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                        }
                    }
                    .font(DS.Typeface.meta)
                }
                .buttonStyle(.plain)
                .help("Open \(id)")
            }
        }
    }

    private var comments: some View {
        let list = model.detail?.comments ?? []
        return section(list.isEmpty ? "Comments" : "Comments (\(list.count))") {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                ForEach(list) { c in
                    VStack(alignment: .leading, spacing: DS.Space.s0) {
                        HStack(spacing: DS.Space.s1) {
                            Text(c.author.isEmpty ? "Someone" : c.author).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                            if let at = c.createdAt { Text(Self.date(at)).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted) }
                        }
                        MarkdownView(blocks: KanbanMarkdown.blocks(c.body)).tint(DS.Palette.link).textSelection(.enabled)
                    }
                }
                composer(KanbanComposerCopy(running: model.selectedIsRunning))
            }
        }
    }

    @ViewBuilder private func composer(_ copy: KanbanComposerCopy) -> some View {
        let empty = sending || model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Kept per card in the model: a late send clears only its own card's draft.
        let field = TextField(copy.placeholder, text: Binding(get: { model.commentDraft }, set: { model.commentDraft = $0 }),
                              axis: .vertical)
            .lineLimit(DS.Kanban.commentLines)
            .textFieldStyle(.roundedBorder)
            .onSubmit(send)
        let sendButton = Button(copy.send, action: send)
            .buttonStyle(DSButtonStyle(kind: .primary))
            .disabled(empty)
        VStack(alignment: .leading, spacing: DS.Space.s1 + DS.Space.s0) {
            if copy.showsRequeue {
                // The inspector is narrow: the field takes the full width and both buttons sit under it.
                field
                if let hint = copy.hint {
                    Text(hint).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: 0)
                    Button(action: requeue) { Label(KanbanComposerCopy.requeue, systemImage: "arrow.clockwise") }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(empty)
                        .help("Post the note and restart the task from scratch with it in context")
                    sendButton
                }
            } else {
                HStack(alignment: .bottom, spacing: DS.Space.s2) {
                    field
                    sendButton
                }
            }
            if let note = model.inspectorNote {
                Label(note, systemImage: "checkmark.circle").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
        }
    }

    private func send() {
        let body = model.commentDraft
        guard !sending, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            _ = await model.addComment(body)
            sending = false
        }
    }

    private func requeue() {
        let body = model.commentDraft
        guard !sending, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            _ = await model.requeueWithNote(body)
            sending = false
        }
    }

    // MARK: attachments

    private var attachmentsSection: some View {
        let list = model.attachments
        return VStack(alignment: .leading, spacing: DS.Space.s1 + DS.Space.s0) {
            HStack(spacing: DS.Space.s1) {
                Text(list.isEmpty ? "Attachments" : "Attachments (\(list.count))")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).accessibilityAddTraits(.isHeader)
                if model.uploading > 0 { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                IconButton(symbol: "paperclip", label: "Attach Files…") {
                    pickAttachments(message: "Choose files to attach to this card (up to \(KanbanAPI.maxAttachmentBytes / (1024 * 1024)) MB each).") { urls in
                        Task { await model.upload(urls) }
                    }
                }
            }
            if list.isEmpty {
                Text(model.uploading > 0 ? "Uploading…" : "No attachments. Drop files here or use the paperclip.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            ForEach(list) { attachmentRow($0) }
            if let e = model.attachmentError {
                HStack(alignment: .top, spacing: DS.Space.s1) {
                    Text(e).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(symbol: "xmark", label: "Dismiss") { model.dismissAttachmentError() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: DS.Size.controlHeight * 2, alignment: .topLeading)
        .contentShape(Rectangle())
        .overlay { if dropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await model.upload(files) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func attachmentRow(_ a: KanbanAttachment) -> some View {
        let name = VisibleText.reveal(a.filename.isEmpty ? "attachment-\(a.id)" : a.filename)
        let busy = model.opening.contains(a.id)
        return HStack(spacing: DS.Space.s1) {
            Button { Task { await model.open(a) } } label: {
                HStack(spacing: DS.Space.s1 + DS.Space.s0) {
                    Image(systemName: busy ? "arrow.down.circle" : "doc").font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                    VStack(alignment: .leading, spacing: DS.Space.s0) {
                        Text(name).font(DS.Typeface.meta).foregroundStyle(DS.Palette.link).lineLimit(1).truncationMode(.middle)
                        Text(Self.attachmentDetail(a)).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Open \(name)")
            .accessibilityLabel("Open attachment \(name)")
            Spacer(minLength: 0)
            IconButton(symbol: "trash", label: "Delete \(name)…") { deleteCandidate = a }
        }
    }

    /// "12 KB · Nov 5, 14:02 · by hermes-bot-app".
    static func attachmentDetail(_ a: KanbanAttachment) -> String {
        [ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file), a.createdAt.map(date),
         a.uploadedBy.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func runs(_ runs: [KanbanRun]) -> some View {
        section("Runs") {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: DS.Space.s0) {
                        HStack(spacing: DS.Space.s1) {
                            Text(run.profile.map { "@\($0)" } ?? "Run \(run.id)").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                            Text([run.outcome ?? run.status, run.startedAt.map(Self.date)].compactMap { $0 }.joined(separator: " · "))
                                .font(DS.Typeface.caption).foregroundStyle(run.error == nil ? DS.Palette.muted : DS.Palette.danger)
                        }
                        if let s = run.summary ?? run.error {
                            Text(s).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(4).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var workerLog: some View {
        section("Worker log") {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Button(model.log == nil ? "Load Log" : "Refresh") { Task { await model.loadLog() } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(model.logLoading)
                    if model.logLoading { ProgressView().controlSize(.mini) }
                    if let log = model.log, log.truncated {
                        Text("Last \(KanbanAPI.defaultLogTail / 1024) KB").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    }
                }
                if let e = model.logError { text(e, color: DS.Palette.danger) }
                if let log = model.log {
                    if !log.exists || log.content.isEmpty {
                        text("No worker log yet", color: DS.Palette.muted)
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            Text(log.content).font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                                .textSelection(.enabled).fixedSize().padding(DS.Space.s2)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: DS.Kanban.logMaxHeight)
                        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func section<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1 + DS.Space.s0) {
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s0) {
            Text(label).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            content()
        }
    }

    private func text(_ s: String, color: Color = DS.Palette.ink) -> some View {
        Text(s).font(DS.Typeface.body).foregroundStyle(color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    static func date(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - new task sheet

struct KanbanNewTaskSheet: View {
    let lanes: [String]
    let assignees: [String]
    let onCreate: (KanbanTaskDraft, String?) async -> String?
    /// Presented by `motionSheet`, so `\.dismiss` would not reach it (CreateRoomView.swift).
    let onClose: () -> Void
    /// K9 Create Task from Message: the sheet starts with these, says where they came from, and offers a board.
    var initialTitle = ""
    var initialDetails = ""
    var initialAssignee = ""
    var subtitle: String?
    var boards: [KanbanSidebarRow] = []
    var board: Binding<String>?
    @State private var title = ""
    @State private var details = ""
    @State private var assignee = ""
    @State private var priority = 0
    /// "" = automatic (the server picks ready or todo).
    @State private var column = ""
    @State private var error: String?
    @State private var creating = false
    @FocusState private var titleFocused: Bool

    /// The draft and the `column` argument for a sheet's values. Triage is the draft's own flag (the server
    /// files it there); any other lane is a follow-up move, as Desktop's per-lane add does.
    static func request(title: String, details: String, assignee: String, priority: Int, column: String) -> (KanbanTaskDraft, String?) {
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = KanbanTaskDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    body: body.isEmpty ? nil : body, assignee: assignee.isEmpty ? nil : assignee,
                                    priority: priority, triage: column == "triage")
        return (draft, column.isEmpty || column == "triage" ? nil : column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("New task").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                if let subtitle { Text(subtitle).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1) }
            }
            if let board, !boards.isEmpty {
                labeled("Board") {
                    Picker("Board", selection: board) {
                        ForEach(boards) { Text($0.name).tag($0.slug) }
                    }
                    .labelsHidden().accessibilityLabel("Board")
                }
            }
            labeled("Title") {
                TextField("What should be done", text: $title).textFieldStyle(.roundedBorder).labelsHidden().focused($titleFocused)
            }
            labeled("Description") {
                TextEditor(text: $details)
                    .font(DS.Typeface.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.s1)
                    .frame(height: DS.Kanban.descriptionHeight)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
            }
            HStack(alignment: .top, spacing: DS.Space.s3) {
                labeled("Assignee") {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(assignees, id: \.self) { Text("@\($0)").tag($0) }
                    }
                    .labelsHidden().accessibilityLabel("Assignee")
                }
                labeled("Lane") {
                    Picker("Lane", selection: $column) {
                        Text("Automatic").tag("")
                        ForEach(KanbanColumns.createTargets(lanes), id: \.self) { Text(KanbanColumns.label($0)).tag($0) }
                    }
                    .labelsHidden().accessibilityLabel("Lane")
                }
            }
            labeled("Priority") {
                Picker("Priority", selection: $priority) {
                    ForEach(KanbanBoardModel.defaultPriorities, id: \.self) { Text($0 == 0 ? "Normal" : "\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Priority")
            }
            Text(column.isEmpty ? "Ready when it has an assignee and no open dependencies, else Todo." : (KanbanColumns.help(column) ?? ""))
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.s5).frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .defaultFocus($titleFocused, true)
        .onAppear {
            if title.isEmpty && details.isEmpty && assignee.isEmpty {
                title = initialTitle; details = initialDetails; assignee = initialAssignee
            }
            titleFocused = true
        }
    }

    private func create() {
        let (draft, lane) = Self.request(title: title, details: details, assignee: assignee, priority: priority, column: column)
        guard !draft.title.isEmpty, !creating else { return }
        creating = true
        Task {
            error = await onCreate(draft, lane)
            creating = false
            if error == nil { onClose() }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(label).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
            content()
        }
    }
}
