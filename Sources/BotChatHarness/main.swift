import Foundation
import HermesGatewayKit

// Headless M1 harness: Backend.connect (attach-first, spawn-if-absent) → profiles.list → one 1:1 chat
// (session.create → prompt.submit → message.start/delta…/complete) → session.close + session.delete →
// shutdown (stops the backend only if this process spawned it).
//
// usage: bot-chat-harness <evidence-dir> [profile] [prompt]
// env:   HERMES_BOT_APP_LOCK_DIR, HERMES_BOT_APP_FORCE_SPAWN=1, HERMES_BOT_APP_NO_SPAWN=1 (see Backend.Options)
// Exit 0 only when ≥2 message.delta frames arrived before message.complete status=complete.

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
@Sendable func say(_ s: String) {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("[\(fmt.string(from: Date()))] \(s)")
}

let args = CommandLine.arguments

// Cleanup mode: bot-chat-harness --delete <profile> <stored_session_id> (session.delete through the
// discovered backend; refuses nothing else).
if args.count == 4 && args[1] == "--delete" {
    do {
        let backend = try await Backend.connect(log: say)
        let r = try await backend.client.call("session.delete", ["session_id": .string(args[3]), "profile": .string(args[2])])
        say("session.delete \(args[2])/\(args[3]) → \(r)")
        backend.shutdown()
        exit(0)
    } catch {
        say("delete failed: \(Redaction.describe(error))"); exit(1)
    }
}
let stamp = Int(Date().timeIntervalSince1970)
let evidence = args.count > 1 ? URL(fileURLWithPath: args[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/m1-\(stamp)")
try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
let wantedProfile = args.count > 2 ? args[2] : nil
let prompt = args.count > 3 ? args[3] : "Count from 1 to 20 in words, one per line. Output only the list."

/// File names + POSIX modes only (never contents).
func lockDirListing(_ dir: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.sorted().map { n in
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.posixPermissions] as? Int) ?? 0
        return "\(n) \(String(mode, radix: 8))"
    }
}

enum HarnessFailure: RedactionSafeError {
    case step(String)
    var description: String { if case .step(let s) = self { return s }; return "" }
}

final class Box: @unchecked Sendable {
    let lock = NSLock()
    var wire: [String] = []
    var events: [JSONValue] = []
    func add(_ e: JSONValue) { lock.withLock { events.append(e) } }
    func addWire(_ s: String) { lock.withLock { wire.append(s) } }
}
let box = Box()
var summary: [String: JSONValue] = ["prompt": .string(prompt), "pid": .number(Double(getpid()))]
var code: Int32 = 1

