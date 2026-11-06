import Foundation
import HermesGatewayKit

/// E2: what stops a first run, found while connecting (`AppModel.setupIssue`). Shown as one guided screen
/// (OnboardingView.swift) instead of a bare error; every other failure keeps the "Can't reach Hermes" screen.
enum SetupIssue: Equatable {
    /// No `hermes` executable where the app looks, or `HERMES_BOT_APP_HERMES_BIN` names something unusable.
    case hermesMissing(tried: [String], problem: String?)
    /// The backend answers but `setup.runtime_check` says no model can be served.
    case noModel(provider: String?, model: String?, reason: String?)
}

/// The first-run screen on show, if any: one calm screen per state.
enum OnboardingScreen: Equatable {
    case hermesMissing(tried: [String], problem: String?)
    case noModel(provider: String?, model: String?, reason: String?)
    /// Connected with exactly one bot: Bot Chat works, Group Chat needs a second bot.
    case oneBot(name: String, title: String)
}

enum Onboarding {
    static let docsURL = URL(string: "https://hermes-agent.nousresearch.com/docs")!
    static let overrideVariable = "HERMES_BOT_APP_HERMES_BIN"
    /// The name the "add a second bot" commands start with; the user can change it.
    static let suggestedBotName = "reviewer"

    /// The connect error → a first-run issue, or nil (the generic failure screen keeps it).
    static func issue(for error: Error) -> SetupIssue? {
        guard let e = error as? ServeProcess.ServeError else { return nil }
        switch e {
        case .binaryNotFound(let tried, _): return .hermesMissing(tried: tried, problem: nil)
        case .invalidBinary(let path, let reason, _): return .hermesMissing(tried: [path], problem: "\(path): \(reason)")
        default: return nil
        }
    }

    /// `setup.runtime_check` → a first-run issue, or nil (ready, or no clear answer).
    static func issue(for readiness: SetupReadiness) -> SetupIssue? {
        if case .noModel(let provider, let model, let reason) = readiness {
            return .noModel(provider: provider, model: model, reason: reason)
        }
        return nil
    }

    /// Which screen the empty detail pane shows. A missing Hermes only while the connect failed; a missing
    /// model, then a lone bot, only while connected.
    static func screen(phase: AppModel.Phase, issue: SetupIssue?, bots: [Bot], groupsAvailable: Bool) -> OnboardingScreen? {
        switch (phase, issue) {
        case (.failed, .hermesMissing(let tried, let problem)?):
            return .hermesMissing(tried: tried, problem: problem)
        case (.connected, .noModel(let provider, let model, let reason)?):
            return .noModel(provider: provider, model: model, reason: reason)
        case (.connected, _):
            guard groupsAvailable, bots.count == 1, let bot = bots.first else { return nil }
            return .oneBot(name: bot.name, title: bot.title)
        default:
            return nil
        }
    }

    /// The two commands that add a bot named `name` with its own provider, or nil for a name Hermes would
    /// refuse (profile names: `^[a-z0-9][a-z0-9_-]{0,63}$`). Shown and copied only; the app never runs them.
    static func newBotCommands(name: String) -> [String]? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard BotActivityProfileSwitch.isProfileName(n), n != "default" else { return nil }
        return ["hermes profile create \(n)", "hermes -p \(n) setup"]
    }

    /// The commands that configure a model for the default profile.
    static let modelCommands = ["hermes setup", "hermes model"]

    /// The override line to paste into a shell (or a launch script) once Hermes is installed somewhere unusual.
    static let overrideExample = "export \(overrideVariable)=\"$(which hermes)\""
}
