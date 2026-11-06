import Combine
import Foundation
import HermesGatewayKit

struct PreparedMessageContent: Equatable, Sendable {
    let blocks: [MarkdownBlock]
    let media: [MediaRef]

    nonisolated static func parse(_ text: String, cacheResult: Bool = true) -> Self {
        let parts = MediaTags.split(text)
        let visible = parts.media.isEmpty ? text : parts.text
        return Self(blocks: visible.isEmpty ? [] : MarkdownBlock.parse(visible, cacheResult: cacheResult),
                    media: parts.media)
    }
}

struct MessageRenderRequest: Equatable, Sendable {
    let text: String
    let identity: String?
    let streaming: Bool
}

enum MessageRenderAdmissionError: Error, Sendable {
    case capacity
}

/// Cancellation is visible to a just-starting detached parser before its actor mailbox handles the
/// removal message. This closes the race between finishing one job and starting a cancelled next job.
private final class MessageParseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// The scheduler never runs Foundation's synchronous parser on its actor. Cancellation and admission
/// remain responsive while one detached parse is busy, with count/byte bounds on pending requests.
actor MarkdownRenderWorker {
    static let shared = MarkdownRenderWorker()
    typealias Parser = @Sendable (MessageRenderRequest) async throws -> PreparedMessageContent

    struct Snapshot: Sendable {
        let pendingCount: Int
        let pendingBytes: Int
        let activeCount: Int
        let activeBytes: Int
        let rejectedCount: Int
    }

    private struct Job {
        let client: UUID
        let ticket: UUID
        let request: MessageRenderRequest
        let bytes: Int
        let continuation: CheckedContinuation<PreparedMessageContent, any Error>
        let cancellation: MessageParseCancellation
    }

    private struct Active {
        let client: UUID
        let ticket: UUID
        let bytes: Int
        var continuation: CheckedContinuation<PreparedMessageContent, any Error>?
        let cancellation: MessageParseCancellation
    }

    private let maxPendingCount: Int
    private let maxPendingBytes: Int
    private let parser: Parser
    private var pending: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var pendingBytes = 0
    private var active: Active?
    private var activeTask: Task<Void, Never>?
    private var rejectedCount = 0

    init(maxPendingCount: Int = 8, maxPendingBytes: Int = 8 * 1024 * 1024,
         parser: @escaping Parser = { request in
             try Task.checkCancellation()
             // Streaming prefixes are transient, not entries in the shared settled-message cache.
             return PreparedMessageContent.parse(request.text, cacheResult: !request.streaming)
         }) {
        self.maxPendingCount = max(0, maxPendingCount)
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.parser = parser
    }

    func snapshot() -> Snapshot {
        Snapshot(pendingCount: pending.count, pendingBytes: pendingBytes,
                 activeCount: active == nil ? 0 : 1, activeBytes: active?.bytes ?? 0,
                 rejectedCount: rejectedCount)
    }

    func prepare(_ request: MessageRenderRequest, client: UUID = UUID()) async throws -> PreparedMessageContent {
        let ticket = UUID()
        let cancellation = MessageParseCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                admit(Job(client: client, ticket: ticket, request: request,
                          bytes: request.text.utf8.count, continuation: continuation, cancellation: cancellation))
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(client: client, ticket: ticket) }
        }
    }

    private func admit(_ job: Job) {
        // A reused row may replace its previous generation before that CPU operation has returned.
        if active?.client == job.client {
            active?.continuation?.resume(throwing: CancellationError())
            active?.continuation = nil
            active?.cancellation.cancel()
            activeTask?.cancel()
        }
        removePending(client: job.client)
        if active == nil {
            // A single large reply is allowed when the worker is free; it must eventually get a rich
            // render even if its source is larger than the pending-byte budget.
            start(job)
        } else if pending.count < maxPendingCount, job.bytes <= maxPendingBytes - pendingBytes {
            pending[job.client] = job
            pendingBytes += job.bytes
            order.append(job.client)
        } else {
            rejectedCount &+= 1
            job.continuation.resume(throwing: MessageRenderAdmissionError.capacity)
        }
    }

    private func removePending(client: UUID) {
        guard let old = pending.removeValue(forKey: client) else { return }
        pendingBytes -= old.bytes
        order.removeAll { $0 == client }
        old.cancellation.cancel()
        old.continuation.resume(throwing: CancellationError())
    }

    private func cancel(client: UUID, ticket: UUID) {
        if pending[client]?.ticket == ticket { removePending(client: client) }
        if active?.ticket == ticket {
            active?.continuation?.resume(throwing: CancellationError())
            active?.continuation = nil
            active?.cancellation.cancel()
            activeTask?.cancel()
            // Synchronous Foundation parsing cannot be interrupted halfway through. Keep this slot
            // occupied until the detached operation actually returns, so global CPU concurrency is one.
        }
    }

    private func start(_ job: Job) {
        active = Active(client: job.client, ticket: job.ticket, bytes: job.bytes,
                        continuation: job.continuation, cancellation: job.cancellation)
        let ticket = job.ticket
        let request = job.request
        let parser = parser
        let cancellation = job.cancellation
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<PreparedMessageContent, any Error>
            do {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                result = .success(try await parser(request))
            } catch {
                result = .failure(error)
            }
            // Even a cancelled synchronous parse must release its occupied scheduler slot.
            await self?.complete(ticket: ticket, result: result)
        }
    }

    private func complete(ticket: UUID, result: Result<PreparedMessageContent, any Error>) {
        guard active?.ticket == ticket else { return }
        active?.continuation?.resume(with: result)
        active = nil
        activeTask = nil
        guard !order.isEmpty else { return }
        let client = order.removeFirst()
        if let next = pending.removeValue(forKey: client) {
            pendingBytes -= next.bytes
            start(next)
        }
    }
}

