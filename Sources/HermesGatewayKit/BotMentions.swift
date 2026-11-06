import Foundation

/// B1: @mentions of other bots from a Bot Chat, ported from Hermes Desktop's hermes-bots plugin
/// (`plugin.tsx` mention completions and the mention middleware, `data.ts` `botHandle`, `mentionNameForms`,
/// `botMentionTag`, `resolveRosterMentions`), reduced to the one local backend.
///
/// The app never sends anything to the mentioned bot itself. A prompt that tags bots of the roster gets an
/// identification note appended for the model (who "@research-buddy" is), and the bot contacts them with
/// its own `message_agent` tool, so there is exactly one send path and the user's text is never forwarded
/// verbatim. Unknown @words (`user@example.com`, an @ nobody has) pass through untouched.
public enum BotMentions {
    /// Tags no bot may claim through a friendly name (`mentionNameForms`): room-wide words and the primary
    /// profile's names.
    static let reserved: Set<String> = ["all", "everyone", "user", "default", "hermes"]

    /// The opening of the note; also how `stripNote` recognises one (Desktop writes the same).
    public static let notePrefix = "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: "

    /// `botHandle`: the profile name, `hermes` for the primary (`default`) profile.
    public static func handle(_ bot: Bot) -> String {
        bot.name.trimmingCharacters(in: .whitespaces).lowercased() == "default" ? "hermes" : bot.name
    }

    /// `mentionNameForms`: a friendly name reduced to the mention charset, slugified ("Research Buddy" →
    /// `research-buddy`) and collapsed (`researchbuddy`); reserved tags dropped.
    public static func nameForms(_ value: String?) -> [String] {
        let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        let slug = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        let collapsed = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "", options: .regularExpression)
        var out: [String] = []
        for form in [slug, collapsed] where !out.contains(form) && !reserved.contains(form)
            && form.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil {
            out.append(form)
        }
        return out
    }

    /// The bot's friendly names in Desktop's `displayName` order: the Bot Mode title, then the display name.
    static func friendlyNames(_ bot: Bot) -> [String?] { [bot.metaTitle, bot.displayName] }

    /// `botMentionTag`: what autocomplete inserts, the friendly slug when the bot has a real name, else the
    /// handle. The resolver accepts both.
    public static func tag(_ bot: Bot) -> String {
        for friendly in friendlyNames(bot) {
            if let first = nameForms(friendly).first { return first }
        }
        return handle(bot)
    }

    /// Every lowercase form `resolve` accepts for a bot: handle, profile name, friendly-name forms.
    public static func forms(_ bot: Bot) -> Set<String> {
        var forms: Set<String> = [handle(bot).lowercased(), bot.name.lowercased()]
        for friendly in friendlyNames(bot) { forms.formUnion(nameForms(friendly)) }
        return forms
    }

    /// The roster a chat can tag: every bot but the one it is talking to.
    public static func candidates(_ roster: [Bot], excluding selfName: String) -> [Bot] {
        roster.filter { $0.name != selfName }
    }

    /// `resolveRosterMentions`: the bots `text` tags, in order of first mention, without duplicates. Code
    /// (fenced and inline) is ignored; a form two bots share resolves to neither.
    public static func resolve(_ text: String, roster: [Bot], selfName: String) -> [Bot] {
        let bots = candidates(roster, excluding: selfName)
        guard !bots.isEmpty, text.contains("@") else { return [] }
        var byForm: [String: Bot?] = [:]
        for bot in bots {
            for form in forms(bot) where !form.isEmpty {
                if let existing = byForm[form] {
                    if existing?.name != bot.name { byForm[form] = .some(nil) }
                } else {
                    byForm[form] = bot
                }
            }
        }
        let prose = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`\\n]*`", with: " ", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: "(^|\\s)@([a-z0-9][a-z0-9_-]*)", options: [.caseInsensitive])
        else { return [] }
        let ns = prose as NSString
        var out: [Bot] = []
        for m in re.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range(at: 2)).lowercased()
            guard let hit = byForm[token], let bot = hit, !out.contains(where: { $0.name == bot.name }) else { continue }
            out.append(bot)
        }
        return out
    }

    /// The identification note for `bots` (Desktop's middleware wording, without its cross-machine relay
    /// clause: this app talks to one local backend). nil when no bot is tagged.
    public static func note(for bots: [Bot]) -> String? {
        guard !bots.isEmpty else { return nil }
        let lines = bots.map { bot -> String in
            let title = friendlyNames(bot).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return "@\(handle(bot)) = agent profile \"\(bot.name)\"" + (title.map { " (\"\($0)\")" } ?? "")
        }
        return notePrefix + lines.joined(separator: "; ")
            + ". If they want one of these agents contacted, compose your own message and send it with your "
            + "message_agent tool; never forward the user\u{2019}s text verbatim. If this session has no "
            + "message_agent tool, agent messaging is unavailable here — say so.]"
    }

    /// The text the model receives: `text` plus the note when it tags bots of the roster, else `text`.
    public static func annotate(_ text: String, roster: [Bot], selfName: String) -> String {
        guard let note = note(for: resolve(text, roster: roster, selfName: selfName)) else { return text }
        return text + note
    }

    /// The user's words without a trailing mention note (history rows carry what the model received).
    public static func stripNote(_ text: String) -> String {
        guard text.hasSuffix("]"), let r = text.range(of: notePrefix, options: .backwards) else { return text }
        return String(text[..<r.lowerBound])
    }
}
