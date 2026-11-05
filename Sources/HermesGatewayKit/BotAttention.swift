import Foundation

/// Why a bot's row carries the "needs attention" badge (A6). The classes and the text rules are Hermes
/// Desktop's (`data.ts` `BOT_ATTENTION_CLASSES` / `attentionReasonFromError`, hermes-agent #93091): a typed
/// reason code wins, otherwise the failure text is classified; transient failures (rate limit, server error,
/// timeout) never badge. The badge is display-only state: never persisted, never changes delivery, set by the
/// latest classified failure and cleared by the bot's next good turn.
public enum BotAttentionReason: String, Sendable, Equatable, CaseIterable {
    case agentBlocked = "agent_blocked"
    case providerAuth = "provider_auth_or_access"
    case quota = "provider_quota_limit"
    case missingConfig = "missing_config"

    /// The row badge's tooltip (Desktop `botAttentionHint`, English).
    public var hint: String {
        switch self {
        case .providerAuth: return "Sign in again for this profile"
        case .quota: return "Quota or balance exhausted"
        case .missingConfig: return "Provider not configured — run hermes model"
        case .agentBlocked: return "Bot is blocked — see its last message"
        }
    }

    /// A reason code (`reason_code` / `data.reason`) or raw failure text → a class, or nil (nothing to badge).
    public static func classify(_ errorTextOrReason: String?) -> BotAttentionReason? {
        let raw = (errorTextOrReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let typed = BotAttentionReason(rawValue: raw) { return typed }
        let text = raw.lowercased()
        // Transient failures first, so a retryable error never sticks a badge.
        if text.contains(transient) { return nil }
        if text.contains(missingConfigText) { return .missingConfig }
        if text.contains(authText) { return .providerAuth }
        if text.contains(quotaText) { return .quota }
        if text.contains(#/\bblocked\b/#) { return .agentBlocked }
        return nil
    }

    private static var transient: Regex<Substring> {
        #/rate.?limit|too many requests|\b429\b|\b5\d\d\b|server error|overloaded|timed?.?out|timeout|temporar/#
    }
    private static var missingConfigText: Regex<Substring> {
        #/no llm provider|no access token|not configured|no api key|missing api key/#
    }
    private static var authText: Regex<Substring> {
        #/\b401\b|\b403\b|unauthorized|forbidden|authentication|invalid.?api.?key|credentials? (?:are )?(?:invalid|expired)/#
    }
    private static var quotaText: Regex<Substring> {
        #/quota|out of funds|insufficient (?:credits?|funds|balance)|payment required|\b402\b|billing/#
    }
}

/// One bot's current "needs attention" state: the class and the failure it came from (first 200 characters).
public struct BotAttention: Sendable, Equatable {
    public let reason: BotAttentionReason
    public let message: String
    public let at: Date

    public init(reason: BotAttentionReason, message: String, at: Date = Date()) {
        self.reason = reason; self.message = message; self.at = at
    }

    /// A classified failure, or nil when it is transient or unknown. A reason code, when there is one, is
    /// the only thing classified (Desktop: `reason || error.message`): a typed transient code never badges.
    public init?(failure: String?, reasonCode: String? = nil, at: Date = Date()) {
        let code = reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let reason = BotAttentionReason.classify(code.isEmpty ? failure : code) else { return nil }
        let text = (failure ?? reasonCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(reason: reason, message: String(text.prefix(200)), at: at)
    }
}
