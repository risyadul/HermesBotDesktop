import Foundation

/// B16: the "N files changed" card under a turn, as Hermes Desktop derives it
/// (`components/assistant-ui/thread/changed-files.ts`, helpers in `tool/fallback-model/index.ts`): the turn's
/// file-edit tool calls (`edit_file`, `patch`, `write_file`) folded into one row per file, in first-touched
/// order, with the +/− lines of every edit to that file summed. Only landed edits with a diff count: a call
/// still running has no result and a failed one changed nothing. History rows carry no results or diffs, so
/// the card appears for turns this client watched.
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// The path exactly as the tool reported it (absolute or relative to the bot's working directory).
    public let path: String
    public let name: String
    public var added: Int
    public var removed: Int
    /// Every diff of this file in the turn, in order (shown when the row is expanded).
    public var diffs: [String]

    public init(path: String, added: Int, removed: Int, diffs: [String]) {
        self.path = path; self.name = ChangedFiles.basename(path); self.added = added; self.removed = removed; self.diffs = diffs
    }
}

public enum ChangedFiles {
    public static let editTools: Set<String> = ["edit_file", "patch", "write_file"]

    /// One row per file the tool lines in `lines` edited.
    public static func derive(_ lines: [ChatLine]) -> [ChangedFile] {
        var order: [String] = []
        var byPath: [String: ChangedFile] = [:]
        for line in lines {
            guard line.role == .tool, let tool = line.tool, editTools.contains(tool.name), tool.state == .done else { continue }
            let diff = stripChrome(tool.inlineDiff ?? diffField(tool.result) ?? "")
            guard !diff.isEmpty, let path = path(args: tool.args, result: tool.result) else { continue }
            let stats = lineStats(diff)
            if var f = byPath[path] {
                f.added += stats.added; f.removed += stats.removed; f.diffs.append(diff)
                byPath[path] = f
            } else {
                order.append(path)
                byPath[path] = ChangedFile(path: path, added: stats.added, removed: stats.removed, diffs: [diff])
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// Desktop `countDiffLineStats`: `+`/`-` lines, file headers (`+++`/`---`) left out.
    public static func lineStats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 } else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// Desktop `fileEditPath`: `path`/`file`/`filepath` from the arguments, then the result (plus `resolved_path`).
    static func path(args: JSONValue?, result: JSONValue?) -> String? {
        for (v, keys) in [(args, ["path", "file", "filepath"]), (result, ["path", "file", "filepath", "resolved_path"])] {
            for k in keys {
                if let s = v?[k]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
        }
        return nil
    }

    /// A result's own `inline_diff` / `diff` (when `tool.complete` sent no top-level `inline_diff`).
    static func diffField(_ result: JSONValue?) -> String? {
        for k in ["inline_diff", "diff"] {
            if let s = result?[k]?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    /// Desktop `stripInlineDiffChrome`: ANSI escapes and the `┊ review diff` banner go.
    static func stripChrome(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        if let r = t.range(of: "^\\s*┊\\s*review diff\\s*\\n", options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func basename(_ path: String) -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return parts.last.map(String.init) ?? path
    }

    /// The tool lines of each FINISHED turn that changed files, keyed by the id of the turn's last line (the
    /// card sits under it). A turn is finished once a user line follows it, or when `busy` is false for the last.
    public static func cards(_ lines: [ChatLine], busy: Bool) -> [UUID: [ChangedFile]] {
        var out: [UUID: [ChangedFile]] = [:]
        var turn: [ChatLine] = []
        func flush(finished: Bool) {
            defer { turn = [] }
            guard finished, let last = turn.last else { return }
            let files = derive(turn)
            if !files.isEmpty { out[last.id] = files }
        }
        for line in lines {
            if line.role == .user { flush(finished: true) } else { turn.append(line) }
        }
        flush(finished: !busy)
        return out
    }
}
