import Foundation
import HermesGatewayKit
import SwiftUI

// Sidebar room rows (roadmap C1.5, C1.7): last-message preview + age and the "needs you" badge, for every
// room, opened or not. A room's own `RoomModel` only polls while its pane is on screen, so the hub keeps a
// light watch of its own: `groups.list` (each row carries `latest_seq`), then `groups.log` for the tail of
// a room whose log moved, then `groups.state` for rooms with an unsettled discussion (an approval can only be
// pending while a turn runs). The open room feeds the hub from its own polls (`absorb`).

@MainActor
final class RoomDigestHub: ObservableObject {
    @Published private(set) var digests: [String: RoomDigest] = [:]
    /// Rooms where a bot waits on an approval (`driver_status.pending_actions`, kind `approval`).
    @Published private(set) var approvals: Set<String> = []
    /// Per room: the log seq the user has seen (the room's pane was on screen). Persisted, so an `@user`
    /// the user already read does not badge again after a relaunch.
    @Published private(set) var seenThrough: [String: Int]

    /// Newest events per room (bounded): what digests are built from.
    private var tails: [String: [RoomEvent]] = [:]
    private var rooms: [String: RoomSummary] = [:]
    private var loop: Task<Void, Never>?
    private let defaults: UserDefaults
    /// Bumped by `start`/`stop`: a pass that started under an older generation applies nothing.
    private var generation = 0
    /// Where the next pass starts in the list of unsettled rooms, so every one gets its `groups.state` turn.
    private var stateOffset = 0

