import AppKit
import HermesGatewayKit
import SwiftUI

// Card details (K2) in the board's native inspector: title, status / assignee / priority (each a menu: the
// K3 actions), dates, description and latest summary as markdown, dependencies (click to open), comments
// with an add box, runs, and the worker log tail on demand. Plus the New Task sheet.

struct KanbanTaskInspector: View {
    @ObservedObject var model: KanbanBoardModel
    let onArchive: (KanbanTask) -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @State private var comment = ""
    @State private var sending = false

    var body: some View {
        if let task = model.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    heading(task)
                    Hairline()
                    fields(task)
                    if let error = task.lastFailureError { section("Last failure") { text(error, color: DS.Palette.danger) } }
                    section("Description") {
                        if let body = (model.detail?.task.body ?? task.body), !body.isEmpty {
                            MarkdownView(blocks: MarkdownBlock.parse(body)).tint(DS.Palette.link).textSelection(.enabled)
                        } else {
                            text("No description", color: DS.Palette.muted)
                        }
                    }
                    if let summary = model.detail?.task.latestSummary ?? task.latestSummary {
                        section("Latest summary") { MarkdownView(blocks: MarkdownBlock.parse(summary)).tint(DS.Palette.link).textSelection(.enabled) }
                    }
                    if let result = model.detail?.task.result ?? task.result {
                        section("Result") { MarkdownView(blocks: MarkdownBlock.parse(result)).tint(DS.Palette.link).textSelection(.enabled) }
                    }
                    if let detail = model.detail { dependencies(detail) }
                    comments
                    if let runs = model.detail?.runs, !runs.isEmpty { self.runs(runs) }
                    workerLog
                    if let e = model.detailError { text("Details not loaded: \(e)", color: DS.Palette.danger) }
                }
                .padding(DS.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(task.id)
            .onChange(of: model.selectedTaskId) { _, _ in comment = "" }  // a draft never moves to another card
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
                }
            }
            field("Priority") {
                KanbanPriorityMenu(task: task, model: model, title: task.priority == 0 ? "0 (normal)" : "\(task.priority)")
                    .menuStyle(.borderlessButton).fixedSize()
            }
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
                        MarkdownView(blocks: MarkdownBlock.parse(c.body)).tint(DS.Palette.link).textSelection(.enabled)
                    }
                }
                HStack(alignment: .bottom, spacing: DS.Space.s2) {
                    TextField("Add a comment", text: $comment, axis: .vertical)
                        .lineLimit(DS.Kanban.commentLines)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .disabled(sending || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func send() {
        let body = comment
        guard !sending, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            if await model.addComment(body) { comment = "" }
            sending = false
        }
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
            Text("New task").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
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
                    .labelsHidden()
                }
                labeled("Lane") {
                    Picker("Lane", selection: $column) {
                        Text("Automatic").tag("")
                        ForEach(KanbanColumns.createTargets(lanes), id: \.self) { Text(KanbanColumns.label($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            labeled("Priority") {
                Picker("Priority", selection: $priority) {
                    ForEach(KanbanBoardModel.defaultPriorities, id: \.self) { Text($0 == 0 ? "Normal" : "\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
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
        .onAppear { titleFocused = true }
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
