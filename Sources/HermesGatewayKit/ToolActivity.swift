import Foundation

/// `tool.start` payload: `{tool_id, name, context?, args?, args_text?, preview?, labels?}`
/// (`tui_gateway/contracts/events.py:268-280`, emitter `tool_progress.py:276-302`). Rows are keyed by
/// `toolId`; `labels[].text` is rendered as-is, tool names are never parsed (`contracts/common.py:136-154`).
public struct ToolStart: Sendable, Equatable {
    public let toolId: String
    public let name: String
    /// ≈80-char preview of the call.
    public let context: String?
    public let label: String?
    /// The call's arguments (`args`), when sent.
    public let args: JSONValue?

    public init(toolId: String, name: String, context: String? = nil, label: String? = nil, args: JSONValue? = nil) {
        self.toolId = toolId; self.name = name; self.context = context; self.label = label; self.args = args
    }

    init(payload p: JSONValue?) {
        self.init(toolId: p?["tool_id"]?.string ?? "", name: p?["name"]?.string ?? "tool",
                  context: p?["context"]?.string ?? p?["preview"]?.string, label: Self.labelText(p),
                  args: p?["args"].flatMap { $0 == .null ? JSONValue?.none : $0 })
    }

    static func labelText(_ p: JSONValue?) -> String? {
        let texts = (p?["labels"]?.array ?? []).compactMap { $0["text"]?.string }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }
}

/// `tool.complete` payload: `{tool_id, name, args, labels?, inline_diff?, duration_s?, result, summary?, …}`
/// (`contracts/events.py:283-299`, emitter `tool_progress.py:331-362`). The contract has no error field;
/// like Desktop (`gateway-event/tools.ts`) a truthy `payload.error` marks a failed call, and so does a
/// non-empty `result.error` string (failures live inside `result`, `message-parts.tsx:123-127`).
public struct ToolCompletion: Sendable, Equatable {
    public let toolId: String
    public let name: String
    public let duration: Double?
    public let summary: String?
    public let failed: Bool
    public let label: String?
    public let args: JSONValue?
    /// The tool's result: JSON when the backend could parse it, else the raw string.
    public let result: JSONValue?
    /// Unified diff of a file edit.
    public let inlineDiff: String?

    public init(toolId: String, name: String, duration: Double? = nil, summary: String? = nil, failed: Bool = false,
                label: String? = nil, args: JSONValue? = nil, result: JSONValue? = nil, inlineDiff: String? = nil) {
        self.toolId = toolId; self.name = name; self.duration = duration; self.summary = summary; self.failed = failed
        self.label = label; self.args = args; self.result = result; self.inlineDiff = inlineDiff
    }

    init(payload p: JSONValue?) {
        let result = p?["result"].flatMap { $0 == .null ? JSONValue?.none : $0 }
        let failed = Self.truthy(p?["error"]) || (result?["error"]?.string.map { !$0.isEmpty } ?? false)
        self.init(toolId: p?["tool_id"]?.string ?? "", name: p?["name"]?.string ?? "tool",
                  duration: p?["duration_s"]?.double, summary: p?["summary"]?.string, failed: failed,
                  label: ToolStart.labelText(p), args: p?["args"].flatMap { $0 == .null ? JSONValue?.none : $0 },
                  result: result, inlineDiff: p?["inline_diff"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .string(let s)?: return !s.isEmpty
        case .object?, .array?, .number?: return true
        default: return false
        }
    }
}

/// One past message of a resumed session (`TranscriptMessage`, `contracts/common.py:158-176`, projection
/// `session_history.py:285-364`). Tool rows carry `name`, `context`, `args` and `labels`; tool results,
/// durations and errors are not in history. Assistant rows carry their step's reasoning as `reasoning` or
/// `reasoning_content` (`_HISTORY_ASSISTANT_DETAIL_KEYS`, `session_history.py:275-281`, `:356`).
public struct ChatHistoryMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, tool, system }
    public let role: Role
    public let text: String
    public let toolName: String?
    public let toolContext: String?
    /// Assistant rows: the reasoning of that step (shown as a collapsed Thought).
    public let reasoning: String?
    /// Tool rows: the call's arguments and its connector label (`App · action`).
    public let toolArgs: JSONValue?
    public let toolLabel: String?
    /// When the row was written (`timestamp`, Unix seconds, `session_history.py` "authoring time"); nil when
    /// the backend sent none.
    public let timestamp: Date?
    /// The durable `state.db` row id (`row_id`, `session_history.py` `_history_to_messages`): how a rewind
    /// addresses a persisted turn (`truncate_before_row_id`, B3). nil when the backend sent no stamp.
    public let rowId: Int?

    public init(role: Role, text: String, toolName: String? = nil, toolContext: String? = nil, reasoning: String? = nil,
                toolArgs: JSONValue? = nil, toolLabel: String? = nil, timestamp: Date? = nil, rowId: Int? = nil) {
        self.role = role; self.text = text; self.toolName = toolName; self.toolContext = toolContext
        self.reasoning = reasoning; self.toolArgs = toolArgs; self.toolLabel = toolLabel; self.timestamp = timestamp
        self.rowId = rowId
    }

    init?(_ v: JSONValue) {
        guard let role = v["role"]?.string.flatMap(Role.init(rawValue:)) else { return nil }
        if v["display_kind"]?.string == "hidden" { return nil }
        let text = v["text"]?.string ?? v["content"]?.string ?? ""
        let reasoning = role == .assistant ? Self.reasoning(v) : nil
        if role != .tool && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reasoning == nil { return nil }
        let tool = role == .tool
        self.init(role: role, text: text, toolName: tool ? (v["name"]?.string ?? "tool") : nil,
                  toolContext: tool ? v["context"]?.string : nil, reasoning: reasoning,
                  toolArgs: tool ? v["args"].flatMap { $0 == .null ? JSONValue?.none : $0 } : nil,
                  toolLabel: tool ? ToolStart.labelText(v) : nil,
                  timestamp: v["timestamp"]?.double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                  rowId: v["row_id"]?.int)
    }

    /// `reasoning`, else `reasoning_content`, when it is non-blank text.
    private static func reasoning(_ v: JSONValue) -> String? {
        for key in ["reasoning", "reasoning_content"] {
            if let s = v[key]?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    /// Decodes a `messages` array (resume / history / compress results), dropping unknown and empty rows.
    public static func decode(_ messages: JSONValue?) -> [ChatHistoryMessage] {
        (messages?.array ?? []).compactMap(ChatHistoryMessage.init)
    }
}
