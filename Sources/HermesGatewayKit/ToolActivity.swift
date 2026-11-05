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

    public init(toolId: String, name: String, context: String? = nil, label: String? = nil) {
        self.toolId = toolId; self.name = name; self.context = context; self.label = label
    }

    init(payload p: JSONValue?) {
        self.init(toolId: p?["tool_id"]?.string ?? "", name: p?["name"]?.string ?? "tool",
                  context: p?["context"]?.string ?? p?["preview"]?.string, label: Self.labelText(p))
    }

    static func labelText(_ p: JSONValue?) -> String? {
        let texts = (p?["labels"]?.array ?? []).compactMap { $0["text"]?.string }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }
}

/// `tool.complete` payload: `{tool_id, name, duration_s?, result, summary?, labels?, …}`
/// (`contracts/events.py:283-299`). The contract has no error field; like Desktop
/// (`gateway-event/tools.ts`) a truthy `payload.error` marks a failed call.
public struct ToolCompletion: Sendable, Equatable {
    public let toolId: String
    public let name: String
    public let duration: Double?
    public let summary: String?
    public let failed: Bool

    public init(toolId: String, name: String, duration: Double? = nil, summary: String? = nil, failed: Bool = false) {
        self.toolId = toolId; self.name = name; self.duration = duration; self.summary = summary; self.failed = failed
    }

    init(payload p: JSONValue?) {
        let error = p?["error"]
        let failed: Bool
        switch error {
        case .bool(let b)?: failed = b
        case .string(let s)?: failed = !s.isEmpty
        case .object?, .array?, .number?: failed = true
        default: failed = false
        }
        self.init(toolId: p?["tool_id"]?.string ?? "", name: p?["name"]?.string ?? "tool",
                  duration: p?["duration_s"]?.double, summary: p?["summary"]?.string, failed: failed)
    }
}

/// One past message of a resumed session (`TranscriptMessage`, `contracts/common.py:158-176`, projection
/// `session_history.py:285-364`). Tool rows carry `name` + `context` only; tool results are not in history.
public struct ChatHistoryMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, tool, system }
    public let role: Role
    public let text: String
    public let toolName: String?
    public let toolContext: String?

    public init(role: Role, text: String, toolName: String? = nil, toolContext: String? = nil) {
        self.role = role; self.text = text; self.toolName = toolName; self.toolContext = toolContext
    }

    init?(_ v: JSONValue) {
        guard let role = v["role"]?.string.flatMap(Role.init(rawValue:)) else { return nil }
        if v["display_kind"]?.string == "hidden" { return nil }
        let text = v["text"]?.string ?? v["content"]?.string ?? ""
        if role != .tool && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        self.init(role: role, text: text, toolName: role == .tool ? (v["name"]?.string ?? "tool") : nil,
                  toolContext: role == .tool ? v["context"]?.string : nil)
    }

    /// Decodes a `messages` array (resume / history / compress results), dropping unknown and empty rows.
    public static func decode(_ messages: JSONValue?) -> [ChatHistoryMessage] {
        (messages?.array ?? []).compactMap(ChatHistoryMessage.init)
    }
}