    static let seenKey = "hba.roomSeenThrough"
    /// Events read per room when its log moved (enough to hold its latest messages).
    static let tailFetch = 40
    static let tailKeep = 200
    /// Rooms asked for `groups.state` per pass.
    static let stateBudget = 8
    static let activeInterval: TimeInterval = 5
    static let idleInterval: TimeInterval = 15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenThrough = (defaults.dictionary(forKey: Self.seenKey) as? [String: Int]) ?? [:]
    }

    // MARK: reading

    /// The badge for a room's row: a pending approval, or an unanswered `@user` the user has not seen. Never
    /// for the room on screen (its action cards and messages are in front of the user).
    func needsYou(_ roomId: String, onScreen: Bool) -> NeedsYou? {
        guard !onScreen else { return nil }
        if approvals.contains(roomId) { return .approval }
        return digests[roomId]?.needsYou(seenThrough: seenThrough[roomId] ?? 0) == true ? .mention : nil
    }

    enum NeedsYou: Equatable { case approval, mention }

    // MARK: feeding

    /// The open room's model applied a poll: its full timeline replaces the tail, its driver status gives
    /// the approvals, and while its pane is on screen everything up to its cursor counts as seen.
    func absorb(_ model: RoomModel) {
        absorb(roomId: model.id, room: model.room, events: model.timeline.events, driver: model.driver,
               onScreen: model.isOnScreen, cursor: model.timeline.cursor)
    }

    func absorb(roomId: String, room: RoomSummary, events: [RoomEvent], driver: RoomDriverStatus?, onScreen: Bool, cursor: Int) {
        rooms[roomId] = room
        setTail(roomId, Array(events.suffix(Self.tailKeep)))
        setApproval(roomId, driver)
        if onScreen { markSeen(roomId, through: cursor) }
    }

    /// Everything up to `seq` in the room was on screen. Monotonic.
    func markSeen(_ roomId: String, through seq: Int) {
        guard seq > (seenThrough[roomId] ?? 0) else { return }
        seenThrough[roomId] = seq
        defaults.set(seenThrough, forKey: Self.seenKey)
    }

    /// A disbanded room: its row is gone, so is its state.
    func forget(_ roomId: String) {
        tails[roomId] = nil; rooms[roomId] = nil; digests[roomId] = nil; approvals.remove(roomId)
        if seenThrough.removeValue(forKey: roomId) != nil { defaults.set(seenThrough, forKey: Self.seenKey) }
    }

    private func setTail(_ roomId: String, _ events: [RoomEvent]) {
        tails[roomId] = events
        let d = RoomDigest.make(events: events, room: rooms[roomId])
        if digests[roomId] != d { digests[roomId] = d }
        if !d.awaiting { setApproval(roomId, nil) }
    }

    private func setApproval(_ roomId: String, _ driver: RoomDriverStatus?) {
        let pending = (driver?.pendingActions ?? []).contains { if case .approval = $0 { return true }; return false }
        if pending != approvals.contains(roomId) {
            if pending { approvals.insert(roomId) } else { approvals.remove(roomId) }
        }
    }

    // MARK: polling

    /// Starts the watch. `listed`: the rooms the caller just loaded (connect), so the first pass does not
    /// list them again.
    func start(directory: any RoomDirectory, listed: [RoomSummary]? = nil) {
        stop()
        let gen = generation
        loop = Task { [weak self] in
            var listed = listed
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                await self.refresh(with: directory, listed: listed)
                listed = nil
                let wait = self.digests.values.contains(where: \.awaiting) ? Self.activeInterval : Self.idleInterval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// One pass. Errors are logged and skipped: the rows keep what they showed, the next pass tries again.
    /// A pass that `stop`/`start` overtook applies nothing more.
    func refresh(with directory: any RoomDirectory, listed known: [RoomSummary]? = nil) async {
        let gen = generation
        let listed: [RoomSummary]
        if let known { listed = known } else {
            do { listed = try await directory.allRooms() } catch {
                AppModel.shared.log("room digests: groups.list failed: \(Redaction.describe(error))")
                return
            }
        }
        guard gen == generation else { return }
        for room in listed { rooms[room.roomId] = room }
        for id in Set(digests.keys).subtracting(listed.map(\.roomId)) { tails[id] = nil; digests[id] = nil; approvals.remove(id) }
        for room in listed {
            let known = tails[room.roomId]?.last?.seq ?? 0
            guard let latest = room.latestSeq, latest > known || tails[room.roomId] == nil else { continue }
            let since = max(known, latest - Self.tailFetch)
            do {
                let page = try await directory.roomLog(roomId: room.roomId, sinceSeq: since, limit: Self.tailFetch)
                guard gen == generation else { return }
                // A tail that does not continue the one held (older events skipped) replaces it.
                // The open room's own poll replaced the tail during the await: it is newer, keep it.
                guard (tails[room.roomId]?.last?.seq ?? 0) == known else { continue }
                let held = since == known ? (tails[room.roomId] ?? []) : []
                setTail(room.roomId, Array((held + page.events.filter { $0.seq > since }).suffix(Self.tailKeep)))
            } catch {
                AppModel.shared.log("room digests: groups.log \(room.roomId) failed: \(Redaction.describe(error))")
            }
        }
        let unsettled = listed.map(\.roomId).filter { digests[$0]?.awaiting == true }
        let start = unsettled.isEmpty ? 0 : stateOffset % unsettled.count
        stateOffset += Self.stateBudget
        for id in (unsettled[start...] + unsettled[..<start]).prefix(Self.stateBudget) {
            do {
                let state = try await directory.roomState(roomId: id)
                guard gen == generation else { return }
                setApproval(id, state.driver)
            } catch {
                AppModel.shared.log("room digests: groups.state \(id) failed: \(Redaction.describe(error))")
            }
        }
    }
}

// MARK: - sidebar row

/// A Group Chat row in the sidebar: room avatars, name and age of the last message, then the last message
/// ("Alpha: …", "You: …") or, before any message, the members. Trailing: the "needs you" badge, else the
/// breathing dot while a round runs.
struct RoomRowContent: View {
    let room: RoomSummary
    @ObservedObject var digests: RoomDigestHub
    let live: RoomModel?
    let onScreen: Bool
    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        let digest = digests.digests[room.roomId]
        HStack(spacing: DS.Space.gutter) {
            RoomAvatarStack(identities: room.members.map { avatars.identity(profile: $0.profile, title: $0.title) })
            VStack(alignment: .leading, spacing: DS.Space.s0 / 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(room.name).font(DS.Typeface.bodyMedium).foregroundStyle(DS.Palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if let time = digest?.preview?.time, time > 0 {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(RoomDigest.age(of: time, now: context.date))
                                .font(DS.Typeface.caption.monospacedDigit()).foregroundStyle(DS.Palette.muted)
                        }
                    }
                }
                Text(Self.subtitle(room: room, digest: digest))
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted).lineLimit(1)
            }
            if let badge = digests.needsYou(room.roomId, onScreen: onScreen) {
                NeedsYouBadge(kind: badge)
            } else if let live {
                RoomLiveDot(model: live)
            }
        }
    }

    static func subtitle(room: RoomSummary, digest: RoomDigest?) -> String {
        if let p = digest?.preview, !p.text.isEmpty { return "\(p.author): \(p.text)" }
        return "\(room.members.count) bots · " + room.members.map { "@\($0.handle)" }.joined(separator: " ")
    }
}

/// `attention` pill: a bot asked the user (`@user`) or waits on an approval.
struct NeedsYouBadge: View {
    let kind: RoomDigestHub.NeedsYou

    var body: some View {
        let label = Self.label(kind)
        Image(systemName: kind == .approval ? "hand.raised.fill" : "at")
            .font(DS.Typeface.iconSmall).foregroundStyle(DS.Palette.attention)
            .padding(.horizontal, DS.Space.s1 + DS.Space.s0).padding(.vertical, DS.Space.s0 / 2)
            .background(DS.Palette.attentionSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.attentionRing, lineWidth: DS.Stroke.hairline))
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    static func label(_ kind: RoomDigestHub.NeedsYou) -> String {
        kind == .approval ? "A bot in this group chat needs your approval" : "A bot in this group chat needs your input"
    }
}
