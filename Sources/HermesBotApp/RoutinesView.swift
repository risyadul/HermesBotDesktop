import HermesGatewayKit
import SwiftUI

// Routines sheet (roadmap A15), opened from the Routines button in a Bot Chat's toolbar: the bot's scheduled
// jobs (list, pause/resume, delete with confirmation, details) and the create form with the schedule picker.
// One sheet with three pages (list, details, new) so no sheet is stacked on a sheet.

extension DS {
    enum Routines {
        static let sheetWidth: CGFloat = 520
        static let sheetHeight: CGFloat = 560
        static let instructionHeight: CGFloat = 88
        static let labelWidth: CGFloat = 120
        static let numberWidth: CGFloat = 64
    }
}

/// The Bot Chat toolbar entry point. It builds the sheet's model from the current connection when opened.
struct RoutinesToolbarButton: View {
    let bot: Bot
    @State private var shown = false
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        Button { shown = true } label: { Label("Routines", systemImage: "clock.arrow.circlepath") }
            .help("Routines: scheduled tasks for @\(bot.name)")
            .motionSheet(isPresented: $shown, motion: motion) {
                RoutinesSheet(bot: bot, context: .current(), onClose: { shown = false })
            }
    }
}

/// What the sheet needs from the connection: the RPC, `hermes serve`'s launch profile and whether this app
/// started (owns) the backend.
struct RoutinesContext {
    let call: RoutinesAPI.Call?
    let launchProfile: String
    let ownsBackend: Bool

    @MainActor static func current(_ app: AppModel = .shared) -> RoutinesContext {
        var call: RoutinesAPI.Call?
        if let client = app.backend?.client {
            call = { method, params in try await client.call(method, params) }
        }
        let launch = app.bots.first { $0.isDefault }?.name ?? Routines.launchProfile
        return RoutinesContext(call: call, launchProfile: launch, ownsBackend: app.backend?.owned != nil)
    }

    static let disconnected: RoutinesAPI.Call = { _, _ in throw GatewayClient.ClientError.notConnected }
}

struct RoutinesSheet: View {
    enum Page: Equatable { case list, detail(String), create }

    let bot: Bot
    let ownsBackend: Bool
    let onClose: () -> Void
    @StateObject private var model: RoutinesModel
    @State private var page = Page.list
    @State private var deleteCandidate: RoutineJob?
    @ObservedObject private var avatars = AvatarStore.shared

