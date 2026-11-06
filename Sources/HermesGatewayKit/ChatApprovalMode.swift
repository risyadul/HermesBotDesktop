import Foundation

/// B14: the approval mode menu, as Hermes Desktop's status bar (`app/shell/approval-mode-menu.tsx`,
/// `store/approval-mode.ts`). The mode is the PROFILE's `approvals.mode` (`manual | smart | off`), read with
/// `config.get` and written with `config.set`, both naming the profile the menu is for: the gateway's config
/// methods are profile-scoped, and an unscoped call would hit the backend's launch profile instead of this bot
/// (Desktop #125969). Writes go through the gateway, which re-emits `session.info` (`approval_mode`) to every
/// live session (`methods_config_set.py` `approvals.mode` → `_emit_all_session_info`).
public enum ApprovalMode: String, Sendable, CaseIterable, Equatable {
    case manual, smart, off

    /// Desktop's reading of an unknown or empty value.
    public init(normalizing raw: String?) {
        self = ApprovalMode(rawValue: (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .manual
    }

    /// Desktop's copy (`i18n/en.ts` `shell.approvalMode`).
    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .smart: return "Smart"
        case .off: return "Off"
        }
    }

    public var detail: String {
        switch self {
        case .manual: return "Ask before actions that require approval"
        case .smart: return "Automatically assess actions and ask when needed"
        case .off: return "Run without approval prompts"
        }
    }

    /// `config.get` / `config.set` params for `profile` (a blank name is the launch profile: no `profile`).
    public static func params(profile: String, value: ApprovalMode? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["key": "approvals.mode"]
        if let value { p["value"] = .string(value.rawValue) }
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { p["profile"] = .string(name) }
        return .object(p)
    }
}

extension BotChatSession {
    /// `config.get {key: "approvals.mode", profile}` for this bot.
    public func approvalMode() async throws -> ApprovalMode {
        ApprovalMode(normalizing: try await backend.client.call("config.get", ApprovalMode.params(profile: bot.name))["value"]?.string)
    }

    /// `config.set {key: "approvals.mode", value, profile}` → the mode the backend applied.
    public func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalMode {
        ApprovalMode(normalizing: try await backend.client.call("config.set",
                                                                ApprovalMode.params(profile: bot.name, value: mode))["value"]?.string)
    }
}
