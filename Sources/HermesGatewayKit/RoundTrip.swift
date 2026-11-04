import Foundation

/// The M0 proof, shared by the SwiftUI shell and the CLI harness:
/// own `hermes serve` → WS handshake → groups.capabilities → profiles.list → groups.create →
/// groups.send → poll groups.log/groups.state until one bot turn has a `message.member` reply and
/// a terminal `turn.*` event.
public final class RoundTrip: @unchecked Sendable {
    public struct Options: Sendable {
        public var serve = ServeProcess.Configuration.spikeDefault()
        public var evidenceDir: URL?
        public var memberA = GroupsAPI.Member(memberId: "alpha", profile: "default", handle: "alpha", displayName: "Alpha")
        public var memberB = GroupsAPI.Member(memberId: "bravo", profile: "bravo", handle: "bravo", displayName: "Bravo")
        public var prompt = "@alpha Reply with exactly one word: pong"
        public var turnTimeout: TimeInterval = 300
        public var keepServerRunning = false
        public init() {}
    }

    public enum Failure: Error, CustomStringConvertible {
        case step(String)
        public var description: String { if case .step(let s) = self { return s }; return "" }
    }

    public let options: Options
    private let say: @Sendable (String) -> Void
    private var transcript: [JSONValue] = []
    private var wire: [String] = []
    private var events: [JSONValue] = []
    private let lock = NSLock()
    public private(set) var serve: ServeProcess?

    public init(options: Options = Options(), log: @escaping @Sendable (String) -> Void) {
        self.options = options
        self.say = log
    }

    private func record(_ step: String, _ value: JSONValue) {
        lock.lock(); transcript.append(["step": .string(step), "value": value]); lock.unlock()
    }

