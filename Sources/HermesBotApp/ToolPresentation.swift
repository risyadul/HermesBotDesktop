import Foundation
import HermesGatewayKit

/// What a tool row shows, derived from a `.tool` transcript line (unit tested). Titles follow Hermes
/// Desktop (`fallback-model/index.ts:1442-1458`): "Ran <command>" for `terminal`, "Ran code <first line>"
/// for `execute_code`, the connector label ("Atlassian · getjiraissue") for MCP/connector calls.
struct ToolRowPresentation: Equatable {
    let name: String
    /// The row's title: a sentence for known tools, else the tool name.
    let title: String
    /// Muted text after a bare tool name (its context preview); nil when the title already says it.
    let context: String?
    let summary: String?
    let state: ToolLine.State
    let duration: String?
    /// Count read from the result, e.g. "3 items", "360 stdout_bytes".
    let count: String?
    let category: ToolCategory
    private let args: JSONValue?
    private let result: JSONValue?
    private let diff: String?

    init(_ line: ChatLine) {
        let tool = line.tool
        name = tool?.name ?? "tool"
        state = tool?.state ?? .done
        duration = tool?.duration.map(Self.format)
        category = ToolCategory(name)
        let preview = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = tool?.summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        count = tool?.result.flatMap(Self.countLabel)
        args = tool?.args
        result = tool?.result
        diff = tool?.inlineDiff
        let headline = Self.headline(name: name, label: tool?.label, args: args, preview: preview)
        title = headline.title
        context = headline.context
    }

    /// What expanding the row shows, in order. Built on demand (only an expanded row asks): pretty-printing a
    /// large result on every body evaluation of a collapsed row would stall streaming.
    var details: [ToolDetail] { Self.details(name: name, args: args, result: result, diff: diff, summary: summary) }

    /// "0.4s", "12s", "2m 05s".
    static func format(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", max(0, seconds)) }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    var symbol: String? {
        switch state {
        case .running: return nil
        case .done: return category.symbol
        case .failed: return "xmark.circle.fill"
        }
    }

    /// Cheap check matching `details` being non-empty.
    var expandable: Bool {
        if diff != nil || summary != nil { return true }
        switch name {
        case "terminal": if args?["command"]?.string != nil { return true }
        case "execute_code": if args?["code"]?.string != nil { return true }
        default: if let args, args != .object([:]) { return true }
        }
        guard let result else { return false }
        if let s = result.string { return !s.isEmpty }
        return true
    }

    var accessibilityLabel: String {
        let status: String
        switch state {
        case .running: status = "running"
        case .done: status = "done"
        case .failed: status = "failed"
        }
        return [title, context, count, status, duration].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - title

    private static func headline(name: String, label: String?, args: JSONValue?, preview: String)
        -> (title: String, context: String?) {
        if let label, !label.isEmpty { return (label, nil) }
        func arg(_ keys: String...) -> String? {
            for k in keys { if let s = args?[k]?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s } }
            return nil
        }
        let fallback = preview.isEmpty ? nil : preview
        switch name {
        case "terminal":
            if let c = arg("command") ?? fallback { return ("Ran " + summarizeCommand(c), nil) }
        case "execute_code":
            if let c = arg("code") ?? fallback { return ("Ran code " + summarizeCommand(c), nil) }
        case "read_file":
            if let p = arg("path", "file_path") ?? fallback { return ("Read " + oneLine(p), nil) }
        case "write_file", "patch":
            if let p = arg("path", "file_path") ?? fallback { return ("Edited " + oneLine(p), nil) }
        case "search_files":
            if let q = arg("pattern", "query") ?? fallback { return ("Searched " + oneLine(q), nil) }
        case "web_search":
            if let q = arg("query") ?? fallback { return ("Searched the web for " + oneLine(q), nil) }
        case "web_extract":
            if let u = arg("url") ?? fallback { return ("Opened " + oneLine(u), nil) }
        default:
            break
        }
        return (name, fallback.map { oneLine($0) })
    }

    /// One line of a shell command or code: Desktop's `summarizeShellCommand` (`lib/summarize-command.ts`),
    /// then cut to 160 characters.
    static func summarizeCommand(_ command: String) -> String { oneLine(ShellSummary.summarize(command)) }

    static func oneLine(_ s: String, limit: Int = 160) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    // MARK: - meta

