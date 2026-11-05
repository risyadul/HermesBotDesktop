import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - B10 error card

/// An error line as an actionable card (Hermes Desktop's layered error card, `assistant-message.tsx`): the
/// error, its raw details behind a disclosure, and Retry / Switch Provider / Copy Diagnostics / Dismiss.
struct ErrorCardRow: View {
    let line: ChatLine
    let plan: ErrorRecoveryPlan
    var canAct = true
    let onRetry: () -> Void
    let onSwitchProvider: () -> Void
    let onCopyDiagnostics: () -> Void
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.danger)
                Text(Self.headline(line)).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Dismiss", action: onDismiss)
            }
            if let details = Self.details(line) {
                DisclosureGroup("Details") {
                    Text(details).font(DS.Typeface.code).foregroundStyle(DS.Palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            }
            HStack(spacing: DS.Space.s2) {
                if plan.retry {
                    Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(DSButtonStyle(kind: .primary)).disabled(!canAct)
                        .help("Run the failed prompt again")
                }
                if plan.switchProvider {
                    Button("Switch Provider", action: onSwitchProvider)
                        .buttonStyle(DSButtonStyle(kind: .secondary)).disabled(!canAct)
                        .help("Pick another model or provider for this chat")
                }
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    onCopyDiagnostics()
                    copied = true
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .help("Copy the error details (secrets removed)")
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
        .background(DS.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.dangerRing, lineWidth: DS.Stroke.hairline))
        .padding(.leading, DS.Size.contentInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(Self.headline(line))")
    }

    /// The card's title: Desktop's per-layer wording when the failure names a layer, else the error line.
    nonisolated static func headline(_ line: ChatLine) -> String {
        guard let s = line.failure?.surface else { return line.text }
        switch s.layer {
        case "auth": return "The provider rejected the credentials for this model."
        case "billing": return "The provider refused the request for billing or quota reasons."
        case "provider", "endpoint": return "The model provider could not complete the request."
        case "streaming": return "The reply stream was interrupted."
        case "disk": return "The disk is full, so Hermes could not continue."
        default: return line.text
        }
    }

    /// The raw error text when the headline does not already show it.
    nonisolated static func details(_ line: ChatLine) -> String? {
        guard let f = line.failure, f.surface != nil else { return nil }
        let raw = f.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw == headline(line) ? nil : raw
    }
}

// MARK: - B16 changed-files card

/// "N files changed" under a finished turn (Desktop `changed-files-card.tsx`): one row per file with its +/−
/// counts; a row expands to its diff; Reveal in Finder re-checks the path at click time (`MediaSafety`, as
/// every bot-named path: protected places are refused, nothing is opened).
struct ChangedFilesCard: View {
    let files: [ChangedFile]
    @State private var open: Set<String> = []
    @State private var revealErrors: [String: String] = [:]
    @Environment(\.motionEnabled) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "doc.badge.ellipsis").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                Text(Self.title(files)).font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                Spacer(minLength: 0)
                DiffStat(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
            }
            .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
            ForEach(files) { file in
                Hairline()
                row(file)
            }
        }
        .frame(maxWidth: DS.Size.cardWidth, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(files))
    }

    nonisolated static func title(_ files: [ChangedFile]) -> String {
        files.count == 1 ? "1 file changed" : "\(files.count) files changed"
    }

    @ViewBuilder private func row(_ file: ChangedFile) -> some View {
        let expanded = open.contains(file.path)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Button {
                    withDSAnimation(motion, DS.Motion.ease) {
                        if expanded { open.remove(file.path) } else { open.insert(file.path) }
                    }
                } label: {
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: "chevron.right").font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(VisibleText.reveal(file.name)).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        DiffStat(added: file.added, removed: file.removed)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(VisibleText.reveal(file.path))
                .accessibilityLabel("\(file.name), \(file.added) added, \(file.removed) removed")
                .accessibilityHint(expanded ? "Hides the changes" : "Shows the changes")
                IconButton(symbol: "folder", label: "Reveal \(file.name) in Finder") { reveal(file) }
                    .disabled(!Self.canReveal(file.path))
                    .help(Self.canReveal(file.path) ? "Reveal in Finder" : Self.relativeNote)
            }
            if let why = revealErrors[file.path] {
                Text(why).font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
            }
            if expanded {
                ForEach(Array(file.diffs.enumerated()), id: \.offset) { _, diff in
                    DiffText(diff: diff)
                }
                .transition(motion ? .opacity : .identity)
            }
        }
        .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
    }

    /// Only an absolute path can be checked and revealed: a relative one is relative to the bot's working
    /// folder, which the app does not know.
    nonisolated static func canReveal(_ path: String) -> Bool { path.hasPrefix("/") }
    nonisolated static let relativeNote = "Hermes reported this path relative to the bot's working folder, so it can't be shown in Finder."

    private func reveal(_ file: ChangedFile) {
        let ref = MediaRef(path: file.path, kind: .file)
        Task {
            let fresh = await MediaActions.reveal(ref)
            if case .unavailable(let reason) = fresh { revealErrors[file.path] = reason } else { revealErrors[file.path] = nil }
        }
    }
}

