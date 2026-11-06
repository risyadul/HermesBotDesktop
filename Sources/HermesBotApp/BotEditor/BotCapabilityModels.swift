import Foundation
import HermesGatewayKit

/// A13 Find Skills in the Edit sheet (Desktop's skills hub search, `skills-hub.tsx`): search the hub, then install
/// one into this bot's profile after the user confirms. The skills list is refreshed after an install.
@MainActor
final class BotSkillsFinderModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [SkillsHub.Result]?
    @Published private(set) var searching = false
    @Published private(set) var installing: String?
    @Published private(set) var installed: Set<String> = []
    /// The skill waiting for the user's Install / Cancel.
    @Published var confirming: SkillsHub.Result?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?

    let profile: String
    private let service: any BotProfileService
    private let onInstalled: (String) async -> Void

    init(profile: String, service: any BotProfileService, onInstalled: @escaping (String) async -> Void) {
        self.profile = profile
        self.service = service
        self.onInstalled = onInstalled
    }

    var canSearch: Bool { !searching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func search() async {
        guard canSearch else { return }
        searching = true
        error = nil
        notice = nil
        results = nil
        do { results = try await service.searchSkills(query) } catch {
            self.error = "Could not search the skills hub: \(BotManagementText.describe(error))"
        }
        searching = false
    }

    /// Install asks first; names that are not a slug or an owner/name path never reach Hermes.
    func requestInstall(_ skill: SkillsHub.Result) {
        guard installing == nil else { return }
        guard SkillsHub.isInstallable(skill.name) else {
            error = "\(skill.name) cannot be installed from here."
            return
        }
        confirming = skill
    }

    func cancelInstall() { confirming = nil }

    func confirmInstall() async {
        guard let skill = confirming, installing == nil else { return }
        confirming = nil
        installing = skill.name
        error = nil
        notice = nil
        do {
            try await service.installSkill(skill.name, profile: profile)
            installed.insert(skill.name)
            notice = "Installed \(skill.name)."
            await onInstalled(skill.name)
        } catch {
            self.error = "Could not install \(skill.name): \(BotManagementText.describe(error))"
        }
        installing = nil
    }
}

/// A thread-safe "stop" flag a running sign-in checks between steps.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A14 MCP servers in the Edit sheet (Desktop's MCP setup, `mcp-setup.tsx`): the servers `mcp.servers.list` reports
/// for this bot, plus Add (a command or a URL), Set API Key, Test and OAuth Sign In. Each acts on the profile at
/// once. The API key lives only in the secure field until it is sent, and the field is cleared afterwards.
@MainActor
final class BotMcpModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, unsupported, failed(String) }
    enum AddKind: String, CaseIterable, Identifiable {
        case command = "Command", url = "URL"
        var id: String { rawValue }
    }
    /// One server's last result line.
    struct Status: Equatable { let text: String; let isError: Bool }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var servers: [MCPServers.Server] = []

    // Add
    @Published var addOpen = false
    @Published var addKind: AddKind = .command
    @Published var addName = ""
    @Published var addCommand = ""
    @Published var addArguments = ""
    @Published var addEnvironment = ""
    @Published var addURL = ""
    @Published private(set) var addError: String?
    @Published private(set) var adding = false

    // Per server
    /// The server whose API key form is open.
    @Published private(set) var keyServer: String?
    @Published var keyEnvVar = ""
    @Published var keyValue = ""
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var status: [String: Status] = [:]
    private var signIns: [String: CancelFlag] = [:]

    let profile: String
    private let service: any BotProfileService
    private let onListed: ([MCPServers.Server]) -> Void

    init(profile: String, service: any BotProfileService, onListed: @escaping ([MCPServers.Server]) -> Void) {
        self.profile = profile
        self.service = service
        self.onListed = onListed
    }

    func server(_ name: String) -> MCPServers.Server? { servers.first { $0.name == name } }

    func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            servers = try await service.mcpServers(profile)
            phase = .loaded
            onListed(servers)
        } catch where MCPServers.isUnsupported(error) {
            phase = .unsupported
        } catch {
            phase = .failed(BotManagementText.describe(error))
        }
    }

    // MARK: add

    func toggleAdd() { addOpen.toggle(); addError = nil }

    func submitAdd() async {
        guard !adding else { return }
        let new: MCPServers.NewServer
        do {
            new = try MCPServers.newServer(name: addName, url: addKind == .url ? addURL : nil, command: addCommand,
                                              arguments: addArguments, environment: addEnvironment)
        } catch {
            addError = BotManagementText.describe(error)
            return
        }
        guard server(new.name) == nil else {
            addError = "This bot already has a server named \(new.name)."
            return
        }
        adding = true
        addError = nil
        do {
            try await service.addMcpServer(profile, new)
            status[new.name] = Status(text: "Added. Test it, or set its API key.", isError: false)
            addOpen = false
            addName = ""; addCommand = ""; addArguments = ""; addEnvironment = ""; addURL = ""
            adding = false
            await load()
        } catch {
            addError = "Could not add the server: \(BotManagementText.describe(error))"
            adding = false
        }
    }

    // MARK: API key

    func openKey(_ name: String) {
        keyServer = keyServer == name ? nil : name
        keyEnvVar = ""
        keyValue = ""
    }

    func submitKey() async {
        guard let name = keyServer, busy[name] == nil else { return }
        let value = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            status[name] = Status(text: "Enter the key first.", isError: true)
            return
        }
        busy[name] = "Saving the key…"
        let envVar = keyEnvVar
        keyValue = ""
        do {
            try await service.setMcpKey(profile, server: name, envVar: envVar, value: value)
            keyServer = nil
            status[name] = Status(text: "Key saved in the bot's .env.", isError: false)
            busy[name] = nil
            await test(name)
        } catch {
            status[name] = Status(text: "Could not save the key: \(BotManagementText.describe(error))", isError: true)
            busy[name] = nil
        }
    }

    // MARK: test

    func test(_ name: String) async {
        guard busy[name] == nil else { return }
        busy[name] = "Testing…"
        do {
            let r = try await service.testMcpServer(profile, name)
            if r.ok {
                status[name] = Status(text: "Connected · \(r.tools) tool\(r.tools == 1 ? "" : "s").", isError: false)
            } else {
                let why = r.error ?? "The test failed."
                status[name] = Status(text: r.oauthNeeded ? "Sign in first. \(why)" : why, isError: true)
            }
        } catch {
            status[name] = Status(text: "Could not test: \(BotManagementText.describe(error))", isError: true)
        }
        busy[name] = nil
    }

    // MARK: OAuth

    var signingIn: Set<String> { Set(signIns.keys) }

    func signIn(_ name: String) async {
        guard busy[name] == nil else { return }
        let flag = CancelFlag()
        signIns[name] = flag
        busy[name] = "Finish signing in in your browser…"
        do {
            try await service.signInMcp(profile, name, cancelled: { flag.isSet })
            status[name] = Status(text: "Signed in.", isError: false)
        } catch is MCPServers.Cancelled {
            status[name] = Status(text: "Sign-in cancelled.", isError: false)
        } catch {
            status[name] = Status(text: "Could not sign in: \(BotManagementText.describe(error))", isError: true)
        }
        signIns[name] = nil
        busy[name] = nil
        if status[name]?.isError == false { await load() }
    }

    func cancelSignIn(_ name: String) { signIns[name]?.set() }

    /// The sheet closed: stop any sign-in still waiting for the browser.
    func cancelAll() { signIns.values.forEach { $0.set() } }
}
