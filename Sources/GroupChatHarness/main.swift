import Foundation
import HermesGatewayKit

// Headless M2 harness: exercises the Group Chat kit (`groups.*` + RoomSync polling) against a live
// backend and writes token-free evidence (scenario.json + wire.log) per scenario.
//
// usage: group-chat-harness <scenario> <evidence-dir> [args…]
//   list                      attach; capabilities (+ per-profile approval_mode) and groups.list. Read-only.
//   multi  <botA,botB>        attach; create hba room, send (no mention → all members), poll to settled, disband
//   stop   <botA,botB>        attach; long prompt to botA, groups.stop while running → turn.cancelled, disband
//   retry-attach <botA,botB>  own same-home serve S (private lock dir) runs a turn; S is SIGKILLed mid-turn;
//                             the attached backend takes the lease over → indeterminate → deferred →
//                             groups.retry via the attached backend → settled; disband
//   approve-iso / retry-iso   the same flows in an isolated home (~/.hermes-bot-app-spike/m2) where
//                             approvals.mode is manual (the user's profiles all have approvals off)
//   serve-iso <seconds> [retry]  keep an isolated serve up for the app to attach to (optionally after
//                             leaving a room with a lost turn that needs Retry)
//   cleanup <@manifest.jsonl|ids|@ids.txt>  attach; for exactly these hba rooms: disband the live ones (retry
//                             on 5114), then bounded rounds that re-discover their hidden member sessions by
//                             provenance (RoomSessionCleaner), session.close idle owned runtimes and
//                             session.delete owned rows (4023 → next round); exit 1 unless it settles empty
//   audit <same>              attach; read-only discovery + exact readback of the rooms' ledger keys; exit 1
//                             if anything owned/unresolved/re-created is left
//   ledger-import <dir[,…]>   append the keys earlier attached cleanups deleted (their wire.log +
//                             scenario.json) to the session ledger (imported_deleted, origin = dir;
//                             HBA_IMPORT_BACKEND must match the report's backend). No backend call.
//   ledger-audit / ledger-cleanup  attach; exact readback (and, for cleanup, re-delete of title-accounting
//                             placeholders) of EVERY ledger key of this backend's scope
// Session ledger: `HBA_SESSION_LEDGER` (default evidence/m2/session-ledger.jsonl), entries scoped by the
// rendezvous lock dir (`HERMES_BOT_APP_LOCK_DIR`), so isolated-home keys are never read back here.
// Exit 0 only when the scenario's assertions hold.

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
@Sendable func say(_ s: String) {
    print("[\(String(format: "%8.3f", Date().timeIntervalSince(t0)))] \(s)")
}

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var wire: [String] = []
    var steps: [JSONValue] = []
    var polls: [JSONValue] = []
    var summary: [String: JSONValue] = [:]
    func step(_ name: String, _ v: JSONValue = .null) {
        let t = Date().timeIntervalSince(t0)
        lock.withLock { steps.append(["t": .number(t), "step": .string(name), "value": v]) }
    }
    func wireLine(_ out: Bool, _ line: String) {
        let t = Date().timeIntervalSince(t0)
        lock.withLock { wire.append("\(String(format: "%8.3f", t)) \(out ? ">>" : "<<") \(line)") }
    }
    func write(_ dir: URL, ok: Bool) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.withLock {
            var doc = summary
            doc["ok"] = .bool(ok); doc["steps"] = .array(steps); doc["polls"] = .array(polls)
            try? JSONValue.object(doc).compactJSON().write(to: dir.appendingPathComponent("scenario.json"), atomically: true, encoding: .utf8)
            try? wire.joined(separator: "\n").write(to: dir.appendingPathComponent("wire.log"), atomically: true, encoding: .utf8)
        }
    }
}

