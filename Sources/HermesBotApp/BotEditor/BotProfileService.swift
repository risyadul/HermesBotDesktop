import Foundation
import HermesGatewayKit

/// Everything bot management (A8 Edit, A9 Advanced, A11 Duplicate, A12 Delete) asks of Hermes. Production
/// wraps the gateway (`BotProfileAPI`, `BotMetaSync`) and the Hermes CLI (`ProfileCLI`); tests use a fake,
/// so no test creates, edits or deletes a real profile, runs `hermes` or uploads an asset.
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
}

/// The live service for one gateway connection.
struct LiveBotProfileService: BotProfileService {
    /// Desktop's `MODEL_OPTIONS_SETTLE_MS` (#95279): a catalog read that hangs falls back to typed entry.
    static let modelOptionsTimeout: TimeInterval = 20
    let call: BotMetaSync.Call
    let catalogCall: BotMetaSync.Call
    let cli: ProfileCLI

    init(client: GatewayClient, cli: ProfileCLI = ProfileCLI()) {
        call = { method, params in try await client.call(method, params) }
        catalogCall = { method, params in try await client.call(method, params, timeout: Self.modelOptionsTimeout) }
        self.cli = cli
    }

    private var api: BotProfileAPI { BotProfileAPI(call: call) }

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
}

enum BotManagementText {
    /// A failure in words: an RPC error's message without the "RPC error N:" prefix, token-scrubbed.
    static func describe(_ error: Error) -> String {
        if let e = error as? GatewayClient.RPCError, !e.message.isEmpty { return Redaction.scrub(e.message) }
        return Redaction.describe(error)
    }
}