/// `+12 −3` in the status colours (added in the OK colour, removed in danger).
struct DiffStat: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Text("+\(added)").foregroundStyle(DS.Palette.statusOK)
            Text("−\(removed)").foregroundStyle(DS.Palette.danger)
        }
        .font(DS.Typeface.caption).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) lines added, \(removed) removed")
    }
}

/// A unified diff, `+` lines in the OK colour and `-` lines in danger, capped at `maxLines`.
struct DiffText: View {
    let diff: String
    static let maxLines = 400

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(Self.attributed(diff))
                .font(DS.Typeface.code)
                .lineSpacing(DS.Typeface.codeLineSpacing)
                .textSelection(.enabled)
                .fixedSize()
                .padding(DS.Space.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.window, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    static func attributed(_ diff: String) -> AttributedString {
        let all = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var out = AttributedString()
        for (i, line) in all.prefix(maxLines).enumerated() {
            var a = AttributedString(String(line) + (i < min(all.count, maxLines) - 1 ? "\n" : ""))
            if line.hasPrefix("+") && !line.hasPrefix("+++") { a.foregroundColor = DS.Palette.statusOK } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                a.foregroundColor = DS.Palette.danger
            } else { a.foregroundColor = DS.Palette.ink }
            out += a
        }
        if all.count > maxLines {
            var more = AttributedString("\n… \(all.count - maxLines) more lines")
            more.foregroundColor = DS.Palette.muted
            out += more
        }
        return out
    }
}

// MARK: - B3 edit sheet, B11 URL dialog

/// Edit a sent message: the text comes back editable; Send Edit reruns the conversation from it.
struct MessageEditSheet: View {
    @State var text: String
    let hadAttachments: Bool
    let onSend: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text("Edit Message").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            Text("Everything after this message is removed from the conversation, and the edited message runs again from here.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(DS.Typeface.body)
                .frame(minHeight: 120)
                .padding(DS.Space.s1)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                .accessibilityLabel("Message text")
            if hadAttachments {
                Text("Attachments of the original message are not sent again.")
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(DSButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button("Send Edit") { onSend(text) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
    }
}

/// Attach URL (Desktop `url-dialog.tsx`): an `http(s)://` link is attached as `@url:` context.
struct AttachURLSheet: View {
    @State private var value = ""
    let onAttach: (String) -> Bool
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var looksLikeURL: Bool { ContextRef.url(value) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Label("Attach URL", systemImage: "globe").font(DS.Typeface.titlePane).foregroundStyle(DS.Palette.ink)
            Text("The bot reads the page when your message runs.")
                .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            TextField("https://example.com/page", text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if looksLikeURL { _ = onAttach(value) } }
                .accessibilityLabel("URL")
            if !value.trimmingCharacters(in: .whitespaces).isEmpty && !looksLikeURL {
                Text("Enter a web address starting with https://").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(DSButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button("Attach") { _ = onAttach(value) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!looksLikeURL)
            }
        }
        .padding(DS.Space.s5)
        .frame(width: DS.Size.sheetWidth)
        .background(DS.Palette.window)
        .onAppear { focused = true }
    }
}
