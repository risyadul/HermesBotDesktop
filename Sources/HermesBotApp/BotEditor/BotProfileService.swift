import AppKit
import HermesGatewayKit

/// Everything bot management (A7 New Bot, A8 Edit, A9 Advanced, A10 avatars, A11 Duplicate, A12 Delete, A13 skills,
/// A14 MCP servers) asks of Hermes. Production wraps the gateway (`BotProfileAPI`, `BotMetaSync`, `BotLook`,
/// `AvatarSources`, `SkillsHub`, `MCPServers`) and the Hermes CLI (`ProfileCLI`); tests use a fake, so no test
/// creates, edits or deletes a real profile, runs `hermes`, uploads an asset, generates an image, installs a skill
/// or an MCP server, or opens a sign-in page.
protocol BotProfileService: Sendable {
    func describe(_ name: String) async throws -> BotProfileAPI.Snapshot
    func modelOptions(_ name: String) async throws -> [BotProfileAPI.ModelProvider]
    func roster() async throws -> BotProfileAPI.Roster
    /// `ui_meta["hermes-bots"].title`, Desktop's compare-and-swap write.
    func saveTitle(_ name: String, _ title: String) async throws -> BotMetaSync.Outcome
    func configure(_ name: String, _ changes: BotProfileAPI.Changes) async throws -> BotProfileAPI.ConfigureResult
    func setAvatar(_ name: String, _ image: Data) async throws
    func clearAvatar(_ name: String) async throws
    func unsetModel(_ name: String) async throws
    func duplicate(_ name: String, description: String,
                   progress: @escaping @Sendable (BotDuplicate.Step) async -> Void) async throws -> BotDuplicate.Result
    func delete(_ name: String) async throws

    // A7
    func create(_ request: BotCreate.Request) async throws -> BotCreate.Created
    func readiness(_ name: String) async -> SetupReadiness
    /// `ui_meta["hermes-bots"]` look fields (A7 / A10), Desktop's compare-and-swap write.
    func saveLook(_ name: String, _ patch: BotLook.Patch) async throws -> BotMetaSync.Outcome
    // A10
    func imageGenerationAvailable() async -> Bool
    func generateImage(prompt: String) async throws -> Data
    func petGallery() async throws -> [AvatarSources.Pet]
    func petThumb(_ pet: AvatarSources.Pet) async -> Data?
    // A13
    func searchSkills(_ query: String) async throws -> [SkillsHub.Result]
    func installSkill(_ skill: String, profile: String) async throws
    // A14
    func mcpServers(_ profile: String) async throws -> [MCPServers.Server]
    func addMcpServer(_ profile: String, _ server: MCPServers.NewServer) async throws
    func setMcpKey(_ profile: String, server: String, envVar: String?, value: String) async throws
    func testMcpServer(_ profile: String, _ server: String) async throws -> MCPServers.TestResult
    /// The whole OAuth sign-in (start, browser, poll); `cancelled` ends it early.
    func signInMcp(_ profile: String, _ server: String, cancelled: @escaping @Sendable () -> Bool) async throws
}

/// The live service for one gateway connection.
struct LiveBotProfileService: BotProfileService {
    /// Desktop's `MODEL_OPTIONS_SETTLE_MS` (#95279): a catalog read that hangs falls back to typed entry.
    static let modelOptionsTimeout: TimeInterval = 20
    /// `mcp.servers.oauth.start` waits up to 30 s on the backend for the authorization URL.
    static let oauthCallTimeout: TimeInterval = 60
    let call: BotMetaSync.Call
    let catalogCall: BotMetaSync.Call
    let cli: ProfileCLI
    let client: GatewayClient

    init(client: GatewayClient, cli: ProfileCLI = ProfileCLI()) {
        self.client = client
        call = { method, params in try await client.call(method, params) }
        catalogCall = { method, params in try await client.call(method, params, timeout: Self.modelOptionsTimeout) }
        self.cli = cli
    }

    private var api: BotProfileAPI { BotProfileAPI(call: call) }

    private func calling(timeout: TimeInterval) -> BotMetaSync.Call {
        { [client] method, params in try await client.call(method, params, timeout: timeout) }
    }

