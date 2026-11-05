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
}

extension BotChatSession: ChatSessionLink {}

/// Opens a bot's chat. Production: `BotChatSession.openCanonical` on the connected backend.
typealias ChatOpener = @Sendable (Bot) async throws -> any ChatSessionLink