    init(bot: Bot, context: RoutinesContext, onClose: @escaping () -> Void) {
        self.bot = bot
        self.ownsBackend = context.ownsBackend
        self.onClose = onClose
        _model = StateObject(wrappedValue: RoutinesModel(bot: bot.name, launchProfile: context.launchProfile,
                                                         api: RoutinesAPI(call: context.call ?? RoutinesContext.disconnected)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            header
            if let hint = RoutineText.backgroundHint(ownsBackend: ownsBackend) {
                Label(hint, systemImage: "moon.zzz")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            messages
            Group {
                switch page {
                case .list: list
                case .detail(let id):
                    if let job = model.job(id) {
                        RoutineDetailView(job: job, model: model, onDelete: { deleteCandidate = job })
                    } else {
                        EmptyStateView(symbol: "clock.badge.questionmark", title: "Routine not found",
                                       message: "It is no longer in this bot's scheduled jobs.")
                    }
                case .create:
                    RoutineCreateForm(model: model, botTitle: bot.title, onDone: { page = .list })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if page != .create {
                HStack {
                    Spacer()
                    Button("Done") { onClose() }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Routines.sheetWidth, height: DS.Routines.sheetHeight)
        .background(DS.Palette.window)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("Delete “\(deleteCandidate.map { Routines.title($0.name) } ?? "")”?",
                            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let job = deleteCandidate {
                    Task {
                        if await model.remove(job), page == .detail(job.id) { page = .list }
                    }
                }
                deleteCandidate = nil
            }
        } message: { Text("It stops firing immediately. This cannot be undone.") }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            if page != .list {
                IconButton(symbol: "chevron.left", label: "Back to routines") { page = .list }
            }
            AvatarView(identity: avatars.identity(profile: bot.name, title: bot.title), size: DS.Size.avatarRow)
            VStack(alignment: .leading, spacing: 0) {
                Text(pageTitle).font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink).lineLimit(1)
                Text("\(bot.title) · @\(bot.name)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            Spacer()
            if page == .list {
                Button { model.dismissMessages(); page = .create } label: { Label("New Routine", systemImage: "plus") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        }
    }

    private var pageTitle: String {
        switch page {
        case .list: return "Routines"
        case .create: return "New routine"
        case .detail(let id): return model.job(id).map { Routines.title($0.name) } ?? "Routine"
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = model.actionError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
        } else if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle").font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
        } else if model.refreshError != nil {
            Label("Could not refresh scheduled jobs. Showing the last list we had.", systemImage: "arrow.clockwise")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
        }
    }

    @ViewBuilder private var list: some View {
        switch model.phase {
        case .loading:
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "Loading routines", message: "Asking Hermes for this bot's scheduled jobs.") {
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Failed to load routines",
                           message: "The list may still be there — this was a read failure, not a delete. (\(message))") {
                Button("Try Again") { Task { await model.refresh() } }.buttonStyle(DSButtonStyle(kind: .primary))
            }
        case .ready:
            if model.jobs.isEmpty {
                EmptyStateView(symbol: "clock", title: "No routines yet",
                               message: model.filterHint ?? "Schedule a prompt for this bot: Hermes runs it on time and keeps the result in the run history or sends it to Bot Chat.") {
                    Button("New Routine") { page = .create }.buttonStyle(DSButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s2) {
                        ForEach(model.jobs) { job in
                            RoutineRow(job: job, model: model, onOpen: { page = .detail(job.id) },
                                       onDelete: { deleteCandidate = job })
                        }
                    }
                }
            }
        }
    }
}

/// A routine in the list: status dot and title (opens the details), the active switch, delete; then the
/// schedule and the next run.
struct RoutineRow: View {
    let job: RoutineJob
    @ObservedObject var model: RoutinesModel
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let active = model.isActive(job)
        let legacy = Routines.isLegacyDelegated(job)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Button(action: onOpen) {
                    HStack(spacing: DS.Space.s2) {
                        Circle().fill(active ? DS.Palette.statusOK : DS.Palette.muted)
                            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                        Text(Routines.title(job.name)).font(DS.Typeface.bodyMedium)
                            .foregroundStyle(active ? DS.Palette.ink : DS.Palette.muted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show details")
                if model.busy.contains(job.id) { ProgressView().controlSize(.small) }
                Toggle("Active", isOn: Binding(get: { active }, set: { on in Task { await model.setActive(job, on) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(model.busy.contains(job.id) || legacy)
                    .help(active ? "Pause" : "Resume")
                IconButton(symbol: "trash", label: "Delete") { onDelete() }
                    .disabled(model.busy.contains(job.id))
            }
            HStack(spacing: DS.Space.s2) {
                Label(RoutineText.scheduleLabel(job.schedule), systemImage: "calendar")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s0)
                    .overlay(Capsule().strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.ring))
                Spacer(minLength: DS.Space.s2)
                Text(RoutineText.nextLine(job, active: active, now: Date()))
                    .font(DS.Typeface.caption)
                    .foregroundStyle(RoutineText.isOverdue(job, now: Date()) && active ? DS.Palette.attention : DS.Palette.muted)
            }
            .padding(.leading, DS.Size.statusDot + DS.Space.s2)
            if legacy {
                Text(RoutineText.legacyUnsafe).font(DS.Typeface.meta).foregroundStyle(DS.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.s2)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A routine's details, from the list payload (no extra RPC): issue, facts, instruction; Pause/Resume, Delete.
struct RoutineDetailView: View {
    let job: RoutineJob
    @ObservedObject var model: RoutinesModel
    let onDelete: () -> Void

    var body: some View {
        let active = model.isActive(job)
        let legacy = Routines.isLegacyDelegated(job)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                if legacy {
                    Text(RoutineText.legacyUnsafe).font(DS.Typeface.meta).foregroundStyle(DS.Palette.attention)
                }
                if let issue = RoutineText.issue(job) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
                        .padding(DS.Space.s2).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.dangerRing, lineWidth: DS.Stroke.ring))
                }
                ForEach(RoutineText.detailRows(job, active: active, now: Date()), id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                        Text(row.label).font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                            .frame(width: DS.Routines.labelWidth, alignment: .leading)
                        Text(row.value).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                    }
                }
                if !job.promptPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Instruction").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                    Text(job.promptPreview).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s2)
                        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
                HStack(spacing: DS.Space.s2) {
                    Button(active ? "Pause" : "Resume") { Task { await model.setActive(job, !active) } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(model.busy.contains(job.id) || legacy)
                    Button("Delete…", role: .destructive) { onDelete() }
                        .buttonStyle(DSButtonStyle(kind: .danger))
                        .disabled(model.busy.contains(job.id))
                }
            }
        }
    }
}

/// The create form: name, instruction, the schedule picker, "Stop after N runs", where results go, continuity.
struct RoutineCreateForm: View {
    @ObservedObject var model: RoutinesModel
    let botTitle: String
    let onDone: () -> Void
    @State private var draft = RoutinesModel.Draft()
    @State private var error: String?
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private var timeLabel: String { RoutineSchedule.timeLabel(draft.schedule.time) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    Text("A recurring task \(botTitle) runs on a schedule.")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    labeled("Name") {
                        TextField("Morning briefing", text: $draft.title).textFieldStyle(.roundedBorder).labelsHidden()
                            .focused($nameFocused)
                    }
                    labeled("Instruction") {
                        TextEditor(text: $draft.instruction)
                            .font(DS.Typeface.body)
                            .scrollContentBackground(.hidden)
                            .padding(DS.Space.s1)
                            .frame(height: DS.Routines.instructionHeight)
                            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
                    }
                    labeled("When to run") { RoutineSchedulePicker(schedule: $draft.schedule, timeLabel: timeLabel) }
                    labeled("Send results to") {
                        Picker("Send results to", selection: $draft.deliverToBotChat) {
                            Text("Run history only").tag(false)
                            Text("\(botTitle)’s chat (bot responds)").tag(true)
                        }
                        .labelsHidden()
                    }
                    Toggle("Continuity: each run sees the previous run’s output (dedupe, continue where it left off)",
                           isOn: $draft.continuity)
                        .toggleStyle(.checkbox).font(DS.Typeface.meta)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s2) {
                Spacer()
                Button("Cancel") { onDone() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(creating)
                Button(creating ? "Saving…" : "Create") { create() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || RoutinesModel.blocker(draft) != nil)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !creating else { return }
        creating = true
        error = nil
        Task {
            error = await model.create(draft)
            creating = false
            if error == nil { onDone() }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
            content()
        }
    }
}

/// Frequency first, then only the detail it needs; a one-line read-back with the schedule string.
struct RoutineSchedulePicker: View {
    @Binding var schedule: RoutineSchedule
    let timeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Picker("Frequency", selection: $schedule.frequency) {
                    ForEach(RoutineSchedule.Frequency.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                if schedule.needsTime {
                    Picker("Time", selection: $schedule.time) {
                        ForEach(RoutineSchedule.times, id: \.id) { Text(RoutineSchedule.timeLabel($0.id)).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }
            switch schedule.frequency {
            case .once:
                HStack(spacing: DS.Space.s2) {
                    number("30", $schedule.onceN)
                    unitPicker($schedule.onceUnit, fromNow: true)
                }
            case .weekly:
                Picker("Day", selection: $schedule.weekday) {
                    ForEach(RoutineSchedule.weekdays, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
            case .monthly:
                HStack(spacing: DS.Space.s2) {
                    Text("Day of month").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    number("1", $schedule.monthday, max: 2)
                }
            case .interval:
                HStack(spacing: DS.Space.s2) {
                    Text("Every").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    number("2", $schedule.intervalN)
                    unitPicker($schedule.intervalUnit, fromNow: false)
                }
            case .advanced:
                TextField("every 1d · every 2h · 0 9 * * * (cron)", text: $schedule.raw)
                    .textFieldStyle(.roundedBorder).font(DS.Typeface.code).labelsHidden()
            case .hourly, .daily, .weekdays:
                EmptyView()
            }
            if schedule.offersRepeat {
                HStack(spacing: DS.Space.s2) {
                    Text("Stop after").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                    number("∞", $schedule.repeatN)
                    Text("runs (blank = forever)").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
            }
            Text("\(schedule.summary(timeLabel: timeLabel)) · \(schedule.composed.isEmpty ? "—" : schedule.composed)")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
    }

    private func number(_ placeholder: String, _ text: Binding<String>, max: Int = 4) -> some View {
        TextField(placeholder, text: Binding(get: { text.wrappedValue },
                                             set: { text.wrappedValue = RoutineSchedule.digits($0, max: max) }))
            .textFieldStyle(.roundedBorder).labelsHidden()
            .frame(width: DS.Routines.numberWidth)
    }

    private func unitPicker(_ unit: Binding<RoutineSchedule.Unit>, fromNow: Bool) -> some View {
        Picker("Unit", selection: unit) {
            ForEach(RoutineSchedule.Unit.allCases) { Text(fromNow ? $0.fromNow : $0.word).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