    func describe(_ name: String) async throws -> BotProfileAPI.Snapshot { try await api.describe(name) }
    func modelOptions(_ name: String) async throws -> [BotProfileAPI.ModelProvider] {
        try await BotProfileAPI(call: catalogCall).modelOptions(profile: name)
    }
    func roster() async throws -> BotProfileAPI.Roster { try await api.roster() }
    func saveTitle(_ name: String, _ title: String) async throws -> BotMetaSync.Outcome {
        try await BotMetaSync.save(name: name, patch: ["title": .string(title)], call: call)
    }
    func configure(_ name: String, _ changes: BotProfileAPI.Changes) async throws -> BotProfileAPI.ConfigureResult {
        try await api.configure(name, changes)
    }
    func setAvatar(_ name: String, _ image: Data) async throws { try await api.setAvatar(name, image: image) }
    func clearAvatar(_ name: String) async throws { try await api.clearAvatar(name) }
    func unsetModel(_ name: String) async throws { try await cli.unsetModel(name) }
    func duplicate(_ name: String, description: String,
                   progress: @escaping @Sendable (BotDuplicate.Step) async -> Void) async throws -> BotDuplicate.Result {
        try await BotDuplicate.run(source: name, description: description, api: api, call: call, progress: progress)
    }
    func delete(_ name: String) async throws { try await cli.deleteProfile(name) }

    func create(_ request: BotCreate.Request) async throws -> BotCreate.Created { try await api.create(request) }
    func readiness(_ name: String) async -> SetupReadiness { await BotCreate.readiness(profile: name, call: call) }
    func saveLook(_ name: String, _ patch: BotLook.Patch) async throws -> BotMetaSync.Outcome {
        try await BotLook.save(name: name, patch: patch, call: call)
    }

    func imageGenerationAvailable() async -> Bool {
        (try? await call("image.generate", AvatarSources.probeParams)).map(AvatarSources.available) ?? false
    }
    func generateImage(prompt: String) async throws -> Data {
        try AvatarSources.generatedImage(try await calling(timeout: AvatarSources.generateTimeout)(
            "image.generate", AvatarSources.generateParams(prompt: prompt)))
    }
    func petGallery() async throws -> [AvatarSources.Pet] { AvatarSources.pets(try await call("pet.gallery", [:])) }
    func petThumb(_ pet: AvatarSources.Pet) async -> Data? {
        (try? await calling(timeout: AvatarSources.thumbTimeout)("pet.thumb", AvatarSources.thumbParams(pet)))
            .flatMap(AvatarSources.thumb)
    }

    func searchSkills(_ query: String) async throws -> [SkillsHub.Result] {
        SkillsHub.results(try await calling(timeout: SkillsHub.searchTimeout)("skills.manage", SkillsHub.searchParams(query)))
    }
    func installSkill(_ skill: String, profile: String) async throws {
        let r = try await calling(timeout: SkillsHub.installTimeout)("skills.manage", SkillsHub.installParams(skill, profile: profile))
        guard SkillsHub.installed(r) else { throw MCPServers.Failure("Hermes did not install \(skill).") }
    }

    private var mcp: MCPServers { MCPServers(call: call) }
    func mcpServers(_ profile: String) async throws -> [MCPServers.Server] { try await mcp.list(profile: profile) }
    func addMcpServer(_ profile: String, _ server: MCPServers.NewServer) async throws { try await mcp.add(profile: profile, server) }
    func setMcpKey(_ profile: String, server: String, envVar: String?, value: String) async throws {
        try await mcp.setAPIKey(profile: profile, name: server, envVar: envVar, value: value)
    }
    func testMcpServer(_ profile: String, _ server: String) async throws -> MCPServers.TestResult {
        try await MCPServers(call: calling(timeout: MCPServers.testTimeout)).test(profile: profile, name: server)
    }
    func signInMcp(_ profile: String, _ server: String, cancelled: @escaping @Sendable () -> Bool) async throws {
        try await MCPServers(call: calling(timeout: Self.oauthCallTimeout)).signIn(profile: profile, name: server, open: { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        }, cancelled: cancelled)
    }
}

enum BotManagementText {
    /// A failure in words: an RPC error's message without the "RPC error N:" prefix, token-scrubbed.
    static func describe(_ error: Error) -> String {
        if let e = error as? GatewayClient.RPCError, !e.message.isEmpty { return Redaction.scrub(e.message) }
        return Redaction.describe(error)
    }
}
