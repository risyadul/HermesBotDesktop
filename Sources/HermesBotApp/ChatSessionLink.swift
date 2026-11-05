import Foundation
import HermesGatewayKit

/// What `ChatModel` needs from an open Bot Chat. `BotChatSession` is the production conformer; tests drive
/// the model state machine with an in-memory fake (no gateway, no windows).
protocol ChatSessionLink: AnyObject, Sendable {
    var sessionId: String { get }
    var storedSessionId: String { get }
    var isCanonical: Bool { get }
    var history: [ChatHistoryMessage] { get }
    var openRequests: [ServerRequest] { get }
    var inflight: InflightTurn? { get }

    func onEvent(_ h: @escaping @Sendable (ChatEvent) -> Void)
    func detach()

    /// Stages `files` and submits in one task, rolling back what it staged on failure (kit `submit`).
    @discardableResult func submit(_ userText: String, files: [ChatAttachments.Checked]) async throws -> JSONValue
    func interrupt() async throws

    func slashCatalog() async throws -> SlashCatalog
    func runSlash(name: String, arg: String, catalog: SlashCatalog?) async throws -> SlashDirective
    func compress(focus: String) async throws -> CompressOutcome

    func answer(_ request: ServerRequest, _ answer: ServerRequestAnswer) async throws
    func decline(_ request: ServerRequest, code: Int, message: String) async throws
    @discardableResult func approvalReceived(requestId: String) async throws -> Bool

    /// Composer controls (ChatControls.swift): the info the chat opened with, steering the running turn,
    /// model and reasoning effort for this chat only, context usage.
    var openInfo: SessionInfoSnapshot? { get }
    func redirect(_ text: String) async throws -> String
    func modelOptions() async throws -> ModelCatalog
    func switchModel(model: String, provider: String, confirmExpensive: Bool) async throws -> ModelSwitchOutcome
    func setReasoning(_ effort: String) async throws -> String
    func usage() async throws -> ContextUsage?
    func contextBreakdown() async throws -> ContextBreakdown

    /// B3 / B4 (ChatRewind.swift): the stored transcript with row ids, a rewind's truncating submit, and a
    /// branch into a new side session (attached, not canonical).
    func historyRows() async throws -> [HistoryRow]
    func rewind(text: String, rowId: Int?, confirmDeep: Bool, rebind: [Int]) async throws -> RewindReceipt
    func branchSession(count: Int, idempotencyKey: String) async throws -> any ChatSessionLink
    /// The session's own title when its open reply named one (a branch).
    var title: String? { get }

    /// B14 (ChatApprovalMode.swift): the bot profile's `approvals.mode`.
    func approvalMode() async throws -> ApprovalMode
    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalMode
}

extension BotChatSession: ChatSessionLink {
    func branchSession(count: Int, idempotencyKey: String) async throws -> any ChatSessionLink {
        try await branch(count: count, idempotencyKey: idempotencyKey)
    }
}

/// Opens a bot's chat. Production: `BotChatSession.openCanonical` on the connected backend.
typealias ChatOpener = @Sendable (Bot) async throws -> any ChatSessionLink