    @discardableResult
    public func run() async throws -> JSONValue {
        let serve = ServeProcess(configuration: options.serve)
        self.serve = serve
        defer { if !options.keepServerRunning { serve.stop(); say("serve stopped (pid \(serve.pid))") } }

        say("starting hermes serve (HERMES_HOME=\(options.serve.hermesHome.path), port=\(options.serve.port))")
        let port = try await serve.start()
        say("READY port=\(port) pid=\(serve.pid)")
        record("serve", ["pid": .number(Double(serve.pid)), "port": .number(Double(port)),
                         "hermes_home": .string(options.serve.hermesHome.path),
                         "lock_dir": .string(options.serve.lockDir?.path ?? "<default>"),
                         "expected_rooms_db": .string(options.serve.hermesHome.appendingPathComponent("shared-state.db").path)])
        guard let url = serve.wsURL else { throw Failure.step("no ws url") }

        // Probe: offer the public subprotocol on loopback token auth and record what happens.
        let probe = GatewayClient(url: url, offeredProtocols: ["hermes-gateway-v1"])
        do {
            try await probe.connect(timeout: 15)
            say("subprotocol probe: connected, negotiated=\(probe.negotiatedProtocol ?? "<none>")")
            record("subprotocol_probe", ["offered": ["hermes-gateway-v1"], "connected": true,
                                         "negotiated": probe.negotiatedProtocol.map(JSONValue.string) ?? .null])
        } catch {
            say("subprotocol probe: failed: \(Redaction.describe(error))")
            record("subprotocol_probe", ["offered": ["hermes-gateway-v1"], "connected": false,
                                         "error": .string(Redaction.describe(error))])
        }
        probe.close()

        let client = GatewayClient(url: url)
        client.onWire = { [weak self] out, line in
            guard let self else { return }
            self.lock.lock(); self.wire.append((out ? "> " : "< ") + line); self.lock.unlock()
        }
        client.onEvent = { [weak self] type, payload, _ in
            guard let self else { return }
            self.lock.lock()
            self.events.append(["t": .number(Date().timeIntervalSince1970), "type": .string(type),
                                "payload_keys": .array((payload?.object?.keys.sorted() ?? []).map(JSONValue.string))])
            self.lock.unlock()
        }
        let ready = try await client.connect()
        say("ws connected (negotiated subprotocol=\(client.negotiatedProtocol ?? "<none>")), gateway.ready keys=\(ready.object?.keys.sorted() ?? [])")
        record("gateway.ready", ["negotiated_protocol": client.negotiatedProtocol.map(JSONValue.string) ?? .null,
                                 "payload_keys": .array((ready.object?.keys.sorted() ?? []).map(JSONValue.string)),
                                 "replay_epoch": ready["replay_epoch"] ?? .null])
        let api = GroupsAPI(client: client)

        // The room worker starts on a background thread after bind; wait for driver=true.
        var caps: JSONValue = .null
        for attempt in 1...60 {
            caps = try await api.capabilities()
            if caps["driver"]?.bool == true { say("groups.capabilities driver=true (attempt \(attempt))"); break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        record("groups.capabilities", caps)
        guard caps["driver"]?.bool == true else { throw Failure.step("room driver never became ready: \(caps)") }

        let profiles = try await api.profiles()
        let names = profiles["profiles"]?.array?.compactMap { $0["name"]?.string } ?? []
        say("profiles.list → \(names)")
        record("profiles.list", profiles)
        for m in [options.memberA, options.memberB] where !names.contains(m.profile) {
            throw Failure.step("profile \(m.profile) missing from profiles.list")
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let roomId = "m0-spike-\(stamp)"
        let members = [options.memberA, options.memberB]
        let created = try await api.create(roomId: roomId, name: "M0 spike \(stamp)", members: members)
        say("groups.create → room_id=\(created["room"]?["room_id"]?.string ?? "?") epoch=\(created["room"]?["authority_epoch"]?.int ?? -1)")
        record("groups.create", created)
        let again = try await api.create(roomId: roomId, name: "M0 spike \(stamp)", members: members)
        record("groups.create(repeat)", ["idempotent": again["room"]?["idempotent"] ?? .null])

        let clientEventId = "m0-msg-\(stamp)"
        let sent = try await api.send(roomId: roomId, eventId: clientEventId, text: options.prompt, threadId: "main")
        let userSeq = sent["event"]?["seq"]?.int ?? 0
        say("groups.send → seq=\(userSeq) event_id=\(sent["event"]?["event_id"]?.string ?? "?") accepted=\(sent["accepted"]?.bool ?? false)")
        record("groups.send", sent)
        let resent = try await api.send(roomId: roomId, eventId: clientEventId, text: options.prompt, threadId: "main")
        record("groups.send(repeat)", ["seq": resent["event"]?["seq"] ?? .null, "idempotent": resent["event"]?["idempotent"] ?? .null])

        // Poll the monotonic log; the room has no push channel (see contract §5).
        var cursor = 0
        var all: [JSONValue] = []
        var reply: JSONValue?
        var terminal: JSONValue?
        var states: [JSONValue] = []
        let deadline = Date().addingTimeInterval(options.turnTimeout)
        var lastState = ""
        while Date() < deadline {
            let page = try await api.log(roomId: roomId, sinceSeq: cursor)
            for e in page["events"]?.array ?? [] {
                all.append(e)
                let kind = e["kind"]?.string ?? "?"
                say("  log seq=\(e["seq"]?.int ?? -1) kind=\(kind) actor=\(e["actor"]?["kind"]?.string ?? "?"):\(e["actor"]?["id"]?.string ?? "?")")
                if kind == "message.member", reply == nil { reply = e }
                if kind.hasPrefix("turn."), kind != "turn.started" { terminal = e }
            }
            cursor = page["cursor"]?.int ?? cursor
            let st = try await api.state(roomId: roomId)
            let ds = st["driver_status"] ?? .null
            let sig = (ds["counts"]?.compactJSON() ?? "") + (ds["working"]?.description ?? "")
            if sig != lastState {
                lastState = sig
                states.append(["t": .number(Date().timeIntervalSince1970), "latest_seq": st["room"]?["latest_seq"] ?? .null,
                               "driver_status": ds])
                say("  state latest_seq=\(st["room"]?["latest_seq"]?.int ?? -1) working=\(ds["working"]?.bool ?? false) counts=\(ds["counts"]?.compactJSON() ?? "{}")")
            }
            if reply != nil, terminal != nil, ds["working"]?.bool == false, page["has_more"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        record("groups.log(all)", .array(all))
        record("groups.state(transitions)", .array(states))
        let finalState = try await api.state(roomId: roomId)
        record("groups.state(final)", finalState)
        let listed = try await api.list()
        record("groups.list", ["room_ids": .array((listed["rooms"]?.array ?? []).compactMap { $0["room_id"] }),
                               "next_offset": listed["next_offset"] ?? .null])

        record("error_probes", await probeErrors(api, roomId: roomId, latestSeq: finalState["room"]?["latest_seq"]?.int ?? 0))
        let (evs, w) = lock.withLock { (events, wire) }
        record("ws_events_seen", .array(evs))
        client.close()

        let summary: JSONValue = [
            "room_id": .string(roomId),
            "reply_text": reply?["payload"]?["text"] ?? .null,
            "reply_actor": reply?["actor"] ?? .null,
            "terminal_kind": terminal?["kind"] ?? .null,
            "final_latest_seq": finalState["room"]?["latest_seq"] ?? .null,
            "ok": .bool(reply != nil && terminal?["kind"]?.string == "turn.settled"),
        ]
        record("summary", summary)
        try writeEvidence(wire: w)
        guard reply != nil else { throw Failure.step("no message.member reply within \(Int(options.turnTimeout))s") }
        say("BOT REPLY: \(reply?["payload"]?["text"]?.string ?? "?")  (terminal=\(terminal?["kind"]?.string ?? "none"))")
        return summary
    }

    /// Non-fatal: records the error envelope (code/message/data) for malformed or invalid calls, plus
    /// one `groups.stop` on the settled room, so the contract doc cites observed codes, not guesses.
    private func probeErrors(_ api: GroupsAPI, roomId: String, latestSeq: Int) async -> JSONValue {
        let c = api.client
        let cases: [(String, String, JSONValue)] = [
            ("state_unknown_room", "groups.state", ["room_id": "m0-does-not-exist"]),
            ("send_missing_thread_id", "groups.send", ["room_id": .string(roomId), "event_id": "m0-bad-1",
                                                       "payload": ["text": "hi"]]),
            ("send_extra_payload_field", "groups.send", ["room_id": .string(roomId), "event_id": "m0-bad-2",
                                                         "payload": ["text": "hi", "thread_id": "main", "x": 1]]),
            ("create_one_member", "groups.create", ["room_id": "m0-bad-room", "name": "bad",
                                                    "members": [["member_id": "a", "profile": "default", "handle": "a"]]]),
            ("create_unknown_profile", "groups.create", ["room_id": "m0-bad-room2", "name": "bad",
                                                         "members": [["member_id": "a", "profile": "default", "handle": "a"],
                                                                     ["member_id": "z", "profile": "nope", "handle": "z"]]]),
            ("log_since_ahead", "groups.log", ["room_id": .string(roomId), "since_seq": .number(Double(latestSeq + 10))]),
            ("log_limit_too_big", "groups.log", ["room_id": .string(roomId), "since_seq": 0, "limit": 501]),
            ("stop_settled_room", "groups.stop", ["room_id": .string(roomId), "cancel_id": "m0-stop-1"]),
            ("retry_unknown_task", "groups.retry", ["room_id": .string(roomId), "task_id": "dtask:nope"]),
            ("approve_not_pending", "groups.approve", ["room_id": .string(roomId), "member_id": "alpha", "task_id": "dtask:nope",
                                                       "execution_generation": 1, "choice": "once", "request_id": "r1"]),
            ("unknown_method", "groups.nope", [:]),
        ]
        var out: [String: JSONValue] = [:]
        for (name, method, params) in cases {
            do {
                let r = try await c.call(method, params, timeout: 30)
                out[name] = ["method": .string(method), "ok": true, "result": r]
            } catch let e as GatewayClient.RPCError {
                out[name] = ["method": .string(method), "ok": false, "code": .number(Double(e.code)),
                             "message": .string(e.message), "data": e.data ?? .null]
            } catch {
                out[name] = ["method": .string(method), "ok": false, "transport_error": .string(Redaction.describe(error))]
            }
        }
        if let tail = try? await api.log(roomId: roomId, sinceSeq: latestSeq) { out["log_after_stop"] = tail }
        return .object(out)
    }

    private func writeEvidence(wire: [String]) throws {
        guard let dir = options.evidenceDir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock(); let t = transcript; lock.unlock()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(JSONValue.array(t)).write(to: dir.appendingPathComponent("roundtrip.json"))
        try (wire.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("wire.log"), atomically: true, encoding: .utf8)
        say("evidence written to \(dir.path)")
    }
}
