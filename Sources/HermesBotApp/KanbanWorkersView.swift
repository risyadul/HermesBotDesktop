import HermesGatewayKit
import SwiftUI

// Kanban Workers sheet (roadmap K5), opened from the board header: which bot runs which card, for how long,
// its last heartbeat; Inspect shows the run, the worker process and its log; Terminate and Reclaim ask first.

extension DS.Kanban {
    static let workersHeight: CGFloat = 420
    static let workersWidth: CGFloat = 560
    static let inspectLabelWidth: CGFloat = 110
}

struct KanbanWorkersSheet: View {
    let onOpenTask: (String) -> Void
    let onClose: () -> Void
    @StateObject private var model: KanbanWorkersModel
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case terminate(KanbanActiveWorker), reclaim(KanbanActiveWorker)
        var id: String {
            switch self {
            case .terminate(let w): return "t\(w.runId)"
            case .reclaim(let w): return "r\(w.runId)"
            }
        }
        var worker: KanbanActiveWorker {
            switch self { case .terminate(let w), .reclaim(let w): return w }
        }
    }

    init(slug: String, api: any KanbanService, onOpenTask: @escaping (String) -> Void,
         onChanged: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onOpenTask = onOpenTask
        self.onClose = onClose
        // Built inside the autoclosure: SwiftUI evaluates it once per view identity, not on every re-init.
        _model = StateObject(wrappedValue: {
            let m = KanbanWorkersModel(slug: slug, api: api)
            m.onChanged = onChanged
            return m
        }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                if model.inspection != nil {
                    IconButton(symbol: "chevron.left", label: "Back to workers") { model.closeInspection() }
                }
                Text(model.inspection.map { "Run #\($0.worker.runId)" } ?? "Active workers")
                    .font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
                Spacer()
                if model.inspection == nil {
                    IconButton(symbol: "arrow.clockwise", label: "Refresh") { Task { await model.refresh() } }
                }
            }
            messages
            Group {
                if let inspection = model.inspection {
                    KanbanRunInspectionView(inspection: inspection, onOpenTask: onOpenTask)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                Text("Terminate and Reclaim stop the worker; the card goes back to Ready for the dispatcher.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Kanban.workersWidth, height: DS.Kanban.workersHeight)
        .background(DS.Palette.window)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(AppModel.shared.$mainWindowOnScreen) { model.setSuspended(!$0) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { c in
            switch c {
            case .terminate(let w):
                Button("Terminate", role: .destructive) { Task { await model.terminate(w) } }
            case .reclaim(let w):
                Button("Reclaim", role: .destructive) { Task { await model.reclaim(w) } }
            }
        } message: { c in
            Text(c.worker.bot.map { "@\($0) stops working on this card now." } ?? "The worker stops now.")
                + Text(" The card goes back to Ready and the dispatcher may run it again.")
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .terminate(let w): return "Terminate run #\(w.runId) of “\(w.taskTitle)”?"
        case .reclaim(let w): return "Reclaim “\(w.taskTitle)”?"
        case nil: return ""
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
        } else if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle").font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
        } else if let sync = model.syncError {
            Label("Not refreshed: \(sync). Retrying.", systemImage: "arrow.clockwise")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
        }
    }

    @ViewBuilder private var list: some View {
        switch model.state {
        case .loading:
            EmptyStateView(symbol: "cpu", title: "Loading workers", message: "Asking Hermes which runs are active.") {
                ProgressView().controlSize(.small)
            }
        case .unavailable:
            EmptyStateView(symbol: "cpu", title: "Kanban is off in Hermes", message: "Turn on the kanban plugin to see workers.")
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't load workers", message: message) {
                Button("Try Again") { Task { await model.refresh() } }.buttonStyle(DSButtonStyle(kind: .primary))
            }
        case .ready:
            if model.workers.isEmpty {
                EmptyStateView(symbol: "cpu", title: "No active workers",
                               message: "No card on this board is being worked on right now.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s2) {
                        ForEach(model.workers) { w in
                            KanbanWorkerRow(worker: w, status: model.status(w), busy: model.busy.contains(w.runId),
                                            inspecting: model.inspecting == w.runId,
                                            onOpen: { onOpenTask(w.taskId) },
                                            onInspect: { Task { await model.inspect(w) } },
                                            onTerminate: { confirm = .terminate(w) },
                                            onReclaim: { confirm = .reclaim(w) })
                        }
                    }
                }
            }
        }
    }
}

