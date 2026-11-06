import Foundation

/// Pure reducer over `GET /activity` pages for one Activity inspector (typically one room).
///
/// - Merge by `key`: a row is upserted in place by the plugin (a tool call goes running → ok, a stream
///   grows), and every upsert gets a new `rev` (`store.py`), so a later rev replaces the earlier copy and an
///   older or equal rev never overwrites a newer one.
/// - Cursor (`since` for the next poll): an incremental page (`since > 0`) walks forward by rev and may be
///   cut at `limit`; when it is full, the cursor is the last rev received, so nothing past the cut is
///   skipped (`plugin_api.py:66-69`). Otherwise the server's `rev` (store max) is safe to jump to. The
///   cursor never moves backwards.
/// - Memory: at most `capacity` rows per room id (rows without a room share one bucket) and `totalCapacity`
///   rows overall; the rows with the oldest `updated` are dropped first. A feed for one room drops rows of
///   any other room on arrival (`apply(_:room:)`).
public struct BotActivityFeed: Sendable, Equatable {
    public static let defaultCapacity = 500
    public static let defaultTotalCapacity = 2000

    public let capacity: Int
    public let totalCapacity: Int
    /// `since` for the next `activity(...)` call.
    public private(set) var cursor: Int = 0
    private var byKey: [String: BotActivityRow] = [:]

    public init(capacity: Int = BotActivityFeed.defaultCapacity, totalCapacity: Int = BotActivityFeed.defaultTotalCapacity) {
        self.capacity = max(1, capacity)
        self.totalCapacity = max(1, totalCapacity)
    }

    /// All kept rows, chronological (`ts`, then `rev`).
    public var rows: [BotActivityRow] {
        byKey.values.sorted { ($0.ts, $0.rev, $0.key) < ($1.ts, $1.rev, $1.key) }
    }

    public var isEmpty: Bool { byKey.isEmpty }

    /// `room`: keep only rows of that room (a page asked with `room=` should hold nothing else; the cursor
    /// still advances over the whole page).
    public mutating func apply(_ page: BotActivityPage, room: String? = nil) {
        for row in page.rows {
            if let room, row.roomId != room { continue }
            if let old = byKey[row.key], old.rev >= row.rev { continue }
            byKey[row.key] = row
        }
        let receivedMax = page.rows.map(\.rev).max() ?? 0
        let cutAtLimit = page.since > 0 && page.rows.count >= page.limit
        let next = cutAtLimit ? receivedMax : max(page.rev, receivedMax)
        cursor = max(cursor, next)
        trim()
    }

    private mutating func trim() {
        let buckets = Dictionary(grouping: byKey.values, by: { $0.roomId ?? "" })
        for (_, rows) in buckets where rows.count > capacity {
            let drop = rows.sorted { ($0.updated, $0.rev) < ($1.updated, $1.rev) }.prefix(rows.count - capacity)
            for r in drop { byKey[r.key] = nil }
        }
        if byKey.count > totalCapacity {
            let drop = byKey.values.sorted { ($0.updated, $0.rev) < ($1.updated, $1.rev) }.prefix(byKey.count - totalCapacity)
            for r in drop { byKey[r.key] = nil }
        }
    }

    /// The plugin's own freshness rule (`/bots`, `plugin_api.py:84-94`): `running`/`waiting` count while
    /// updated within `staleAfter`; `streaming` while updated within `streamQuiet`. Precedence: waiting
    /// (needs the user), running, streaming. `current` = the newest row in that phase.
    public static func phase(of rows: [BotActivityRow], now: Double,
                             staleAfter: TimeInterval = BotActivityAPI.staleAfter,
                             streamQuiet: TimeInterval = BotActivityAPI.streamQuiet) -> (BotActivityPhase, BotActivityRow?) {
        func newest(_ status: String, within window: TimeInterval) -> BotActivityRow? {
            rows.filter { $0.status == status && now - $0.updated < window }.max { ($0.updated, $0.rev) < ($1.updated, $1.rev) }
        }
        if let r = newest("waiting", within: staleAfter) { return (.waiting, r) }
        if let r = newest("running", within: staleAfter) { return (.running, r) }
        if let r = newest("streaming", within: streamQuiet) { return (.streaming, r) }
        return (.idle, nil)
    }
}

public enum BotActivityPhase: String, Sendable, Equatable {
    /// Waiting on the user (an approval).
    case waiting
    /// A turn or tool call in flight.
    case running
    /// Reasoning/message text arriving.
    case streaming
    case idle
}
