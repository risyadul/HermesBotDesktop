import Foundation

/// Bounds for frames that arrive for a session nobody routes yet.
///
/// Why: the backend attaches our socket to a session INSIDE `session.resume` / `session.create`, before it
/// writes the reply (`tui_gateway/server.py` `_live_session_payload` rebinds the transport under the
/// history lock), so a running turn's deltas, `message.complete` and server→client requests can reach us
/// before the reply does, i.e. before `BotChatSession.attach()` subscribed. The same holds for the
/// re-resume after `session.reclaimed`. Such frames are held per session id (at most `limit` frames, each
/// for at most `window` seconds) and handed, in arrival order, to the first subscriber of that id.
/// `session.events.since` could replay them too, but needs a `seq` watermark per session and an extra RPC
/// after every attach; the local hold covers exactly the reply gap with no wire change.
public enum UnroutedHold {
    public static let window: TimeInterval = 5
    public static let limit = 256
}

public final class EventRouter: @unchecked Sendable {
    public typealias Handler = @Sendable (_ type: String, _ payload: JSONValue?, _ raw: JSONValue) -> Void
    private struct Held {
        let sid: String, type: String, payload: JSONValue?, raw: JSONValue, at: Date
    }

    private let lock = NSLock()
    /// Serializes handler calls: a live dispatch and the replay on subscribe never interleave, so held frames
    /// always reach a new subscriber before newer live ones. Recursive so a handler may subscribe.
    private let delivery = NSRecursiveLock()
    private var handlers: [UUID: (String, Handler)] = [:]
    private var disconnectHandlers: [UUID: @Sendable (String) -> Void] = [:]
    private var tapHandler: Handler?
    private var held: [Held] = []
    private let window: TimeInterval
    private let limit: Int

    init(window: TimeInterval = UnroutedHold.window, limit: Int = UnroutedHold.limit) {
        self.window = window; self.limit = limit
    }

    /// Taps every event. Guarded by `lock`: it can be set while events are being routed.
    public var tap: Handler? {
        get { lock.withLock { tapHandler } }
        set { lock.withLock { tapHandler = newValue } }
    }

    func addDisconnect(_ h: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { disconnectHandlers[id] = h }
        return id
    }

    func disconnected(_ reason: String) {
        let targets = lock.withLock { () -> [@Sendable (String) -> Void] in
            held = []
            return Array(disconnectHandlers.values)
        }
        targets.forEach { $0(reason) }
    }

    /// Registers `h` for `sessionId`, then replays that session's held frames to it (in order).
    func add(sessionId: String, _ h: @escaping Handler) -> UUID {
        let id = UUID()
        delivery.lock(); defer { delivery.unlock() }
        let replay = lock.withLock { () -> [Held] in
            handlers[id] = (sessionId, h)
            guard !sessionId.isEmpty else { return [] }
            prune(Date())
            let mine = held.filter { $0.sid == sessionId }
            held.removeAll { $0.sid == sessionId }
            return mine
        }
        replay.forEach { h($0.type, $0.payload, $0.raw) }
        return id
    }

    func remove(_ id: UUID) {
        lock.withLock { _ = handlers.removeValue(forKey: id); _ = disconnectHandlers.removeValue(forKey: id) }
    }

    func dispatch(type: String, payload: JSONValue?, raw: JSONValue) {
        let sid = raw["params"]?["session_id"]?.string ?? ""
        delivery.lock(); defer { delivery.unlock() }
        let (tap, targets) = lock.withLock { () -> (Handler?, [Handler]) in
            let targets = handlers.values.filter { $0.0 == sid }.map(\.1)
            if targets.isEmpty && !sid.isEmpty { hold(Held(sid: sid, type: type, payload: payload, raw: raw, at: Date())) }
            return (tapHandler, targets)
        }
        tap?(type, payload, raw)
        targets.forEach { $0(type, payload, raw) }
    }

    /// Number of frames currently held, and of live subscriptions (tests).
    var heldCount: Int { lock.withLock { held.count } }
    var subscriberCount: Int { lock.withLock { handlers.count + disconnectHandlers.count } }

    // Under `lock`.
    private func hold(_ h: Held) {
        prune(h.at)
        held.append(h)
        if held.count > limit { held.removeFirst(held.count - limit) }
    }

    // Under `lock`.
    private func prune(_ now: Date) {
        held.removeAll { now.timeIntervalSince($0.at) > window }
    }
}