    /// Array results count as items; then the first number under a `*_count` / `*_total` key, named without
    /// the suffix (`fallback-model/index.ts:457-492`; `stdout_bytes_total` → "360 stdout_bytes").
    static func countLabel(_ result: JSONValue) -> String? {
        if let items = result.array { return items.isEmpty ? nil : plural(items.count, "item") }
        guard case .object(let o) = result else { return nil }
        for key in ["items", "results", "matches", "files", "entries"] {
            if let a = o[key]?.array { return plural(a.count, "item") }
        }
        for key in o.keys.sorted() {
            for suffix in ["_count", "_total"] where key.hasSuffix(suffix) {
                // `Int(exactly:)`: a whole number too big for Int (untrusted data) is skipped, not a trap.
                if let n = o[key]?.double, n >= 0, let i = Int(exactly: n) {
                    return "\(i) \(key.dropLast(suffix.count))"
                }
            }
        }
        return nil
    }

    static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    // MARK: - details

    /// Longest text shown in an expanded row; the rest is cut with a note (Copy still copies what is shown).
    static let detailLimit = 20_000

    private static func details(name: String, args: JSONValue?, result: JSONValue?, diff: String?, summary: String?)
        -> [ToolDetail] {
        var out: [ToolDetail] = []
        switch name {
        case "terminal":
            if let c = args?["command"]?.string { out.append(.code(label: "Command", language: "bash", text: c)) }
        case "execute_code":
            if let c = args?["code"]?.string { out.append(.code(label: "Code", language: "python", text: c)) }
        default:
            if let args, args != .object([:]) { out.append(.code(label: "Arguments", language: "json", text: pretty(args))) }
        }
        if let diff { out.append(.code(label: "Changes", language: "diff", text: diff)) }
        if let summary { out.append(.text(label: "Summary", text: summary)) }
        if let result { out.append(contentsOf: resultDetails(result)) }
        return out.map(\.capped)
    }

    /// Shell-like results show their output streams and exit code; anything else is shown as JSON.
    private static func resultDetails(_ result: JSONValue) -> [ToolDetail] {
        if let s = result.string { return s.isEmpty ? [] : [.code(label: "Output", language: nil, text: s)] }
        guard case .object(let o) = result else { return [.code(label: "Result", language: "json", text: pretty(result))] }
        var out: [ToolDetail] = []
        func text(_ key: String) -> String? {
            o[key]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if let s = text("output") ?? text("stdout") { out.append(.code(label: "Output", language: nil, text: s)) }
        if let s = text("stderr") { out.append(.code(label: "Errors", language: nil, text: s)) }
        if let s = text("error") { out.append(.code(label: "Error", language: nil, text: s)) }
        if let code = (o["exit_code"]?.double ?? o["returncode"]?.double).flatMap({ Int(exactly: $0) }) {
            out.append(.text(label: "Exit code", text: "\(code)"))
        }
        return out.isEmpty ? [.code(label: "Result", language: "json", text: pretty(result))] : out
    }

    static func pretty(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? v.compactJSON()
    }
}

enum ToolDetail: Equatable {
    case code(label: String, language: String?, text: String)
    case text(label: String, text: String)

    var capped: ToolDetail {
        let limit = ToolRowPresentation.detailLimit
        switch self {
        case .code(let l, let lang, let t) where t.count > limit:
            return .code(label: l, language: lang, text: String(t.prefix(limit)) + "\n… (\(t.count - limit) more characters)")
        case .text(let l, let t) where t.count > limit:
            return .text(label: l, text: String(t.prefix(limit)) + "…")
        default:
            return self
        }
    }
}

/// How a tool counts in a group summary ("Ran 2 commands, used 1 tool"), in Desktop's clause order
/// (`run-summary.ts:52-81`, `192-235`).
enum ToolCategory: Int, Comparable, CaseIterable {
    case edit, search, read, browse, run, other

    init(_ name: String) {
        switch name {
        case "write_file", "patch": self = .edit
        case "search_files", "web_search", "session_search": self = .search
        case "read_file": self = .read
        case "web_extract": self = .browse
        case "terminal", "execute_code", "process": self = .run
        default: self = name.hasPrefix("browser_") ? .browse : .other
        }
    }

    static func < (a: ToolCategory, b: ToolCategory) -> Bool { a.rawValue < b.rawValue }

