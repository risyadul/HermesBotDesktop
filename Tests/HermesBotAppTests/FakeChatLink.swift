import Foundation
@testable import HermesBotApp
@testable import HermesGatewayKit

/// In-memory `ChatSessionLink` for headless ChatModel tests and window layout tests: records calls,
/// answers from configurable closures, never touches a gateway. Like `BotChatSession` it is single-consumer
/// (a second `onEvent` asserts) and buffers events emitted before `onEvent`, flushing them in order.
final class FakeChatLink: ChatSessionLink, @unchecked Sendable {
    private let lock = NSLock()
    let sessionId = "rt-fake"
    let storedSessionId = "st-fake"
    let isCanonical = true
    let history: [ChatHistoryMessage]
    let openRequests: [ServerRequest]
    let inflight: InflightTurn?

    private var _calls: [String] = []
    private var _detached = false
    private var handler: (@Sendable (ChatEvent) -> Void)?
    private var buffered: [ChatEvent] = []
    private var consumerSet = false
    var calls: [String] { lock.withLock { _calls } }
    var detached: Bool { lock.withLock { _detached } }

    /// Overridable behaviour (set before use). `stageError`: the file name whose staging fails (the kit
    /// then throws `StageFailure` after rolling back, which the fake records as `rollback:<names>`).
    var stageError: String?
    var submitStatus = "streaming"
    var catalogResult: @Sendable () throws -> SlashCatalog = {
        SlashCatalog(result: ["pairs": [["/model", "Switch model"], ["/goal", "Set a goal"], ["/undo", "Undo the last turn"]]])
    }
    var slashResult: @Sendable (String, String) throws -> SlashDirective = { name, _ in .output("/\(name) ran") }
    var sendError: Error?
    var compressHistory: [ChatHistoryMessage]?
    /// Delay before `submit` returns (lets tests observe the sending state).
    var submitDelay: UInt64 = 0

    init(history: [ChatHistoryMessage] = [], openRequests: [ServerRequest] = [], inflight: InflightTurn? = nil) {
        self.history = history
        self.openRequests = openRequests
        self.inflight = inflight
    }

    private func record(_ s: String) { lock.withLock { _calls.append(s) } }

    func onEvent(_ h: @escaping @Sendable (ChatEvent) -> Void) {
        lock.withLock {
            assert(!consumerSet, "FakeChatLink is single-consumer: onEvent was already set")
            consumerSet = true
            guard !_detached else { return }
            handler = h
            let pending = buffered
            buffered = []
            pending.forEach(h)
        }
    }
    func emit(_ e: ChatEvent) {
        let h = lock.withLock { () -> (@Sendable (ChatEvent) -> Void)? in
            if handler == nil && !_detached && !consumerSet { buffered.append(e) }
            return handler
        }
        h?(e)
    }
    func detach() { lock.withLock { _detached = true; handler = nil; buffered = [] }; record("detach") }

    func submit(_ userText: String, files: [ChatAttachments.Checked]) async throws -> JSONValue {
        if submitDelay > 0 { try await Task.sleep(nanoseconds: submitDelay) }
        if let bad = stageError, let i = files.firstIndex(where: { $0.name == bad }) {
            record("rollback:\(files.prefix(i).map(\.name).joined(separator: ","))")
            throw ChatAttachments.StageFailure(index: i, message: "\(bad) could not be attached.")
        }
        record("send:\(userText)|\(files.map(\.name).joined(separator: ","))")
        if let sendError { throw sendError }
        return ["status": .string(submitStatus)]
    }
    func interrupt() async throws { record("interrupt") }
    func slashCatalog() async throws -> SlashCatalog { record("catalog"); return try catalogResult() }
    func runSlash(name: String, arg: String, catalog: SlashCatalog?) async throws -> SlashDirective {
        record("slash:\(name) \(arg)")
        return try slashResult(name, arg)
    }
    func compress(focus: String) async throws -> CompressOutcome {
        record("compress:\(focus)")
        return CompressOutcome(compressed: true, message: nil, beforeMessages: 40, afterMessages: 6, history: compressHistory)
    }
    func answer(_ request: ServerRequest, _ answer: ServerRequestAnswer) async throws { record("answer:\(request.id)") }
    func decline(_ request: ServerRequest, code: Int, message: String) async throws { record("decline:\(request.id):\(code)") }
    func approvalReceived(requestId: String) async throws -> Bool { record("received:\(requestId)"); return true }
}