do {
    let backend = try await Backend.connect(log: say)
    backend.client.onWire = { out, line in
        box.addWire("\(String(format: "%8.3f", Date().timeIntervalSince(t0))) \(out ? ">>" : "<<") \(line)")
    }
    summary["mode"] = .string(backend.mode.description)
    summary["attached"] = .bool(backend.mode.isAttached)
    summary["rendezvous_verdicts"] = .array(backend.verdicts.map { .string($0.description) })
    if case .attached(let a) = backend.mode {
        summary["backend"] = ["role": .string(a.role.rawValue), "pid": .number(Double(a.record.pid)),
                              "port": .number(Double(a.record.port ?? 0)), "identity": a.identity]
    }
    if case .spawned(let pid, let port) = backend.mode {
        summary["backend"] = ["pid": .number(Double(pid)), "port": .number(Double(port)), "isolated": true]
        let dir = Backend.Options.fromEnvironment().spawn.lockDir ?? HostRendezvous.lockDir()
        summary["lock_dir_while_running"] = .array(lockDirListing(dir).map(JSONValue.string))
        say("lock dir while spawned backend runs (\(dir.path)): \(lockDirListing(dir))")
        // The spawned serve must itself pass discovery (its record is what a CLI would attach to).
        let (again, v) = await HostRendezvous.discover(lockDir: dir)
        say("re-discovery against own spawn: \(v.map(\.description)) → \(again?.description ?? "none")")
        summary["rediscovery_own_spawn"] = .array(v.map { .string($0.description) })
    }

    let bots = try await Bot.list(backend)
    say("profiles.list → \(bots.count) bots: \(bots.map(\.name).joined(separator: ", "))")
    summary["bots"] = .array(bots.map { ["name": .string($0.name), "display_name": $0.displayName.map(JSONValue.string) ?? .null,
                                         "model": $0.model.map(JSONValue.string) ?? .null,
                                         "provider": $0.provider.map(JSONValue.string) ?? .null,
                                         "is_default": .bool($0.isDefault)] })
    guard let bot = bots.first(where: { $0.name == (wantedProfile ?? "") }) ?? bots.first(where: \.isDefault) ?? bots.first else {
        throw HarnessFailure.step("no bots")
    }
    let title = "hba-m1-\(stamp)"
    let chat = try await BotChatSession.open(backend, bot: bot, title: title)
    say("session.create profile=\(bot.name) → session_id=\(chat.sessionId) stored=\(chat.storedSessionId); session.title → \(chat.titleResult ?? .null)")
    summary["session"] = ["profile": .string(bot.name), "title": .string(title), "session_id": .string(chat.sessionId),
                          "stored_session_id": .string(chat.storedSessionId), "title_result": chat.titleResult ?? .null,
                          "info_model": chat.createInfo["model"] ?? .null, "info_provider": chat.createInfo["provider"] ?? .null]

    let done = AsyncStream<(String, String?, String?)>.makeStream()
    let streamed = Box()
    chat.onEvent { e in
        let t = Date().timeIntervalSince(t0)
        switch e {
        case .started: box.add(["t": .number(t), "type": "message.start"]); say("message.start")
        case .delta(let d):
            box.add(["t": .number(t), "type": "message.delta", "text": .string(d)])
            streamed.addWire(d)
        case .reasoning(let d): box.add(["t": .number(t), "type": "reasoning.delta", "chars": .number(Double(d.count))])
        case .interim(let s, _): box.add(["t": .number(t), "type": "message.interim", "text": .string(s)])
        case .status(let k, let s): box.add(["t": .number(t), "type": "status.update", "kind": .string(k), "text": .string(s)])
        case .completed(let c):
            box.add(["t": .number(t), "type": "message.complete", "status": c.status.map(JSONValue.string) ?? .null,
                     "error": c.error.map(JSONValue.string) ?? .null, "text": c.text.map(JSONValue.string) ?? .null,
                     "response_previewed": .bool(c.responsePreviewed), "response_reused": .bool(c.responseReused),
                     "response_transformed": .bool(c.responseTransformed)])
            say("message.complete status=\(c.status ?? "nil") transformed=\(c.responseTransformed)")
            done.continuation.yield((c.text ?? "", c.status, c.error)); done.continuation.finish()
        case .error(let m):
            box.add(["t": .number(t), "type": "error", "message": .string(m)]); say("error event: \(m)")
            done.continuation.yield(("", "error", m)); done.continuation.finish()
        case .disconnected(let m):
            box.add(["t": .number(t), "type": "client.disconnected", "message": .string(m)]); say("disconnected: \(m)")
            done.continuation.yield(("", "disconnected", m)); done.continuation.finish()
        case .other(let type): box.add(["t": .number(t), "type": .string(type)])
        }
    }
    let submit = try await chat.send(prompt)
    say("prompt.submit → \(submit)")
    summary["submit_result"] = submit

    var final: (String, String?, String?) = ("", "timeout", nil)
    let timeout = Task { try await Task.sleep(nanoseconds: 300_000_000_000); done.continuation.finish() }
    for await f in done.stream { final = f }
    timeout.cancel()

    let deltas = box.lock.withLock { box.events.filter { $0["type"]?.string == "message.delta" } }
    let joined = streamed.lock.withLock { streamed.wire.joined() }
    let times = deltas.compactMap { $0["t"]?.double }
    summary["delta_count"] = .number(Double(deltas.count))
    summary["first_delta_t"] = times.first.map(JSONValue.number) ?? .null
    summary["last_delta_t"] = times.last.map(JSONValue.number) ?? .null
    summary["streamed_text"] = .string(joined)
    summary["final_text"] = .string(final.0)
    summary["final_status"] = final.1.map(JSONValue.string) ?? .null
    say("deltas=\(deltas.count) span=\(String(format: "%.2f", (times.last ?? 0) - (times.first ?? 0)))s status=\(final.1 ?? "nil")")
    say("reply: \(final.0.replacingOccurrences(of: "\n", with: " | "))")

    let notes = await chat.close(deleteStored: true)
    notes.forEach { say($0) }
    summary["cleanup"] = .array(notes.map(JSONValue.string))
    backend.shutdown()
    if let owned = backend.owned {
        let alive = kill(owned.pid, 0) == 0
        say("owned backend stopped: pid \(owned.pid) running=\(owned.isRunning) kill0_alive=\(alive)")
        let dir = Backend.Options.fromEnvironment().spawn.lockDir ?? HostRendezvous.lockDir()
        summary["lock_dir_after_shutdown"] = .array(lockDirListing(dir).map(JSONValue.string))
        say("lock dir after shutdown: \(lockDirListing(dir))")
    }
    summary["owned_backend_running_after_shutdown"] = backend.owned.map { .bool($0.isRunning) } ?? .null
    code = (deltas.count >= 2 && final.1 == "complete") ? 0 : 2
} catch {
    let msg = Redaction.describe(error)
    say("FAILED: \(msg)")
    summary["error"] = .string(msg)
}

summary["ok"] = .bool(code == 0)
summary["events"] = .array(box.lock.withLock { box.events })
try? JSONValue.object(summary).compactJSON().write(to: evidence.appendingPathComponent("chat.json"), atomically: true, encoding: .utf8)
try? box.lock.withLock { box.wire }.joined(separator: "\n").write(to: evidence.appendingPathComponent("wire.log"), atomically: true, encoding: .utf8)
say("evidence → \(evidence.path) exit=\(code)")
exit(code)