    func clause(_ n: Int) -> String {
        switch self {
        case .edit: return "Edited " + ToolRowPresentation.plural(n, "file")
        case .search: return "Searched " + (n == 1 ? "once" : "\(n) times")
        case .read: return "Read " + ToolRowPresentation.plural(n, "file")
        case .browse: return "Opened " + ToolRowPresentation.plural(n, "page")
        case .run: return "Ran " + ToolRowPresentation.plural(n, "command")
        case .other: return "Used " + ToolRowPresentation.plural(n, "tool")
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "pencil"
        case .search: return "magnifyingglass"
        case .read: return "doc.text"
        case .browse: return "globe"
        case .run: return "apple.terminal"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// "Ran 1 command, used 1 tool": clauses in category order, all but the first lowercased.
    static func summary(_ names: [String]) -> String {
        var counts: [ToolCategory: Int] = [:]
        for n in names { counts[ToolCategory(n), default: 0] += 1 }
        let clauses = counts.keys.sorted().map { $0.clause(counts[$0]!) }
        return clauses.enumerated().map { i, c in i == 0 ? c : c.prefix(1).lowercased() + c.dropFirst() }
            .joined(separator: ", ")
    }
}

/// Port of Hermes Desktop's `summarizeShellCommand` (`apps/desktop/src/lib/summarize-command.ts`): agents wrap
/// the real command in plumbing (`cd <dir> && <cmd> 2>&1 | tail -N; echo "x_exit=$?"`), so the title shows
/// the command that matters. Split on top-level `&&` `||` `;` and newlines (quote-aware), strip pipe tails
/// (`| head`, `| tail`, …), drop redirects, skip setup heads (`cd`, `export`, …) and status echoes; one
/// survivor is shown as is, several as "first + N commands". Display only: details keep the full command.
enum ShellSummary {
    static let silentHeads: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":"]
    static let pipeTailHeads: Set<String> = ["head", "tail", "wc", "sort", "uniq"]

    static func summarize(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "" }
        let segments = split(original)
        if segments.count <= 1 {
            let c = clean(original)
            return c.isEmpty ? original : c
        }
        let core = segments.map(clean).filter { !$0.isEmpty && !silentHeads.contains(head($0)) && !isBoundaryEcho($0) }
        if core.isEmpty { return original }
        if core.count == 1 { return core[0] }
        return "\(core[0]) + \(core.count - 1) \(core.count == 2 ? "command" : "commands")"
    }

    static func split(_ input: String) -> [String] {
        var segments: [String] = [], buf = "", quote: Character?
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                buf.append(ch)
                if ch == q && (i == 0 || chars[i - 1] != "\\") { quote = nil }
                i += 1; continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); i += 1; continue }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if (ch == "&" && next == "&") || (ch == "|" && next == "|") {
                segments.append(buf); buf = ""; i += 2; continue
            }
            if ch == ";" || ch == "\n" || ch == "\r\n" { segments.append(buf); buf = ""; i += 1; continue }
            buf.append(ch); i += 1
        }
        segments.append(buf)
        return segments.map { stripPipeTail($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func words(_ segment: String) -> [String] {
        var out: [String] = [], buf = "", quote: Character?
        let chars = Array(segment)
        for (i, ch) in chars.enumerated() {
            if let q = quote {
                buf.append(ch)
                if ch == q && (i == 0 || chars[i - 1] != "\\") { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; buf.append(ch); continue }
            if ch.isWhitespace {
                if !buf.isEmpty { out.append(buf); buf = "" }
                continue
            }
            buf.append(ch)
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    static func basename(_ word: String) -> String { word.split(separator: "/").last.map(String.init) ?? word }

    /// The command word, skipping `FOO=bar` env assignments.
    static func head(_ segment: String) -> String {
        let tokens = words(segment)
        let first = tokens.first { $0.range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) == nil }
        return basename(first ?? "")
    }

    static func stripPipeTail(_ segment: String) -> String {
        let w = words(segment)
        var out: [String] = []
        for (i, word) in w.enumerated() {
            if word == "|", i + 1 < w.count, pipeTailHeads.contains(basename(w[i + 1])) { break }
            out.append(word)
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Drops redirects (`2>&1`, `> file`, `< file`).
    static func clean(_ segment: String) -> String {
        let w = words(segment)
        var out: [String] = []
        var i = 0
        while i < w.count {
            let word = w[i]
            if word.range(of: #"^\d*(?:>>?|<)$"#, options: .regularExpression) != nil { i += 2; continue }
            if word.range(of: #"^\d*(?:>&|<&)\d+$"#, options: .regularExpression) != nil { i += 1; continue }
            out.append(word); i += 1
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Banner and status echoes (`echo "---"`, `echo "x_exit=$?"`), not arbitrary `echo $VALUE`.
    static func isBoundaryEcho(_ segment: String) -> Bool {
        let w = words(segment)
        guard basename(w.first ?? "") == "echo" else { return false }
        let rest = w.dropFirst().joined(separator: " ")
        return rest.range(of: #"-{2,}|_exit=|(?:^|\s|=)\$[?{]|PIPESTATUS"#, options: .regularExpression) != nil
    }
}
