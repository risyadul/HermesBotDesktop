import Foundation

/// Owns the poll loop of one room (docs/gateway-contract.md §7.2). There is no WS push for rooms, so
/// the loop runs `RoomSync.refresh` (`groups.log {since_seq}` + `groups.state`) at
/// `RoomPollPolicy` cadence.
///
/// Lifecycle rule: at most ONE loop is current. `start()` opens a new generation, `stop()` ends it.
/// `GatewayClient.call` is not cancellation-aware, so a cancelled loop can still be parked on an RPC
/// whose response arrives later — possibly after a newer loop applied a newer snapshot. Every
/// result is therefore checked against the generation it was requested under before it is applied,
/// published or followed by a sleep. A stale result is dropped (`droppedStale`). A result whose
/// cursor is behind the applied one is dropped too.
@MainActor
public final class RoomPoller {
    public struct Update: Sendable {
        public let timeline: RoomTimeline
        public let state: RoomStateSnapshot
        /// Events with `seq` above the cursor before this sync.
        public let newEvents: [RoomEvent]
    }

    public let roomId: String
    private let source: RoomSource
    public private(set) var timeline: RoomTimeline
    public private(set) var state: RoomStateSnapshot?
    /// Called on the main actor for every applied sync of the current generation, never after `stop()`.
    public var onUpdate: ((Update) -> Void)?
    /// Called for a failed sync of the current generation, never after `stop()`.
    public var onError: ((Error) -> Void)?
    /// Wait before the next sync; defaults to `RoomPollPolicy`.
    public var interval: (RoomTimeline, RoomStateSnapshot?) -> TimeInterval = { t, s in
        RoomPollPolicy.interval(driver: s?.driver, timeline: t)
    }

    public private(set) var generation = 0
    public private(set) var appliedCount = 0
    /// Results that came back for a generation that is no longer current (or behind the cursor).
    public private(set) var droppedStale = 0
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    public init(source: RoomSource, roomId: String, timeline: RoomTimeline = RoomTimeline()) {
        self.source = source; self.roomId = roomId; self.timeline = timeline
    }

    public var isRunning: Bool { loop != nil }

    /// Starts polling unless a loop is already current.
    public func start() {
        guard loop == nil else { return }
        generation &+= 1
        let gen = generation
        loop = Task { [weak self] in
            while true {
                guard let self, self.isCurrent(gen) else { return }
                guard await self.syncOnce(gen) else { return }
                let wait = self.interval(self.timeline, self.state)
                guard wait > 0 else { continue }
                let s = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard self.isCurrent(gen) else { s.cancel(); return }
                self.sleeper = s
                await s.value
                if self.sleeper == s { self.sleeper = nil }
            }
        }
    }

    /// Ends the current generation: nothing it still has in flight is applied or published.
    public func stop() {
        generation &+= 1
        loop?.cancel(); loop = nil
        sleeper?.cancel(); sleeper = nil
    }

    /// Ends the current loop's wait so the next sync runs now (after a send/stop/retry/approve).
    public func nudge() { sleeper?.cancel() }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    /// One sync; returns whether the loop of `gen` should go on.
    private func syncOnce(_ gen: Int) async -> Bool {
        let base = timeline
        do {
            let (t, s) = try await RoomSync.refresh(source, roomId: roomId, timeline: base)
            guard isCurrent(gen) else { droppedStale += 1; return false }
            guard t.cursor >= timeline.cursor else { droppedStale += 1; return true }
            timeline = t; state = s; appliedCount += 1
            // Applied events are in seq order; only the newly appended suffix can be above this cursor.
            let newEvents = Array(t.events.reversed().prefix { $0.seq > base.cursor }.reversed())
            onUpdate?(Update(timeline: t, state: s, newEvents: newEvents))
        } catch {
            guard isCurrent(gen) else { droppedStale += 1; return false }
            onError?(error)
        }
        return isCurrent(gen)
    }
}
