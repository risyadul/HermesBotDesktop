import AppKit
import HermesGatewayKit
import UniformTypeIdentifiers

/// B15: Export a Bot Chat as Markdown, from the transcript as loaded (the chat's history plus this
/// launch's turns). Messages keep their markdown; each turn's tool calls are one quoted summary line
/// each (title, summary, state, duration); arguments, results and Thought rows are left out, and every
/// piece of text goes through `Redaction.scrub`, so session tokens and auth headers never reach the file.
/// The @mention note sent to the model is not part of a user message (stripped when the history loads).
/// Pure, unit tested (ChatExportTests); `save` adds the save panel.
enum ChatExport {
    static func markdown(bot: Bot, lines: [ChatLine], exportedAt: Date, locale: Locale = .current) -> String {
        let stamp = { (d: Date) in d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)) }
        var out = ["# Bot Chat with \(scrub(bot.title))", "",
                   "Exported from Herald on \(stamp(exportedAt)). Profile `\(scrub(bot.name))`."]
        for item in TranscriptItem.build(lines) {
            switch item {
            case .line(let line, let header):
                if TranscriptItem.isBotSide(line.role), header { out += ["", heading(bot.title, at: line.at, stamp: stamp)] }
                out += block(line, stamp: stamp)
            case .tools(let tools, let header):
                if header { out += ["", heading(bot.title, at: tools.first?.at, stamp: stamp)] }
                out += [""] + tools.map(toolLine)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func heading(_ who: String, at: Date?, stamp: (Date) -> String) -> String {
        "## \(scrub(who))" + (at.map { " · \(stamp($0))" } ?? "")
    }

    private static func block(_ line: ChatLine, stamp: (Date) -> String) -> [String] {
        let text = scrub(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
        switch line.role {
        case .user:
            guard !text.isEmpty else { return [] }
            if let notice = SystemNotice.parse(line.text) { return ["", "> _Hermes note: \(scrub(notice.title))_"] }
            return ["", heading("You", at: line.at, stamp: stamp), "", text]
        case .bot:
            guard !text.isEmpty else { return [] }
            return ["", text] + (line.turnDuration.map { ["", "_Replied in \(MessageTime.elapsed($0))._"] } ?? [])
        case .tool: return ["", toolLine(line)]
        case .error: return text.isEmpty ? [] : ["", quoted("**Error:** " + text)]
        case .system: return text.isEmpty ? [] : ["", quoted(text)]
        case .thought: return []
        }
    }

    /// "> Tool: Ran git status — 3 items (failed, 1.2s)".
    static func toolLine(_ line: ChatLine) -> String {
        let p = ToolRowPresentation(line)
        var s = "Tool: " + p.title
        if let detail = p.summary ?? p.count { s += " — " + ToolRowPresentation.oneLine(detail) }
        let meta = [p.state == .failed ? "failed" : nil, p.duration].compactMap { $0 }
        if !meta.isEmpty { s += " (" + meta.joined(separator: ", ") + ")" }
        return "> " + scrub(s)
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    private static func scrub(_ s: String) -> String { Redaction.scrub(s) }

    /// "<bot>-bot-chat-2026-11-06.md", lowercased, only `[a-z0-9._-]`.
    static func filename(bot: Bot, date: Date, calendar: Calendar = .current) -> String {
        let base = bot.title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(base.isEmpty ? "bot" : String(base.prefix(48)))-bot-chat-\(day).md"
    }

    /// Save panel, then an atomic write. A failure is shown as a note in the chat.
    @MainActor static func save(_ chat: ChatModel) {
        let now = Date()
        let text = markdown(bot: chat.bot, lines: chat.lines, exportedAt: now)
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.message = "Save \(chat.bot.title)'s Bot Chat as Markdown. Tool arguments, results and reasoning are not included."
        panel.nameFieldStringValue = filename(bot: chat.bot, date: now)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            chat.log("bot chat exported: profile=\(chat.bot.name) lines=\(chat.lines.count)")
        } catch {
            chat.transcript.appendSystem("Export failed: \(Redaction.describe(error))")
        }
    }
}
