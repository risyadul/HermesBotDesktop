import Foundation

/// The agent-to-agent messaging protocol section a bot's SOUL.md has to keep, ported verbatim from Hermes
/// Desktop (`soul.ts` `messagingProtocolSection` / `ensureMessagingProtocol`). Saving an edited SOUL re-adds
/// it when it is missing, exactly as Desktop does, unless the backend injects the protocol into every
/// session's system prompt itself (`profiles.list` `bot_mode_protocol: true`): then SOUL.md stays the
/// user's text alone.
public enum SoulProtocol {
    public struct Teammate: Sendable, Equatable {
        public let name: String
        public let description: String
        public init(name: String, description: String = "") { self.name = name; self.description = description }
    }

    public static let heading = "## Messaging other agents"

    /// Desktop's `botHandle`: the profile name, `hermes` for the default profile.
    public static func handle(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased() == "default" ? "hermes" : name
    }

    /// `/(^|\n)## Messaging other agents(\s|$)/`.
    public static func hasSection(_ soul: String) -> Bool {
        soul.range(of: #"(^|\n)## Messaging other agents(\s|$)"#, options: .regularExpression) != nil
    }

    /// The section for bot `name`, listing `roster` minus the bot itself.
    public static func section(name: String, roster: [Teammate]) -> String {
        let teammates = roster.filter { $0.name != name }
        let h = handle(name)
        var lines = [
            heading,
            "",
            "You work alongside other named agents. Every agent (including you) has",
            "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
            "so it always exists. Agent-to-agent messages are delivered straight",
            "into it, like a DM. To message a teammate, run:",
            "",
            "```",
            "hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from \u{1F916} "
                + h + " (@" + h + "): your message\"",
            "",
            "Run the send with background=true and notify_on_complete=true on the",
            "terminal tool, then finish your turn — the reply arrives later as a",
            "background process notification. Never block waiting for it.",
            "```",
            "",
            "(`--in ~ -c \"Bot Chat\" --create-if-missing` resumes their canonical",
            "conversation in the home workspace, creating it if the target has no",
            "\"Bot Chat\" yet. `-Q` keeps output clean. Always open with the",
            "\"Message from \u{1F916} " + h + " (@" + h + "):\" prefix so they know",
            "who is talking (the @handle lets the app show your avatar to them).",
            "Their reply prints to stdout — relay the relevant part back to the",
            "user, and say which agent it came from.)",
            "",
            "If a message in YOUR chat starts with \"Message from \u{1F916} <name>\", it is",
            "a teammate messaging you, not the user. Answer it directly — your reply",
            "reaches them via their own delivery — and use the same command if you",
            "need to start a conversation yourself.",
            "",
            "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
            "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
            "reply, and report back.",
            "",
            "The roster grows over time — run `hermes profile list` for the LIVE",
            "teammate list before a handoff. Teammates when you were created:",
        ]
        lines += teammates.isEmpty
            ? ["- (none yet)"]
            : teammates.map { "- `\($0.name)`" + ($0.description.isEmpty ? "" : " — \($0.description)") }
        return lines.joined(separator: "\n")
    }

    /// Desktop's `ensureMessagingProtocol`: the trimmed SOUL, plus the section once when it is missing and
    /// the backend does not inject it.
    public static func ensure(_ soul: String, name: String, roster: [Teammate], serverInjects: Bool) -> String {
        let text = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverInjects || hasSection(text) { return text }
        let s = section(name: name, roster: roster)
        return text.isEmpty ? s : text + "\n\n" + s
    }
}