struct Fail: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: group-chat-harness <list|multi|stop|retry-attach|approve-iso|retry-iso|serve-iso|cleanup|audit|key-inventory|ledger-import|ledger-audit|ledger-cleanup> <evidence-dir> [args]")
    exit(64)
}
let scenario = args[1]
let evidence = URL(fileURLWithPath: args[2])
let rec = Recorder()
let stamp = Int(Date().timeIntervalSince1970)
let createdRoomsFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/m2/created-rooms.txt")
/// Rooms created on a backend that cleanup must be able to recognise later (name + roster + created_at;
/// `RoomManifestEntry`). Override with `HBA_ROOM_MANIFEST=<path>`.
let roomManifestFile = ProcessInfo.processInfo.environment["HBA_ROOM_MANIFEST"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/m2/room-manifest.jsonl")

/// Test room names embed the room id, so the name in a member's first prompt
/// (`[Discussion: "<name>"]`) identifies exactly one room.
func testRoomName(_ roomId: String) -> String { "hba \(roomId)" }

func noteCreated(_ room: RoomSummary) {
    try? FileManager.default.createDirectory(at: createdRoomsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: createdRoomsFile) { h.seekToEndOfFile(); h.write(Data((room.roomId + "\n").utf8)); try? h.close() }
    else { try? (room.roomId + "\n").write(to: createdRoomsFile, atomically: true, encoding: .utf8) }
    do { try RoomManifest.append(RoomManifestEntry(room: room), to: roomManifestFile) }
    catch { say("room manifest append failed: \(Redaction.describe(error))") }
}

/// Rooms created in the ISOLATED home (approve/retry fixtures): their own manifest, so a cleanup of the
/// user's install never sees them and an isolated cleanup (`cleanup @<this file>` with
/// `HERMES_BOT_APP_LOCK_DIR` on the isolated lock dir) can attribute their sessions. Names embed the id.
let isoRoomManifestFile = ProcessInfo.processInfo.environment["HBA_ISO_ROOM_MANIFEST"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/m2/iso-room-manifest.jsonl")

/// Durable record of every member-session key a cleanup proved (`SessionLedger`).
let sessionLedgerFile = ProcessInfo.processInfo.environment["HBA_SESSION_LEDGER"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/m2/session-ledger.jsonl")

/// Which backend/home a ledger key belongs to: the rendezvous lock dir this process discovers in (the
/// user's install and the isolated home use different ones).
func ledgerScope() -> String { "lockdir:" + Backend.Options.fromEnvironment().lockDir.standardizedFileURL.path }

func noteIsoCreated(_ room: RoomSummary) {
    do { try RoomManifest.append(RoomManifestEntry(room: room), to: isoRoomManifestFile) }
    catch { say("iso room manifest append failed: \(Redaction.describe(error))") }
}

// MARK: - connection helpers

/// Attach only (never spawn): M2 evidence must run against the user's running backend.
func attach() async throws -> Backend {
    var o = Backend.Options.fromEnvironment()
    o.allowSpawn = false
    let b = try await Backend.connect(o, log: say)
    guard b.mode.isAttached else { throw Fail("expected attach, got \(b.mode)") }
    b.client.onWire = { out, line in rec.wireLine(out, "[attached] " + line) }
    rec.summary["backend"] = .string(b.mode.description)
    return b
}

func connect(_ serve: ServeProcess, label: String) async throws -> GatewayClient {
    guard let url = serve.wsURL else { throw Fail("\(label): no ws url") }
    let c = GatewayClient(url: url)
    try await c.connect()
    c.onWire = { out, line in rec.wireLine(out, "[\(label)] " + line) }
    return c
}

func members(_ spec: String, from bots: [Bot]) throws -> [RoomMember] {
    try spec.split(separator: ",").map { name in
        guard let bot = bots.first(where: { $0.name == name }), let m = RoomMember.forBot(bot) else { throw Fail("no bot \(name)") }
        return m
    }
}

// MARK: - polling

struct PollResult { var timeline: RoomTimeline; var state: RoomStateSnapshot }

/// Polls with `RoomSync.refresh` at `RoomPollPolicy` cadence (capped at 1 s for evidence) until `done`.
func poll(_ api: GroupsAPI, _ roomId: String, from timeline: RoomTimeline = RoomTimeline(), label: String,
          timeout: TimeInterval, maxInterval: TimeInterval = 1.0,
          until done: (RoomTimeline, RoomStateSnapshot) -> Bool) async throws -> PollResult {
    var t = timeline
    let end = Date().addingTimeInterval(timeout)
    var lastPrinted = t.cursor
    while true {
        let (nt, st) = try await RoomSync.refresh(api, roomId: roomId, timeline: t)
        t = nt
        let d = st.driver
        let pending: [JSONValue] = (d?.pendingActions ?? []).map { .string($0.id) }
        rec.lock.withLock {
            rec.polls.append(["t": .number(Date().timeIntervalSince(t0)), "label": .string(label), "cursor": .number(Double(t.cursor)),
                              "working": d.map { .bool($0.working) } ?? .null, "blocked": d.map { .bool($0.blocked) } ?? .null,
                              "counts": .object((d?.counts ?? [:]).mapValues { .number(Double($0)) }),
                              "pending_actions": .array(pending), "awaiting_discussion": .bool(t.awaitingDiscussion)])
        }
        for e in t.events where e.seq > lastPrinted {
            let who = e.memberId.map { " member=\($0)" } ?? ""
            let txt = (e.text ?? e.payload["reason_code"]?.string ?? e.payload["reason"]?.string ?? e.payload["error"]?.string ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            say("  log seq=\(e.seq) \(e.kind)\(who) \(txt.prefix(140))")
        }
        lastPrinted = t.cursor
        if done(t, st) { return PollResult(timeline: t, state: st) }
        if Date() > end { throw Fail("\(label): timeout after \(Int(timeout))s (working=\(d?.working ?? false) counts=\(d?.counts ?? [:]))") }
        let wait = min(maxInterval, RoomPollPolicy.interval(driver: d, timeline: t))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}

func eventsJSON(_ t: RoomTimeline) -> JSONValue {
    .array(t.events.map { e in
        ["seq": .number(Double(e.seq)), "kind": .string(e.kind), "event_id": .string(e.eventId), "actor": e.actor,
         "payload": e.payload, "created_at": .number(e.createdAt)]
    })
}

func settledAndIdle(_ t: RoomTimeline, _ s: RoomStateSnapshot) -> Bool {
    !t.awaitingDiscussion && s.driver?.working == false && !t.behind
}

/// Disband with a scheduled retry: `groups.disband` refuses (5114 "still stopping") while a stop is
/// unacknowledged.
func disband(_ api: GroupsAPI, _ roomId: String, attempts: Int = 18, every: TimeInterval = 10) async -> Bool {
    for i in 1...attempts {
        do {
            let r = try await api.disbandRoom(roomId: roomId)
            say("disband \(roomId) → tombstone disbanded_at=\(r["tombstone"]?["disbanded_at"]?.double ?? 0) (attempt \(i))")
            rec.step("disband", ["room_id": .string(roomId), "attempt": .number(Double(i)), "result": r])
            return true
        } catch {
            let msg = Redaction.describe(error)
            say("disband \(roomId) attempt \(i) failed: \(msg)")
            rec.step("disband_failed", ["room_id": .string(roomId), "attempt": .number(Double(i)), "error": .string(msg)])
            if msg.contains("not found") { return true }
            try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
    }
    return false
}

// MARK: - read-only lease probe (sqlite3 CLI, `immutable=1` URI: no locks, no writes; a plain
// `-readonly` open of the live DB intermittently fails with "unable to open database file")

/// `process_generation|lease_generation|expires_at|released_at`, or `""` when there is no row. An
/// `immutable=1` read can race a concurrent write (no locks) and fail; it is retried, and a read that
/// still fails returns `error: …` instead of a silent blank (run 1 recorded a blank `lease_before_kill`).
func leaseRow(_ db: String, _ roomId: String, attempts: Int = 8) -> String {
    guard MemberCheck.isSafe(roomId) else { return "?" }
    var last = ""
    for _ in 0..<attempts {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["file:\(db)?immutable=1",
                       "select process_generation||'|'||lease_generation||'|'||expires_at||'|'||ifnull(released_at,'') from hosted_room_driver_leases where room_id='\(roomId)';"]
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { last = "error: \(error)"; continue }
        p.waitUntilExit()
        let row = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus == 0 && msg.isEmpty && !row.isEmpty { return row }
        last = msg.isEmpty ? (p.terminationStatus == 0 ? "" : "error: exit \(p.terminationStatus)") : "error: \(msg)"
        usleep(100_000)
    }
    return last
}

enum MemberCheck { static func isSafe(_ s: String) -> Bool { RoomMember.isIdentifier(s) && !s.contains("'") } }

// MARK: - scenarios

func scenarioList() async throws {
    let b = try await attach()
    let api = GroupsAPI(client: b.client)
    let caps = try await api.capabilities()
    rec.summary["capabilities"] = ["driver": caps["driver"] ?? .null, "protocol_version": caps["protocol_version"] ?? .null,
                                   "methods": caps["methods"] ?? .null, "room_link_enabled": caps["room_link"]?["enabled"] ?? .null]
    say("groups.capabilities driver=\(caps["driver"] ?? .null) methods=\(caps["methods"]?.array?.count ?? 0)")
    let bots = try await Bot.list(b)
    var modes: [String: JSONValue] = [:]
    for bot in bots {
        let c = try await b.client.call("groups.capabilities", ["profile": .string(bot.name)])
        let policy = c["room_link"]?["catalog"]?["execution_policy"]
        modes[bot.name] = ["approval_mode": policy?["approval_mode"] ?? .null, "room_link": c["room_link"]?["enabled"] ?? .null,
                           "reason": c["room_link"]?["reason"] ?? .null]
        say("  profile \(bot.name): approval_mode=\(policy?["approval_mode"] ?? .null) room_link=\(c["room_link"]?["enabled"] ?? .null)")
    }
    rec.summary["execution_policy_by_profile"] = .object(modes)
    let rooms = try await api.allRooms()
    rec.summary["rooms_total"] = .number(Double(rooms.count))
    rec.summary["hba_rooms"] = .array(rooms.filter { $0.roomId.hasPrefix("hba-") }.map { .string($0.roomId) })
    say("groups.list → \(rooms.count) rooms, hba-*: \(rooms.filter { $0.roomId.hasPrefix("hba-") }.map(\.roomId))")
    b.shutdown()
}

func scenarioMulti(_ spec: String) async throws {
    let b = try await attach()
    let api = GroupsAPI(client: b.client)
    let roster = try members(spec, from: try await Bot.list(b))
    let roomId = "hba-m2-multi-\(stamp)"
    let room = try await api.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster)
    noteCreated(room)
    say("groups.create → \(room.roomId) members=\(room.members.map(\.handle)) idempotent=\(room.idempotent)")
    rec.step("create", ["room_id": .string(room.roomId), "members": .array(room.members.map { .string($0.memberId) })])
    let text = "Hello both. Each of you: reply with exactly ONE short sentence saying which model you are. Do not use any tools and do not mention anyone."
    let sent = try await api.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
    say("groups.send → seq=\(sent.seq) event_id=\(sent.eventId)")
    rec.step("send", ["seq": .number(Double(sent.seq)), "event_id": .string(sent.eventId)])
    let r: PollResult
    do { r = try await poll(api, roomId, label: "multi", timeout: 600, until: settledAndIdle) }
    catch { _ = await disband(api, roomId); b.shutdown(); throw error }
    let replies = r.timeline.events.filter { $0.kind == "message.member" && $0.discussionEventId == sent.eventId }
    let repliers = Set(replies.compactMap(\.memberId))
    rec.summary["events"] = eventsJSON(r.timeline)
    rec.summary["repliers"] = .array(repliers.sorted().map(JSONValue.string))
    rec.summary["phase"] = .string("\(r.timeline.phase(of: sent))")
    rec.summary["final_driver"] = ["working": .bool(r.state.driver?.working ?? true),
                                   "counts": .object((r.state.driver?.counts ?? [:]).mapValues { .number(Double($0)) })]
    say("settled: phase=\(r.timeline.phase(of: sent)) repliers=\(repliers.sorted()) working=\(r.state.driver?.working ?? true)")
    let ok = repliers.count >= 2 && r.state.driver?.working == false
    _ = await disband(api, roomId)
    b.shutdown()
    if !ok { throw Fail("expected replies from ≥2 members") }
}

func scenarioStop(_ spec: String) async throws {
    let b = try await attach()
    let api = GroupsAPI(client: b.client)
    let roster = try members(spec, from: try await Bot.list(b))
    let roomId = "hba-m2-stop-\(stamp)"
    noteCreated(try await api.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster))
    let target = roster[0]
    let text = "@\(target.handle) Write a detailed 1200-word essay about the history of lighthouses, in plain prose. Do not use any tools and do not mention or address any other member."
    let sent = try await api.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
    say("groups.send → seq=\(sent.seq)")
    rec.step("send", ["seq": .number(Double(sent.seq)), "event_id": .string(sent.eventId), "target": .string(target.memberId)])
    // Wait until a member task is running, then give it a few seconds of model time.
    let running: PollResult
    do { running = try await poll(api, roomId, label: "until-running", timeout: 120) { _, s in (s.driver?.counts["running"] ?? 0) >= 1 } }
    catch { _ = await disband(api, roomId); b.shutdown(); throw error }
    try await Task.sleep(nanoseconds: 4_000_000_000)
    let cancelId = "hba-stop-\(UUID().uuidString.lowercased())"
    let cancelled = try await api.stopRoom(roomId: roomId, cancelId: cancelId)
    say("groups.stop cancel_id=\(cancelId) → cancelled=\(cancelled)")
    rec.step("stop", ["cancel_id": .string(cancelId), "cancelled": .number(Double(cancelled))])
    let r: PollResult
    do {
        r = try await poll(api, roomId, from: running.timeline, label: "after-stop", timeout: 180) { t, s in
            t.events.contains { $0.kind == "turn.cancelled" && $0.discussionEventId == sent.eventId } && s.driver?.working == false
        }
    } catch { _ = await disband(api, roomId); b.shutdown(); throw error }
    let memberReplies = r.timeline.events.filter { $0.kind == "message.member" && $0.discussionEventId == sent.eventId }
    rec.summary["events"] = eventsJSON(r.timeline)
    rec.summary["cancelled_count"] = .number(Double(cancelled))
    rec.summary["member_replies_after_stop"] = .number(Double(memberReplies.count))
    rec.summary["phase"] = .string("\(r.timeline.phase(of: sent))")
    say("stopped: phase=\(r.timeline.phase(of: sent)) member replies=\(memberReplies.count) working=\(r.state.driver?.working ?? true)")
    // Idle check: no new turn is planned for the fenced message.
    try await Task.sleep(nanoseconds: 8_000_000_000)
    let (after, st) = try await RoomSync.refresh(api, roomId: roomId, timeline: r.timeline)
    rec.summary["after_8s"] = ["cursor": .number(Double(after.cursor)), "working": .bool(st.driver?.working ?? true),
                               "counts": .object((st.driver?.counts ?? [:]).mapValues { .number(Double($0)) })]
    say("8 s later: cursor \(r.timeline.cursor)→\(after.cursor) working=\(st.driver?.working ?? true) counts=\(st.driver?.counts ?? [:])")
    _ = await disband(api, roomId)
    b.shutdown()
    if cancelled < 1 || memberReplies.count != 0 || st.driver?.working != false { throw Fail("stop did not cancel the running turn") }
}

/// Waits for a retry action on `roomId`, then calls `groups.retry` through `api` and polls to settled.
func retryPhase(_ api: GroupsAPI, _ roomId: String, _ sent: RoomEvent, from timeline: RoomTimeline, timeout: TimeInterval) async throws -> PollResult {
    let deferred = try await poll(api, roomId, from: timeline, label: "until-retry-action", timeout: timeout, maxInterval: 2) { _, s in
        s.driver?.pendingActions.contains { if case .retry = $0 { return true }; return false } == true
    }
    guard case .retry(let taskId)? = deferred.state.driver?.pendingActions.first(where: { if case .retry = $0 { return true }; return false }) else {
        throw Fail("no retry action")
    }
    say("pending retry action task_id=\(taskId) counts=\(deferred.state.driver?.counts ?? [:]) blocked=\(deferred.state.driver?.blocked ?? false)")
    rec.step("retry_action", ["task_id": .string(taskId), "counts": .object((deferred.state.driver?.counts ?? [:]).mapValues { .number(Double($0)) })])
    let r: JSONValue
    do { r = try await api.retry(roomId: roomId, taskId: taskId) } catch {
        // 5118: `retry_indeterminate` first takes the room lease (`hosted_room_driver.py:243-251`); while
        // another live process generation holds and renews it, only that process can retry.
        let msg = Redaction.describe(error)
        rec.step("retry_refused", ["error": .string(msg)])
        throw Fail("groups.retry refused: \(msg)")
    }
    say("groups.retry → \(r)")
    rec.step("retry", r)
    return try await poll(api, roomId, from: deferred.timeline, label: "after-retry", timeout: 300) { t, s in
        t.events.contains { $0.kind == "turn.settled" && $0.payload["task_id"]?.string == taskId } && s.driver?.working == false
    }
}

func scenarioRetryAttach(_ spec: String) async throws {
    let e = try await attach()
    let eapi = GroupsAPI(client: e.client)
    let roster = try members(spec, from: try await Bot.list(e))
    // Own same-home serve, PRIVATE lock dir (never touches the user's rendezvous), --isolated.
    let lockDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes-bot-app-spike/m2-retry-locks-\(stamp)")
    var cfg = ServeProcess.Configuration.sameHomeDefault(lockDir: lockDir)
    cfg.logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HermesBotApp/serve-m2-retry.log")
    let s = ServeProcess(configuration: cfg)
    let port = try await s.start()
    say("own serve S pid=\(s.pid) port=\(port) (HERMES_HOME=~/.hermes, lock dir private)")
    rec.step("spawn_S", ["pid": .number(Double(s.pid)), "port": .number(Double(port))])
    let sc = try await connect(s, label: "S")
    let sapi = GroupsAPI(client: sc)
    let roomId = "hba-m2-retry-\(stamp)"
    // Create + send through S: S's worker wakes immediately and takes the room lease; the attached
    // backend and the messaging gateway only notice the room on their 5 s idle poll.
    noteCreated(try await sapi.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster))
    let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/shared-state.db").path
    let target = roster[0]
    let text = "@\(target.handle) Write a detailed 1200-word essay about the history of tide clocks, in plain prose. Do not use any tools and do not mention or address any other member."
    let sent = try await sapi.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
    rec.step("send_via_S", ["seq": .number(Double(sent.seq)), "event_id": .string(sent.eventId)])
    let running = try await poll(sapi, roomId, label: "S-until-running", timeout: 120) { _, st in (st.driver?.counts["running"] ?? 0) >= 1 }
    let leaseBefore = leaseRow(db, roomId)
    say("running on S; lease row (process_generation|lease_generation|expires_at|released_at) = \(leaseBefore)")
    rec.step("lease_before_kill", .string(leaseBefore))
    try await Task.sleep(nanoseconds: 3_000_000_000)
    // Simulated crash of the process that runs the turn.
    kill(s.pid, SIGKILL)
    sc.close()
    say("SIGKILL S pid=\(s.pid)")
    rec.step("sigkill_S", ["pid": .number(Double(s.pid))])
    // When the lease expires, wake the attached backend's worker with an idempotent groups.create of
    // the same room (no state change) so it — not the 5 s-polling messaging gateway — takes the lease.
    let parts = leaseBefore.split(separator: "|")
    let expires = parts.count >= 3 ? Double(parts[2]) ?? 0 : 0
    let gen0 = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    while Date().timeIntervalSince1970 < expires { try await Task.sleep(nanoseconds: 250_000_000) }
    var leaseAfter = leaseBefore
    for _ in 0..<120 {
        _ = try? await eapi.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster)
        leaseAfter = leaseRow(db, roomId)
        let g = leaseAfter.split(separator: "|").dropFirst().first.flatMap { Int($0) } ?? gen0
        if g > gen0 { break }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    say("lease after takeover = \(leaseAfter)")
    rec.step("lease_after_takeover", .string(leaseAfter))
    // Takeover = a NEW process_generation with a higher lease_generation; requires a readable before-row.
    let before = leaseBefore.split(separator: "|", omittingEmptySubsequences: false)
    let after = leaseAfter.split(separator: "|", omittingEmptySubsequences: false)
    let takeover = before.count >= 2 && after.count >= 2 && before[0] != after[0] && (Int(after[1]) ?? 0) > (Int(before[1]) ?? 0)
    rec.summary["lease_takeover_proven"] = .bool(takeover)
    say("lease takeover proven=\(takeover) (S generation \(before.first ?? "?") → \(after.first ?? "?"))")
    rec.summary["S_alive_after_kill"] = .bool(kill(s.pid, 0) == 0)
    let r: PollResult
    do {
        r = try await retryPhase(eapi, roomId, sent, from: running.timeline, timeout: 240)
    } catch {
        // Never leave the room behind (run 306 did: the failure skipped the disband).
        rec.step("lease_at_failure", .string(leaseRow(db, roomId)))
        _ = await disband(eapi, roomId)
        try? FileManager.default.removeItem(at: lockDir)
        e.shutdown()
        throw error
    }
    rec.summary["events"] = eventsJSON(r.timeline)
    let kinds = r.timeline.events.map(\.kind)
    rec.summary["kinds"] = .array(kinds.map(JSONValue.string))
    say("retried and settled: kinds=\(kinds)")
    _ = await disband(eapi, roomId)
    try? FileManager.default.removeItem(at: lockDir)
    e.shutdown()
    if !kinds.contains("message.member") { throw Fail("retry flow incomplete") }
    if !takeover { throw Fail("retry settled, but the lease takeover was not proven (see lease_before_kill / lease_after_takeover)") }
}

/// Isolated home for flows the user's install cannot produce (approvals are off in every profile).
func isoConfig() throws -> ServeProcess.Configuration {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes-bot-app-spike/m2")
    var c = ServeProcess.Configuration.spikeDefault()
    c.hermesHome = base.appendingPathComponent("home")
    c.lockDir = base.appendingPathComponent("locks")
    c.logFile = base.appendingPathComponent("serve.log")
    guard FileManager.default.fileExists(atPath: c.hermesHome.appendingPathComponent("config.yaml").path) else {
        throw Fail("isolated home missing: \(c.hermesHome.path) (see evidence/m2/README)")
    }
    return c
}

/// Disbands leftover hba rooms of earlier runs in the ISOLATED home only.
func isoSweep(_ api: GroupsAPI) async {
    for r in (try? await api.allRooms()) ?? [] where r.roomId.hasPrefix("hba-") {
        say("iso sweep: disbanding leftover \(r.roomId)")
        _ = await disband(api, r.roomId, attempts: 3, every: 5)
    }
}

func scenarioApproveIso() async throws {
    let s = ServeProcess(configuration: try isoConfig())
    let port = try await s.start()
    say("isolated serve pid=\(s.pid) port=\(port)")
    defer { s.stop() }
    let c = try await connect(s, label: "iso")
    let api = GroupsAPI(client: c)
    await isoSweep(api)
    let caps = try await c.call("groups.capabilities", ["profile": "default"])
    rec.summary["iso_approval_mode"] = caps["room_link"]?["catalog"]?["execution_policy"]?["approval_mode"] ?? .null
    let roster = [RoomMember(memberId: "alpha", profile: "default", handle: "alpha", displayName: "Alpha"),
                  RoomMember(memberId: "bravo", profile: "bravo", handle: "bravo", displayName: "Bravo")]
    let roomId = "hba-m2-approve-\(stamp)"
    noteIsoCreated(try await api.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster))
    let probe = "/tmp/hba-approve-probe-\(stamp)"
    try FileManager.default.createDirectory(atPath: probe, withIntermediateDirectories: true)
    let text = "@alpha This is an approval test. Call the terminal tool exactly once with this command: rm -rf \(probe) . After that single call, reply with the single word done. Run no other command and do not investigate anything."
    let sent = try await api.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
    rec.step("send", ["seq": .number(Double(sent.seq)), "probe_dir": .string(probe)])
    let waiting = try await poll(api, roomId, label: "until-approval", timeout: 180) { _, st in
        st.driver?.pendingActions.contains { if case .approval = $0 { return true }; return false } == true
    }
    guard case .approval(let a)? = waiting.state.driver?.pendingActions.first(where: { if case .approval = $0 { return true }; return false }) else {
        throw Fail("no approval action")
    }
    let existedBefore = FileManager.default.fileExists(atPath: probe)
    say("pending approval member=\(a.memberId) task=\(a.taskId) gen=\(a.executionGeneration) choices=\(a.choices) command=\(a.command ?? "?") probe_exists=\(existedBefore)")
    rec.step("approval_pending", ["member_id": .string(a.memberId), "task_id": .string(a.taskId),
                                  "execution_generation": .number(Double(a.executionGeneration)), "request_id": .string(a.requestId),
                                  "choices": .array(a.choices.map(JSONValue.string)), "command": a.command.map(JSONValue.string) ?? .null,
                                  "description": a.description.map(JSONValue.string) ?? .null,
                                  "working": .bool(waiting.state.driver?.working ?? false), "probe_exists": .bool(existedBefore)])
    let r = try await api.approve(roomId: roomId, approval: a, choice: "once")
    say("groups.approve once → \(r)")
    rec.step("approve", r)
    let done = try await poll(api, roomId, from: waiting.timeline, label: "after-approve", timeout: 480, until: settledAndIdle)
    let existsAfter = FileManager.default.fileExists(atPath: probe)
    rec.summary["events"] = eventsJSON(done.timeline)
    rec.summary["probe_exists_after"] = .bool(existsAfter)
    let reply = done.timeline.events.last { $0.kind == "message.member" }?.text ?? ""
    say("settled: reply=\(reply.prefix(80)) probe_exists_after=\(existsAfter) pending=\(done.state.driver?.pendingActions.map(\.id) ?? [])")
    // A second approval request id must now be rejected as no longer pending (stale approve).
    do { _ = try await api.approve(roomId: roomId, approval: a, choice: "once"); rec.step("stale_approve", "accepted?!") }
    catch { rec.step("stale_approve_rejected", .string(Redaction.describe(error))); say("stale approve → \(Redaction.describe(error))") }
    _ = await disband(api, roomId, attempts: 3, every: 5)
    if existedBefore == false || existsAfter { throw Fail("approval did not gate the command as expected") }
}

func scenarioRetryIso() async throws {
    let cfg = try isoConfig()
    let s1 = ServeProcess(configuration: cfg)
    let p1 = try await s1.start()
    say("isolated serve S1 pid=\(s1.pid) port=\(p1)")
    let c1 = try await connect(s1, label: "S1")
    let a1 = GroupsAPI(client: c1)
    await isoSweep(a1)
    let roster = [RoomMember(memberId: "alpha", profile: "default", handle: "alpha", displayName: "Alpha"),
                  RoomMember(memberId: "bravo", profile: "bravo", handle: "bravo", displayName: "Bravo")]
    let roomId = "hba-m2-retryiso-\(stamp)"
    noteIsoCreated(try await a1.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster))
    let text = "@alpha Write a detailed 1200-word essay about the history of tide clocks, in plain prose. Do not use any tools and do not mention or address any other member."
    let sent = try await a1.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
    let running = try await poll(a1, roomId, label: "S1-until-running", timeout: 120) { _, st in (st.driver?.counts["running"] ?? 0) >= 1 }
    try await Task.sleep(nanoseconds: 3_000_000_000)
    kill(s1.pid, SIGKILL); c1.close()
    say("SIGKILL S1 pid=\(s1.pid)")
    rec.step("sigkill_S1", ["pid": .number(Double(s1.pid))])
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let s2 = ServeProcess(configuration: cfg)
    let p2 = try await s2.start()
    defer { s2.stop() }
    say("isolated serve S2 pid=\(s2.pid) port=\(p2)")
    let c2 = try await connect(s2, label: "S2")
    let a2 = GroupsAPI(client: c2)
    let r = try await retryPhase(a2, roomId, sent, from: running.timeline, timeout: 240)
    rec.summary["events"] = eventsJSON(r.timeline)
    let kinds = r.timeline.events.map(\.kind)
    say("retried and settled: kinds=\(kinds)")
    _ = await disband(a2, roomId, attempts: 3, every: 5)
    if !kinds.contains("message.member") { throw Fail("retry flow incomplete") }
}

/// Keeps an isolated serve alive for `seconds` so the SwiftUI app can attach to it
/// (`HERMES_BOT_APP_LOCK_DIR=~/.hermes-bot-app-spike/m2/locks`). With `retry`, it first leaves a room
/// whose running turn was lost (S1 SIGKILLed mid-turn; S2 takes over → indeterminate + retry action)
/// and writes its id to `<evidence>/room_id`.
func scenarioServeIso(seconds: TimeInterval, prepareRetry: Bool) async throws {
    let cfg = try isoConfig()
    if prepareRetry {
        let s1 = ServeProcess(configuration: cfg)
        _ = try await s1.start()
        let c1 = try await connect(s1, label: "S1")
        let a1 = GroupsAPI(client: c1)
        await isoSweep(a1)
        let roster = [RoomMember(memberId: "alpha", profile: "default", handle: "alpha", displayName: "Alpha"),
                      RoomMember(memberId: "bravo", profile: "bravo", handle: "bravo", displayName: "Bravo")]
        let roomId = "hba-m2-uiretry-\(stamp)"
        noteIsoCreated(try await a1.createRoom(roomId: roomId, name: testRoomName(roomId), members: roster))
        let text = "@alpha Write a detailed 1200-word essay about the history of tide clocks, in plain prose. Do not use any tools and do not mention or address any other member."
        _ = try await a1.sendMessage(roomId: roomId, eventId: "hba-msg-\(UUID().uuidString.lowercased())", text: text, threadId: "main")
        _ = try await poll(a1, roomId, label: "S1-until-running", timeout: 120) { _, st in (st.driver?.counts["running"] ?? 0) >= 1 }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        kill(s1.pid, SIGKILL); c1.close()
        say("SIGKILL S1 pid=\(s1.pid); room \(roomId) left with a lost running turn")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try roomId.write(to: evidence.appendingPathComponent("room_id"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    let s = ServeProcess(configuration: cfg)
    let port = try await s.start()
    say("isolated serve pid=\(s.pid) port=\(port) up for \(Int(seconds))s (lock dir \(cfg.lockDir?.path ?? "?"))")
    rec.step("serve_iso", ["pid": .number(Double(s.pid)), "port": .number(Double(port))])
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    try "ready\n".write(to: evidence.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !FileManager.default.fileExists(atPath: evidence.appendingPathComponent("stop").path) {
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    s.stop()
    say("isolated serve stopped")
}

// MARK: - cleanup of this card's test rooms and their hidden member sessions

/// Room ids from `a,b,c` or `@file` (one per line); only `hba-` ids that pass the identifier rule.
func roomIds(_ spec: String) throws -> [String] {
    let raw: [String]
    if spec.hasPrefix("@") {
        raw = try String(contentsOfFile: String(spec.dropFirst()), encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    } else {
        raw = spec.split(separator: ",").map(String.init)
    }
    var seen = Set<String>()
    return raw.map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("hba-") && MemberCheck.isSafe($0) && seen.insert($0).inserted }
}

/// The cleanup adapter is `HermesGatewayKit.AttachedSessionGateway` (unit-tested at its real WS/REST
/// boundary): `session.list` only discovers candidates; a close needs the exact-id REST inventory.
func sessionGateway(_ b: Backend) -> AttachedSessionGateway {
    if b.sessionREST == nil { say("cleanup: no REST access → close candidates stay unresolved") }
    return AttachedSessionGateway(client: b.client, rest: b.sessionREST)
}

/// Which rooms to clean and what is known about them. `spec`: `@<manifest>.jsonl` (entries written by
/// `noteCreated` / the app's `HERMES_BOT_APP_ROOM_MANIFEST`), or ids (`a,b` / `@ids.txt`) looked up in
/// the default manifest. An id with no manifest entry that is still live gets one from `groups.list`;
/// one that is neither is returned in `missing` (its sessions cannot be attributed → cleanup fails).
func cleanupTargets(_ spec: String, rooms live: [RoomSummary]) throws -> (entries: [RoomManifestEntry], missing: [String]) {
    if spec.hasPrefix("@"), spec.hasSuffix(".jsonl") {
        let entries = try RoomManifest.load(URL(fileURLWithPath: String(spec.dropFirst())))
            .filter { $0.roomId.hasPrefix("hba-") && MemberCheck.isSafe($0.roomId) }
        return (entries, [])
    }
    let ids = try roomIds(spec)
    let known = (try? RoomManifest.load(roomManifestFile)) ?? []
    var entries: [RoomManifestEntry] = [], missing: [String] = []
    for id in ids {
        if let e = known.first(where: { $0.roomId == id }) { entries.append(e) }
        else if let r = live.first(where: { $0.roomId == id }) { entries.append(RoomManifestEntry(room: r)) }
        else { missing.append(id) }
    }
    return (entries, missing)
}

/// Cleaner budget from the environment. Settling needs `settleRounds` consecutive empty passes; it is
/// derived from `HBA_CLEANUP_QUIET` (default 90 s): the window in which a late writer may still re-create a
/// deleted key. The title upgrade of a member's first turn runs in a daemon thread that `session.close`
/// does not join (`session_lifecycle.py:568-584`); its LLM call is bounded by
/// `auxiliary.title_generation.timeout` (default 30 s, `hermes_cli/config_defaults.py:774-785`,
/// `agent/auxiliary_client.py:6250,6353-6361`) without same-provider retry on timeout
/// (`auxiliary_client.py:3548-3550`, but a fallback provider may follow), then the usage write re-inserts
/// the row (`hermes_state_usage.py:388-391`). 90 s = three such windows. Anything later is caught by
/// `audit` / `ledger-audit` (exact readback of the ledger) and removed by `ledger-cleanup`.
func cleanerBudget() -> (rounds: Int, every: Double, settle: Int, quiet: Double) {
    let env = ProcessInfo.processInfo.environment
    let every = max(0, Double(env["HBA_RETRY_EVERY"] ?? "") ?? 10)
    let quiet = max(0, Double(env["HBA_CLEANUP_QUIET"] ?? "") ?? 90)
    let settle = max(2, every > 0 ? Int((quiet / every).rounded(.up)) + 1 : 2)
    let rounds = max(settle + 2, Int(env["HBA_CLEANUP_ROUNDS"] ?? "") ?? 36)
    return (rounds, every, settle, quiet)
}

/// Ledger keys of this backend's scope (optionally only for `rooms`). An unreadable ledger fails the run.
func ledgerKeys(rooms: Set<String>?) throws -> [SessionLedgerEntry] {
    SessionLedger.keys(try SessionLedger.load(sessionLedgerFile), scope: ledgerScope(), rooms: rooms)
}

func ledgerSummary(_ keys: [SessionLedgerEntry]) -> JSONValue {
    ["file": .string(sessionLedgerFile.path), "scope": .string(ledgerScope()), "keys": .array(keys.map(\.json))]
}

/// `cleanup <@manifest.jsonl | ids | @ids.txt>`: for exactly those hba rooms
///  1. `groups.disband` the live ones (stops their work; scheduled retry on 5114);
///  2. `RoomSessionCleaner` rounds (`HBA_CLEANUP_ROUNDS`, default 36 × `HBA_RETRY_EVERY` 10 s): re-discover
///     the member sessions by provenance (exact `Group: <id>` title, or the driver's opening line in the
///     stored preview / derived title, per profile + room created_at), record each owned key in the session
///     ledger BEFORE touching it, `session.close` owned runtimes only when `idle` and their key is proven by
///     an exact-id lookup (`GET /api/sessions/{id}?profile=`) to be stored in the owning profile and no other
///     `profiles.list` profile (listing absence proves nothing), `session.delete` owned rows no runtime holds
///     (4023 → next round), read back every ledger key of these rooms by exact id each round (re-created
///     `source=unknown` placeholders are deleted again), until `settle` consecutive empty passes
///     (`HBA_CLEANUP_QUIET`, default 90 s → 10 rounds);
///  3. re-read `groups.list`. Exit 0 only when no room is live, the cleaner settled empty, and every id
///     had a manifest entry. Rows that name a test room but cannot be proven (`unresolved`) are never
///     touched and fail the run.
func scenarioCleanup(_ spec: String) async throws {
    let b = try await attach()
    let api = GroupsAPI(client: b.client)
    let budget = cleanerBudget()

    let liveRooms = try await api.allRooms()
    let (entries, missing) = try cleanupTargets(spec, rooms: liveRooms)
    guard !entries.isEmpty || !missing.isEmpty else { throw Fail("no hba rooms given") }
    let ids = entries.map(\.roomId)
    let prior = try ledgerKeys(rooms: Set(ids + missing))
    rec.summary["room_ids"] = .array(ids.map(JSONValue.string))
    rec.summary["manifest"] = .array(entries.map(\.json))
    rec.summary["no_manifest"] = .array(missing.map(JSONValue.string))
    rec.summary["ledger_before"] = ledgerSummary(prior)
    rec.summary["budget"] = ["rounds": .number(Double(budget.rounds)), "every": .number(budget.every),
                             "settle_rounds": .number(Double(budget.settle)), "quiet_s": .number(budget.quiet)]

    // 1. rooms
    let liveIds = Set(liveRooms.map(\.roomId))
    var disbandFailed: [String] = []
    for id in ids + missing where liveIds.contains(id) {
        if !(await disband(api, id)) { disbandFailed.append(id) }
    }
    rec.summary["rooms_live_before"] = .array((ids + missing).filter(liveIds.contains).map(JSONValue.string))

    // 2. member sessions
    let others = Set(liveRooms.filter { r in !ids.contains(r.roomId) }.map(\.name))
    let cleaner = RoomSessionCleaner(manifest: entries, otherRoomNames: others, maxRounds: budget.rounds, every: budget.every,
                                     settleRounds: budget.settle, ledger: prior, scope: ledgerScope(),
                                     recorder: FileSessionLedger(url: sessionLedgerFile))
    say("cleanup: \(entries.count) room(s), profiles \(cleaner.profiles), \(prior.count) ledger key(s) known, up to \(budget.rounds) rounds every \(Int(budget.every)) s, settle \(budget.settle) empty rounds (quiet \(Int(budget.quiet)) s)")
    let report = await cleaner.run(sessionGateway(b), log: say)
    rec.summary["sessions"] = report.json

    // 3. read back rooms
    let roomsAfter = try await api.allRooms().map(\.roomId).filter { (ids + missing).contains($0) }
    rec.summary["after"] = ["rooms_live": .array(roomsAfter.map(JSONValue.string)), "disband_failed": .array(disbandFailed.map(JSONValue.string)),
                            "sessions_ok": .bool(report.ok), "sessions_reason": .string(report.reason),
                            "left": report.final.json]
    say("cleanup after: rooms live=\(roomsAfter.count) closed=\(report.closed.count) deleted=\(report.deleted.count) redeleted=\(report.redeleted.count) ledger keys=\(report.ledgerKeys.count) sessions: \(report.reason)")
    b.shutdown()
    var problems: [String] = []
    if !roomsAfter.isEmpty { problems.append("rooms still live: \(roomsAfter)") }
    if !report.ok { problems.append(report.reason) }
    if !missing.isEmpty { problems.append("no manifest entry (sessions not attributable): \(missing)") }
    if !problems.isEmpty { throw Fail("not clean: " + problems.joined(separator: "; ")) }
}

/// `audit <same spec as cleanup>`: read-only, one discovery pass + exact readback of the rooms' ledger
/// keys + live rooms. Fails when anything owned, unresolved or re-created is left (so it can gate "clean").
func scenarioAudit(_ spec: String) async throws {
    let b = try await attach()
    let api = GroupsAPI(client: b.client)
    let rooms = try await api.allRooms()
    let (entries, missing) = try cleanupTargets(spec, rooms: rooms)
    let ids = entries.map(\.roomId)
    let keys = try ledgerKeys(rooms: Set(ids + missing))
    let others = Set(rooms.filter { r in !ids.contains(r.roomId) }.map(\.name))
    let cleaner = RoomSessionCleaner(manifest: entries, otherRoomNames: others)
    let d = try await cleaner.discover(sessionGateway(b), ledger: keys)
    let allActive = try await b.client.call("session.active_list", [:])["sessions"]?.array ?? []
    let anyHba = allActive.filter { ($0["title"]?.string ?? "").contains("hba") }
    // Every profile (not only the manifest's members): bot_room rows that look like ANY hba test room.
    // Read-only and informational: it shows what is left install-wide, it does not decide ownership. Rows
    // re-created as `source=unknown` are NOT in this list; the ledger readback above is what covers them.
    let gw = sessionGateway(b)
    var hbaAny: [JSONValue] = []
    for bot in try await Bot.list(b) {
        for row in try await gw.storedRows(profile: bot.name) where row.source == RoomSessionClassifier.roomSource
            && (row.title.hasPrefix("Group: hba-") || row.title.hasPrefix("[Discussion: \"hba") || row.preview.hasPrefix("[Discussion: \"hba")) {
            hbaAny.append(["profile": .string(row.profile), "id": .string(row.id), "title": .string(row.title), "preview": .string(row.preview)])
        }
    }
    rec.summary["hba_bot_room_rows_any_profile"] = .array(hbaAny)
    rec.summary["room_ids"] = .array(ids.map(JSONValue.string))
    rec.summary["no_manifest"] = .array(missing.map(JSONValue.string))
    rec.summary["ledger"] = ledgerSummary(keys)
    rec.summary["rooms_live"] = .array(rooms.map(\.roomId).filter { (ids + missing).contains($0) }.map(JSONValue.string))
    rec.summary["hba_rooms_live_any"] = .array(rooms.map(\.roomId).filter { $0.hasPrefix("hba-") }.map(JSONValue.string))
    rec.summary["discovery"] = d.json
    rec.summary["active_sessions_total"] = .number(Double(allActive.count))
    rec.summary["active_titles_with_hba"] = .array(anyHba.map { ["runtime_id": $0["id"] ?? .null, "session_key": $0["session_key"] ?? .null,
                                                                  "title": $0["title"] ?? .null, "status": $0["status"] ?? .null] })
    let ledgerAbsent = d.ledgerReadback.values.filter { if case .absent = $0 { return true }; return false }.count
    say("audit: rooms live=\(rooms.map(\.roomId).filter { (ids + missing).contains($0) }) owned stored=\(d.ownedStored.count) owned live=\(d.ownedLive.count) unresolved=\(d.unresolved.count) ledger keys=\(keys.count) absent=\(ledgerAbsent) recreated=\(d.ledgerRecreated.count) foreign=\(d.foreign.count) active titles with 'hba'=\(anyHba.count) hba bot_room rows any profile=\(hbaAny.count) no_manifest=\(missing.count)")
    for (k, v) in d.ledgerReadback.sorted(by: { $0.key < $1.key }) { say("  ledger \(k): \(v)") }
    for u in d.unresolved { say("  unresolved \(u.kind) \(u.ref): \(u.detail)") }
    b.shutdown()
    if !d.isEmpty || !missing.isEmpty {
        throw Fail("audit: not clean (owned \(d.ownedStored.count)+\(d.ownedLive.count), unresolved \(d.unresolved.count), re-created \(d.ledgerRecreated.count), no_manifest \(missing.count))")
    }
}

/// `ledger-import <dir[,dir…]>`: no backend call. Each dir is an earlier cleanup's evidence dir
/// (`scenario.json` + `wire.log`). Every key that run deleted on the ATTACHED backend — a
/// `session.delete {session_id, profile}` request in `wire.log` answered with a `result` (not an error),
/// plus the report's own `deleted[]` lists — is appended to the ledger in this process's scope with
/// `origin` = the dir. `HBA_IMPORT_BACKEND=<substring>` (e.g. `role=desktop-serve pid=29903`) must match the
/// report's `backend`, so keys of an isolated serve are never imported into the user install's scope.
func scenarioLedgerImport(_ spec: String) throws {
    let dirs = spec.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !dirs.isEmpty else { throw Fail("no evidence dirs") }
    guard let want = ProcessInfo.processInfo.environment["HBA_IMPORT_BACKEND"], !want.isEmpty else {
        throw Fail("HBA_IMPORT_BACKEND=<backend substring> is required")
    }
    let scope = ledgerScope()
    var seen = Set(try ledgerKeys(rooms: nil).map(\.key))
    var added: [JSONValue] = [], skipped: [JSONValue] = [], refused: [JSONValue] = []
    for dir in dirs {
        let base = URL(fileURLWithPath: dir)
        let doc = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: base.appendingPathComponent("scenario.json")))
        let backend = doc["backend"]?.string ?? ""
        guard backend.hasPrefix("attached"), backend.contains(want) else {
            refused.append(["dir": .string(dir), "backend": .string(backend)]); say("ledger-import: skip \(dir) (backend '\(backend)')"); continue
        }
        // room ids from the report lists (wire.log carries only profile + id)
        var rooms: [String: String] = [:]
        var keys: [(String, String, String)] = []  // profile, id, evidence
        for item in (doc["sessions"]?["deleted"]?.array ?? []) + (doc["deleted"]?.array ?? []) where item["deleted"]?.bool != false {
            if let p = item["profile"]?.string, let id = item["id"]?.string {
                rooms["\(p):\(id)"] = item["room_id"]?.string ?? ""
                keys.append((p, id, item["evidence"]?.string ?? "report"))
            }
        }
        if let wire = try? String(contentsOf: base.appendingPathComponent("wire.log"), encoding: .utf8) {
            var pending: [Int: (String, String)] = [:]
            for line in wire.split(whereSeparator: \.isNewline) {
                guard let r = line.range(of: "[attached] ") else { continue }
                let out = line[..<r.lowerBound].contains(">>")
                guard let o = try? JSONDecoder().decode(JSONValue.self, from: Data(line[r.upperBound...].utf8)), let rid = o["id"]?.int else { continue }
                if out, o["method"]?.string == "session.delete", let id = o["params"]?["session_id"]?.string {
                    pending[rid] = ((o["params"]?["profile"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "default", id)
                } else if !out, let (p, id) = pending.removeValue(forKey: rid), o["result"] != nil {
                    keys.append((p, id, "wire_delete_ok"))
                }
            }
        }
        for (p, id, ev) in keys {
            let e = SessionLedgerEntry(event: "imported_deleted", scope: scope, profile: p, id: id, roomId: rooms["\(p):\(id)"] ?? "",
                                       evidence: ev, origin: dir)
            guard seen.insert(e.key).inserted else { skipped.append(["key": .string(e.key), "origin": .string(dir)]); continue }
            try SessionLedger.append(e, to: sessionLedgerFile)
            added.append(e.json)
            say("ledger-import: \(e.key) (\(e.roomId.isEmpty ? "room ?" : e.roomId)) from \(dir)")
        }
    }
    rec.summary["ledger_file"] = .string(sessionLedgerFile.path)
    rec.summary["scope"] = .string(scope)
    rec.summary["backend_match"] = .string(want)
    rec.summary["added"] = .array(added)
    rec.summary["already_known"] = .array(skipped)
    rec.summary["refused_dirs"] = .array(refused)
    say("ledger-import: \(added.count) added, \(skipped.count) already known, \(refused.count) dir(s) refused")
}

/// `ledger-audit`: read-only exact readback of every ledger key of this scope (no room manifest needed).
/// `ledger-cleanup`: the same plus the cleaner rounds: re-created placeholders deleted again, settle as in
/// `cleanup`. Both exit 1 unless every key is proven absent.
func scenarioLedger(cleanup: Bool) async throws {
    let b = try await attach()
    let keys = try ledgerKeys(rooms: nil)
    rec.summary["ledger_before"] = ledgerSummary(keys)
    guard !keys.isEmpty else { b.shutdown(); throw Fail("ledger has no keys for scope \(ledgerScope())") }
    let budget = cleanerBudget()
    let cleaner = RoomSessionCleaner(manifest: [], maxRounds: budget.rounds, every: budget.every, settleRounds: budget.settle,
                                     ledger: keys, scope: ledgerScope(), recorder: FileSessionLedger(url: sessionLedgerFile))
    let gw = sessionGateway(b)
    if cleanup {
        say("ledger-cleanup: \(keys.count) key(s), up to \(budget.rounds) rounds every \(Int(budget.every)) s, settle \(budget.settle)")
        let report = await cleaner.run(gw, log: say)
        rec.summary["sessions"] = report.json
        say("ledger-cleanup: redeleted=\(report.redeleted.count) \(report.reason)")
        for (k, v) in report.final.ledgerReadback.sorted(by: { $0.key < $1.key }) { say("  ledger \(k): \(v)") }
        b.shutdown()
        if !report.ok { throw Fail("ledger-cleanup: \(report.reason)") }
    } else {
        let d = try await cleaner.discover(gw)
        rec.summary["discovery"] = d.json
        let absent = d.ledgerReadback.values.filter { if case .absent = $0 { return true }; return false }.count
        say("ledger-audit: \(keys.count) key(s): absent=\(absent) recreated=\(d.ledgerRecreated.count) unresolved=\(d.unresolved.count)")
        for (k, v) in d.ledgerReadback.sorted(by: { $0.key < $1.key }) { say("  ledger \(k): \(v)") }
        for u in d.unresolved { say("  unresolved \(u.kind) \(u.ref): \(u.detail)") }
        b.shutdown()
        if !d.isEmpty || absent != keys.count { throw Fail("ledger-audit: not clean (\(keys.count - absent) of \(keys.count) key(s) not proven absent)") }
    }
}

/// `key-inventory <id[,id…]>`: read-only. For each id and every `profiles.list` profile: does the filtered
/// `session.list {include_hidden, limit 500}` show it, and what does the exact-id lookup say. Shows that
/// listing absence is not inventory absence (e.g. `kanban` rows) without touching any session.
func scenarioKeyInventory(_ spec: String) async throws {
    let b = try await attach()
    defer { b.shutdown() }
    let gw = sessionGateway(b)
    let ids = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !ids.isEmpty else { throw Fail("no ids") }
    let profiles = try await gw.profileNames()
    var listed: [String: Set<String>] = [:]
    for p in profiles { listed[p] = Set(try await gw.storedRows(profile: p).map(\.id)) }
    var out: [JSONValue] = []
    for id in ids {
        for p in profiles {
            let presence = await gw.storedIdPresence(profile: p, id: id)
            let inListing = listed[p]?.contains(id) ?? false
            say("key \(id) profile \(p): session.list=\(inListing ? "listed" : "not listed") exact=\(presence)")
            out.append(["id": .string(id), "profile": .string(p), "in_session_list": .bool(inListing), "exact": .string(presence.description)])
        }
    }
    rec.summary["profiles"] = .array(profiles.map(JSONValue.string))
    rec.summary["inventory"] = .array(out)
}

var ok = false
do {
    switch scenario {
    case "key-inventory": try await scenarioKeyInventory(args.count > 3 ? args[3] : "")
    case "ledger-import": try scenarioLedgerImport(args.count > 3 ? args[3] : "")
    case "ledger-audit": try await scenarioLedger(cleanup: false)
    case "ledger-cleanup": try await scenarioLedger(cleanup: true)
    case "list": try await scenarioList()
    case "multi": try await scenarioMulti(args.count > 3 ? args[3] : "translator,code-reviewer")
    case "stop": try await scenarioStop(args.count > 3 ? args[3] : "translator,code-reviewer")
    case "retry-attach": try await scenarioRetryAttach(args.count > 3 ? args[3] : "translator,code-reviewer")
    case "approve-iso": try await scenarioApproveIso()
    case "retry-iso": try await scenarioRetryIso()
    case "cleanup": try await scenarioCleanup(args.count > 3 ? args[3] : "")
    case "audit": try await scenarioAudit(args.count > 3 ? args[3] : "")
    case "serve-iso": try await scenarioServeIso(seconds: args.count > 3 ? Double(args[3]) ?? 600 : 600,
                                                 prepareRetry: args.count > 4 && args[4] == "retry")
    default: throw Fail("unknown scenario \(scenario)")
    }
    ok = true
} catch {
    let msg = (error as? Fail)?.description ?? Redaction.describe(error)
    say("FAILED: \(msg)")
    rec.summary["error"] = .string(msg)
}
rec.write(evidence, ok: ok)
say("evidence → \(evidence.path) ok=\(ok)")
exit(ok ? 0 : 1)