/// Each realized message has at most one in-flight parse plus the latest pending revision. In
/// particular, incoming text does not restart a debounce timer and starve rendering indefinitely.
@MainActor
final class MessageRenderState: ObservableObject {
    struct Rendered: Equatable, Sendable {
        let request: MessageRenderRequest
        let content: PreparedMessageContent
    }
    typealias Parser = @Sendable (MessageRenderRequest) async throws -> PreparedMessageContent

    @Published private(set) var rendered: Rendered?
    private let parser: Parser
    private var requested: MessageRenderRequest?
    private var pending: MessageRenderRequest?
    private var inFlight: MessageRenderRequest?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var retrying = false
    private var retryAttempt = 0

    init(parser: Parser? = nil, worker: MarkdownRenderWorker = .shared) {
        let client = UUID()
        self.parser = parser ?? { try await worker.prepare($0, client: client) }
    }

    func request(_ request: MessageRenderRequest) {
        if let previous = requested, previous.identity != request.identity {
            cancel()
            rendered = nil
        }
        guard requested != request else { return }
        requested = request
        if inFlight != nil || retrying {
            pending = request
        } else if rendered?.request != request {
            start(request)
        }
    }

    /// Keeps completed content while a row is offscreen, but prevents obsolete CPU results from
    /// publishing after disappearance/reuse. Reappearing rows can immediately display that content.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        inFlight = nil
        pending = nil
        requested = nil
        retrying = false
        retryAttempt = 0
    }

    private func start(_ request: MessageRenderRequest) {
        inFlight = request
        let current = generation
        let parser = parser
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await parser(request)
                guard !Task.isCancelled else { return }
                await self?.finished(request, result: result, retryable: false, generation: current)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.finished(request, result: nil, retryable: error is MessageRenderAdmissionError,
                                     generation: current)
            }
        }
    }

    private func finished(_ request: MessageRenderRequest, result: PreparedMessageContent?, retryable: Bool,
                          generation current: Int) {
        guard current == generation, inFlight == request else { return }
        task = nil
        inFlight = nil
        // An intermediate revision of the same message is useful while the latest one is parsing.
        // A replacement row has a new generation, and can never receive this result.
        if let result {
            rendered = Rendered(request: request, content: result)
            retryAttempt = 0
        }
        if retryable {
            scheduleRetry()
            return
        }
        if let next = pending {
            pending = nil
            if rendered?.request != next { start(next) }
        }
    }

    private func scheduleRetry() {
        // No request/continuation is parked in the global scheduler when it is full. The realized row
        // keeps its one latest value and retries with bounded backoff; disappearance cancels this timer.
        retrying = true
        let delay = UInt64(50_000_000) << min(retryAttempt, 4)
        retryAttempt = min(retryAttempt + 1, 4)
        let current = generation
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.retrying = false
            self.pending = nil
            if let latest = self.requested { self.start(latest) }
        }
    }

    deinit { task?.cancel() }
}
