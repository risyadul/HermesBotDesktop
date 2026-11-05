import Foundation

/// A sleep the test drives instead of the clock: every call is recorded and parks until `advance()` resumes
/// it, or throws `CancellationError` as soon as its task is cancelled (like `Task.sleep`). Tests assert on the
/// recorded sequence and on `pending` (loops parked right now) instead of sleeping and hoping.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var _requested: [TimeInterval] = []

    /// Every duration asked for, in order.
    var requested: [TimeInterval] { lock.withLock { _requested } }
    /// Sleeps parked now.
    var pending: Int { lock.withLock { waiters.count } }

    var sleep: @Sendable (TimeInterval) async throws -> Void { { [self] in try await self.park($0) } }

    /// Resumes every parked sleep.
    func advance() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let w = Array(waiters.values)
            waiters = [:]
            return w
        }
        all.forEach { $0.resume() }
    }

    private func park(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    _requested.append(seconds)
                    if Task.isCancelled { return true }
                    waiters[id] = c
                    return false
                }
                if cancelled { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}