struct KanbanWorkerRow: View {
    let worker: KanbanActiveWorker
    let status: KanbanWorkerStatus
    let busy: Bool
    let inspecting: Bool
    let onOpen: () -> Void
    let onInspect: () -> Void
    let onTerminate: () -> Void
    let onReclaim: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            if let bot = worker.bot {
                AvatarView(identity: avatars.identity(profile: bot), size: DS.Size.avatarChip)
            } else {
                Image(systemName: "cpu").font(DS.Typeface.icon).foregroundStyle(DS.Palette.muted)
                    .frame(width: DS.Size.avatarChip, height: DS.Size.avatarChip)
            }
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Button(action: onOpen) {
                    Text(worker.taskTitle.isEmpty ? worker.taskId : worker.taskTitle)
                        .font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Open the card")
                Text(detailLine).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: status.stale ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                        .font(DS.Typeface.iconSmall)
                    Text(status.stale ? "No heartbeat for \(status.heartbeat.replacingOccurrences(of: " ago", with: ""))"
                                      : "Heartbeat \(status.heartbeat)")
                }
                .font(DS.Typeface.caption)
                .foregroundStyle(status.stale ? DS.Palette.attention : DS.Palette.muted)
            }
            Spacer(minLength: DS.Space.s2)
            if busy || inspecting { ProgressView().controlSize(.small) }
            Menu {
                Button("Inspect Run", action: onInspect)
                Button("Open Card", action: onOpen)
                Divider()
                Button("Terminate Run…", role: .destructive, action: onTerminate)
                Button("Reclaim Task…", role: .destructive, action: onReclaim)
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .labelStyle(.iconOnly)
                .fixedSize()
                .disabled(busy)
                .help("Inspect, terminate or reclaim")
        }
        .padding(DS.Space.s2)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let bot = worker.bot { parts.append("@\(bot)") }
        if let elapsed = status.elapsed { parts.append("working \(elapsed)") }
        parts.append("run #\(worker.runId)")
        if let pid = worker.workerPid { parts.append("pid \(pid)") }
        return parts.joined(separator: " · ")
    }
}

/// Inspect: the run record (status, profile, summary, error), the worker process, then the log tail.
struct KanbanRunInspectionView: View {
    let inspection: KanbanWorkersModel.Inspection
    let onOpenTask: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                Button { onOpenTask(inspection.worker.taskId) } label: {
                    Label(inspection.worker.taskTitle.isEmpty ? inspection.worker.taskId : inspection.worker.taskTitle,
                          systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                .buttonStyle(.plain).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                ForEach(inspection.problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle").font(DS.Typeface.meta).foregroundStyle(DS.Palette.attention)
                }
                ForEach(Self.rows(inspection), id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                        Text(row.label).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .frame(width: DS.Kanban.inspectLabelWidth, alignment: .leading)
                        Text(row.value).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                    }
                }
                if let log = inspection.log {
                    Text(log.truncated ? "Worker log (last part)" : "Worker log").font(DS.Typeface.metaStrong)
                    Text(log.exists && !log.content.isEmpty ? log.content : "The worker has not written a log yet.")
                        .font(DS.Typeface.code).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s2)
                        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
            }
        }
    }

    struct Row: Equatable { let label: String; let value: String }

    /// The facts the server sent, as label/value rows; an absent value drops its row.
    static func rows(_ i: KanbanWorkersModel.Inspection) -> [Row] {
        var out: [Row] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { out.append(Row(label: label, value: value)) }
        }
        add("Status", i.run.map { r in [r.status, r.outcome].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") })
        add("Profile", (i.run?.profile ?? i.worker.bot).map { "@\($0)" })
        add("Summary", i.run?.summary)
        add("Error", i.run?.error)
        if let p = i.process {
            if p.alive {
                var parts: [String] = []
                if let pid = p.pid { parts.append("pid \(pid)") }
                if let s = p.status { parts.append(s) }
                if let cpu = p.cpuPercent { parts.append(String(format: "CPU %.0f%%", cpu)) }
                if let rss = p.memoryRSSBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(rss), countStyle: .memory)) }
                if let t = p.threads { parts.append("\(t) threads") }
                if let e = p.error { parts.append(e) }
                add("Process", parts.isEmpty ? "running" : parts.joined(separator: " · "))
            } else {
                add("Process", "not running" + (p.reason.map { " (\($0))" } ?? ""))
            }
        }
        return out
    }
}
