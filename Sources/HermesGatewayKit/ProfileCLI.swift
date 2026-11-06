import Foundation

/// The two profile changes Hermes Desktop makes through the Hermes CLI (its `cli.exec` path) because no
/// profile RPC does them:
/// - Delete a bot: `hermes profile delete <name> --yes` (`profile-ops.ts` `deleteBot`; Desktop's preferred
///   `host.deleteProfile` is an Electron-only REST interception). The default profile is never deleted.
/// - "Inherit" model: `hermes --profile <name> config unset model` (`profile-config.tsx`
///   `applyAdvancedConfig` with provider and model both empty).
///
/// Same rules as every hermes the app runs (`BotActivityProfileSwitch`): the binary passes
/// `ServeProcess.trustedExecutable`, no shell, clean environment with the app's Hermes root, a name that is
/// not a profile id never reaches the command line, a timeout, and a Redaction-safe failure.
public struct ProfileCLI: Sendable {
    public static let timeout: TimeInterval = 120

    public struct Failure: Error, RedactionSafeError, Equatable {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public let home: URL
    let environment: [String: String]
    let runner: any CommandRunner

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: any CommandRunner = ProcessCommandRunner()) {
        self.home = home; self.environment = environment; self.runner = runner
    }

    public static func isDefault(_ name: String) -> Bool { name.trimmingCharacters(in: .whitespaces).lowercased() == "default" }

    public static func deleteArguments(_ name: String) -> [String] { ["profile", "delete", name, "--yes"] }
    public static func unsetModelArguments(_ name: String) -> [String] { ["--profile", name, "config", "unset", "model"] }

    /// Deletes profile `name` (its whole directory). Refuses `default` and anything that is not a profile id.
    public func deleteProfile(_ name: String) async throws {
        guard !Self.isDefault(name) else { throw Failure(description: "The default profile cannot be deleted.") }
        try await run(name, Self.deleteArguments(name))
    }

    /// Removes profile `name`'s model pin so it inherits the launch profile's model.
    public func unsetModel(_ name: String) async throws {
        try await run(name, Self.unsetModelArguments(name))
    }

    private func run(_ name: String, _ arguments: [String]) async throws {
        guard BotActivityProfileSwitch.isProfileName(name) else { throw Failure(description: "not a profile name") }
        let hermes: String
        switch ServeProcess.trustedExecutable(environment: environment, home: home, log: home.appendingPathComponent(".hermes/logs").path) {
        case .success(let path): hermes = path
        case .failure(let e): throw Failure(description: Redaction.scrub(e.description))
        }
        var env = ProcessCommandRunner.cleanEnvironment(environment)
        env["HOME"] = home.path
        env["HERMES_HOME"] = home.appendingPathComponent(".hermes").path
        env["PATH"] = BackgroundServe.path(hermes: hermes, home: home.path)
        let r: CommandResult
        do { r = try await runner.run(hermes, arguments, environment: env, timeout: Self.timeout) } catch {
            throw Failure(description: Redaction.describe(error))
        }
        guard r.succeeded else {
            if r.timedOut { throw Failure(description: "timed out") }
            let last = Redaction.scrub(r.output).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let detail = last.trimmingCharacters(in: .whitespaces).prefix(200)
            throw Failure(description: detail.isEmpty ? "hermes exited with \(r.status)" : String(detail))
        }
    }
}
