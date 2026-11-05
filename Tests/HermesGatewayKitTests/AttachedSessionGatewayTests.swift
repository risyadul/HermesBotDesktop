import Foundation
import Network
import XCTest
@testable import HermesGatewayKit

/// Profile attribution at the ACTUAL adapter boundary: `RoomSessionCleaner` driving the real
/// `AttachedSessionGateway` against an in-process fake backend (WS `/api/ws` JSON-RPC + HTTP
/// `GET /api/sessions/{id}?profile=`) on 127.0.0.1 — never the user's backend.
///
/// The fake models the backend's two read paths separately: `session.list` returns only the LISTED rows
/// (it drops `kanban`/`tool`/`oneshot`, archived and out-of-window rows, `methods_session.py:133-157,549-571`),
/// while the detail route reads the whole store by exact id (`web_routers/sessions.py:562-582`).
final class AttachedSessionGatewayTests: XCTestCase {
    static let translator = RoomMember(memberId: "translator", profile: "translator", handle: "translator")
    static let reviewer = RoomMember(memberId: "code-reviewer", profile: "code-reviewer", handle: "code-reviewer")
    static let probe = RoomManifestEntry(roomId: "hba-cleanup-probe", name: "hba cleanup probe", createdAt: 1_000,
                                         members: [translator, reviewer])
    private let secret = "hbaRestSecret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    // MARK: - the reviewer's repro and its variants

    /// Own `translator:same-key` bot_room row (listed, exact Group title) + a foreign `code-reviewer:same-key` row
    /// that `session.list` never shows (denied source / archived / outside the window) + ONE idle runtime on
    /// `same-key` whose live title is blank or agrees with the own row. Before the fix: closed the runtime,
    /// deleted the own row, ok:true. Now: 0 close, 0 delete, unresolved key_collision, not ok.
    func testUnlistedForeignSameKeyRowBlocksCloseAndDelete() async throws {
        let foreignVariants: [(String, String)] = [("kanban", "denied source kanban"), ("tool", "denied source tool"),
                                                   ("oneshot", "denied source oneshot"), ("tui", "archived / outside the listing window")]
        for (source, why) in foreignVariants {
            for liveTitle in ["", "Group: hba-cleanup-probe"] {
                let label = "\(why), live title '\(liveTitle)'"
                let be = try await FakeBackend.start(token: secret)
                defer { be.stop() }
                be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "same-key", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
                be.state.listed["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "cr-visible", title: "Plan", source: "desktop", startedAt: 900)]
                be.state.unlisted["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "same-key", title: "", source: source, startedAt: 1_010)]
                be.state.live = [LiveSessionRow(runtimeId: "foreign-runtime", sessionKey: "same-key", title: liveTitle, status: "idle")]

                let gw = AttachedSessionGateway(client: be.client, rest: be.rest)
                // Precondition: the listing really hides the foreign row (this is what made the old code wrong).
                let crListed = try await gw.storedRows(profile: "code-reviewer").map(\.id)
                XCTAssertFalse(crListed.contains("same-key"), label)

                let report = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 2, every: 0).run(gw)
                XCTAssertFalse(report.ok, label)
                XCTAssertEqual(be.state.closeCalls, [], label)
                XCTAssertEqual(be.state.deleteCalls, [], label)
                XCTAssertEqual(report.final.unresolved.map(\.kind), ["key_collision"], label)
                XCTAssertEqual(report.final.unresolved.first?.ref, "foreign-runtime", label)
                XCTAssertTrue(report.final.unresolved.first?.detail.contains("code-reviewer present(source=\(source))") == true,
                              "\(label): \(report.final.unresolved.first?.detail ?? "")")
                XCTAssertTrue(report.final.ownedLive.isEmpty, label)
                XCTAssertEqual(be.state.live.map(\.runtimeId), ["foreign-runtime"], label)
                XCTAssertEqual(be.state.unlisted["code-reviewer"]?.map(\.id), ["same-key"], label)
                XCTAssertEqual(be.state.listed["translator"]?.map(\.id), ["same-key"], label)
                // Every scanned profile was asked by exact id, with the header token and no token in the URL.
                XCTAssertEqual(Set(be.state.httpRequests.map(\.target)),
                               ["/api/sessions/same-key?profile=translator", "/api/sessions/same-key?profile=code-reviewer",
                                "/api/sessions/same-key?profile=default"], label)
                XCTAssertTrue(be.state.httpRequests.allSatisfy { $0.tokenOK && !$0.target.contains(secret) }, label)
                XCTAssertFalse(report.json.compactJSON().contains(secret), label)
            }
        }
    }

    /// Ordinary unique control: the key is stored only in the owning profile (404 elsewhere) → the idle
    /// runtime is closed, the row deleted after it, two empty rounds → ok.
    func testUniqueKeyIsClosedAndDeleted() async throws {
        let be = try await FakeBackend.start(token: secret)
        defer { be.stop() }
        be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k1", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        be.state.listed["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "other", title: "Plan", source: "desktop", startedAt: 900)]
        be.state.unlisted["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "k1-not-the-same", source: "kanban", startedAt: 1_010)]
        be.state.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "k1", title: "Group: hba-cleanup-probe", status: "idle")]
        let report = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 5, every: 0)
            .run(AttachedSessionGateway(client: be.client, rest: be.rest))
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(be.state.closeCalls, ["own-runtime"])
        XCTAssertEqual(be.state.deleteCalls, ["translator:k1"])
        XCTAssertEqual(be.state.unlisted["code-reviewer"]?.map(\.id), ["k1-not-the-same"])
        XCTAssertEqual(be.state.listed["code-reviewer"]?.map(\.id), ["other"])
        XCTAssertEqual(report.closed.count, 1)
    }

    /// The detail route resolves a unique PREFIX when the exact id is missing (`resolve_session_id`): a 200
    /// for a longer id proves the exact key absent there — it must not count as a holder (and not as present).
    func testPrefixResolvedOtherIdIsAbsentNotPresent() async throws {
        let be = try await FakeBackend.start(token: secret)
        defer { be.stop() }
        be.state.prefixResolve = true
        be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k2", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        be.state.unlisted["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "k2_longer", source: "kanban", startedAt: 1_010)]
        be.state.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "k2", title: "", status: "idle")]
        let gw = AttachedSessionGateway(client: be.client, rest: be.rest)
        let crAnswer = await gw.storedIdPresence(profile: "code-reviewer", id: "k2")
        XCTAssertEqual(crAnswer, .absent("prefix_resolved_other_id"))
        let report = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 5, every: 0).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(be.state.closeCalls, ["own-runtime"])
    }

    /// Fail closed whenever the exact inventory cannot be proven: no REST access, wrong token (401), a
    /// failing store (503), a profile the route does not know (404 with another detail), a 200 without an
    /// id, or a transport failure. Nothing is closed or deleted and the run is not ok.
    func testUnprovableInventoryNeverCloses() async throws {
        enum Fault: CaseIterable { case noRest, badToken, store503, profile404, emptyBody, deadPort }
        for fault in Fault.allCases {
            let be = try await FakeBackend.start(token: secret)
            defer { be.stop() }
            be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k3", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
            be.state.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "k3", title: "", status: "idle")]
            var rest: SessionRESTAccess? = be.rest
            switch fault {
            case .noRest: rest = nil
            case .badToken: rest = SessionRESTAccess(base: be.rest.base, token: "wrong-" + secret.prefix(4))
            case .store503: be.state.httpFault = ["code-reviewer": (503, ["detail": "Session store is corrupt"])]
            case .profile404: be.state.httpFault = ["default": (404, ["detail": "Profile 'default' does not exist."])]
            case .emptyBody: be.state.httpFault = ["code-reviewer": (200, [:])]
            case .deadPort: rest = SessionRESTAccess(base: URL(string: "http://127.0.0.1:\(try FakeGateway.closedPort())")!, token: secret)
            }
            let report = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 2, every: 0)
                .run(AttachedSessionGateway(client: be.client, rest: rest))
            XCTAssertFalse(report.ok, "\(fault)")
            XCTAssertEqual(be.state.closeCalls, [], "\(fault)")
            XCTAssertEqual(be.state.deleteCalls, [], "\(fault)")
            XCTAssertEqual(report.final.unresolved.map(\.kind), ["key_inventory_unknown"], "\(fault)")
            XCTAssertFalse(report.json.compactJSON().contains(secret), "\(fault) leaks the token")
        }
    }

    /// The owning row vanished between the listing and the exact lookup → not closed this round.
    func testOwnRowGoneOnExactLookupIsUnresolved() async throws {
        let be = try await FakeBackend.start(token: secret)
        defer { be.stop() }
        be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k4", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        be.state.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "k4", title: "", status: "idle")]
        be.state.httpFault = ["translator": (404, ["detail": "Session not found"])]
        let d = try await RoomSessionCleaner(manifest: [Self.probe]).discover(AttachedSessionGateway(client: be.client, rest: be.rest))
        XCTAssertTrue(d.ownedLive.isEmpty)
        XCTAssertEqual(d.unresolved.map(\.kind), ["key_inventory_changed"])
        XCTAssertEqual(d.keyInventory["k4"]?["translator"], .absent("not_found"))
    }

    // MARK: - deleted keys re-created by late title accounting

    /// Actual adapter: own bot_room row + idle runtime → close + delete; the backend re-creates the SAME id
    /// right after the delete as `source=unknown`, llm title, 0 messages (listed, but not bot_room). The
    /// exact readback (detail route) finds it, it is deleted again, and only then ok; the ledger file holds
    /// proven → deleted → redeleted. A later audit from that file reads it back absent.
    func testRecreatedSameKeyAfterDeleteIsReadBackAndRedeleted() async throws {
        let be = try await FakeBackend.start(token: secret)
        defer { be.stop() }
        be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k5", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        be.state.listed["code-reviewer"] = [StoredSessionRow(profile: "code-reviewer", id: "unrelated-unknown", title: "Aux only", source: "unknown", startedAt: 1_015)]
        be.state.live = [LiveSessionRow(runtimeId: "own-runtime", sessionKey: "k5", title: "Group: hba-cleanup-probe", status: "idle")]
        be.state.recreateOnDelete = ["translator:k5": StoredSessionRow(profile: "translator", id: "k5", title: "History of tide clocks essay", source: "unknown", startedAt: 1_020)]
        be.state.messageCounts = ["translator:k5": 0]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hba-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let gw = AttachedSessionGateway(client: be.client, rest: be.rest)
        let report = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 6, every: 0, scope: "fake", recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(report.ok, report.reason)
        XCTAssertEqual(be.state.closeCalls, ["own-runtime"])
        XCTAssertEqual(be.state.deleteCalls, ["translator:k5", "translator:k5"])
        XCTAssertEqual(report.redeleted.count, 1)
        XCTAssertFalse(be.state.listed["translator"]?.contains { $0.id == "k5" } ?? false)
        XCTAssertEqual(be.state.listed["code-reviewer"]?.map(\.id), ["unrelated-unknown"], "an unrelated unknown row is never touched")
        XCTAssertTrue(be.state.httpRequests.contains { $0.target == "/api/sessions/k5?profile=translator" })
        XCTAssertEqual(try SessionLedger.load(url).map(\.event), ["proven", "deleted", "redeleted"])
        XCTAssertFalse(report.json.compactJSON().contains(secret))
        let keys = SessionLedger.keys(try SessionLedger.load(url), scope: "fake")
        let audit = try await RoomSessionCleaner(manifest: [Self.probe], ledger: keys).discover(gw)
        XCTAssertTrue(audit.isEmpty)
        XCTAssertEqual(audit.ledgerReadback["translator:k5"], .absent("not_found"))
    }

    /// Same boundary, the re-creation lands only after the run settled (beyond its budget): an audit from
    /// the ledger file fails (the listing-only audit would pass), a new run from the ledger alone fixes it.
    func testRecreationAfterTheRunFailsAuditUntilLedgerCleanup() async throws {
        let be = try await FakeBackend.start(token: secret)
        defer { be.stop() }
        be.state.listed["translator"] = [StoredSessionRow(profile: "translator", id: "k6", title: "Group: hba-cleanup-probe", startedAt: 1_010)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hba-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let gw = AttachedSessionGateway(client: be.client, rest: be.rest)
        let r1 = await RoomSessionCleaner(manifest: [Self.probe], maxRounds: 4, every: 0, scope: "fake", recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(r1.ok, r1.reason)
        be.state.listed["translator", default: []].append(StoredSessionRow(profile: "translator", id: "k6", title: "Essay", source: "unknown", startedAt: 1_030))
        be.state.messageCounts = ["translator:k6": 0]
        let blind = try await RoomSessionCleaner(manifest: [Self.probe]).discover(gw)
        XCTAssertTrue(blind.isEmpty, "listing-only audit is blind")
        let keys = SessionLedger.keys(try SessionLedger.load(url), scope: "fake")
        let audit = try await RoomSessionCleaner(manifest: [Self.probe], ledger: keys).discover(gw)
        XCTAssertEqual(audit.ledgerRecreated.map(\.entry.key), ["translator:k6"])
        XCTAssertEqual(audit.ledgerRecreated.first?.presence, .present(source: "unknown", messages: 0))
        be.state.messageCounts = ["translator:k6": 2]
        let withMessages = try await RoomSessionCleaner(manifest: [Self.probe], ledger: keys).discover(gw)
        XCTAssertEqual(withMessages.unresolved.map(\.kind), ["ledger_key_present"], "not the placeholder shape → never deleted")
        be.state.messageCounts = [:]
        let noCount = try await RoomSessionCleaner(manifest: [Self.probe], ledger: keys).discover(gw)
        XCTAssertEqual(noCount.unresolved.map(\.kind), ["ledger_key_present"], "an unproven message count is not the placeholder shape")
        be.state.messageCounts = ["translator:k6": 0]
        let r2 = await RoomSessionCleaner(manifest: [], maxRounds: 4, every: 0, ledger: keys, scope: "fake", recorder: FileSessionLedger(url: url)).run(gw)
        XCTAssertTrue(r2.ok, r2.reason)
        XCTAssertEqual(be.state.deleteCalls, ["translator:k6", "translator:k6"])
        let after = try await RoomSessionCleaner(manifest: [Self.probe], ledger: keys).discover(gw)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - response mapping

    func testPresenceMapping() {
        typealias G = AttachedSessionGateway
        XCTAssertEqual(G.presence(status: 200, body: ["id": "a", "source": "kanban", "profile": "p"], requestedId: "a", profile: "p"), .present(source: "kanban"))
        XCTAssertEqual(G.presence(status: 200, body: ["id": "a", "source": "unknown", "profile": "p", "message_count": 0], requestedId: "a", profile: "p"),
                       .present(source: "unknown", messages: 0))
        XCTAssertEqual(G.presence(status: 200, body: ["id": "ab", "source": "tui", "profile": "p"], requestedId: "a", profile: "p"), .absent("prefix_resolved_other_id"))
        XCTAssertTrue(G.presence(status: 200, body: ["id": "a", "profile": "q"], requestedId: "a", profile: "p").isUnknown)
        XCTAssertTrue(G.presence(status: 200, body: ["x": 1], requestedId: "a", profile: "p").isUnknown)
        XCTAssertTrue(G.presence(status: 200, body: nil, requestedId: "a", profile: "p").isUnknown)
        XCTAssertEqual(G.presence(status: 404, body: ["detail": "Session not found"], requestedId: "a", profile: "p"), .absent("not_found"))
        XCTAssertTrue(G.presence(status: 404, body: ["detail": "Profile 'p' does not exist."], requestedId: "a", profile: "p").isUnknown)
        XCTAssertTrue(G.presence(status: 404, body: nil, requestedId: "a", profile: "p").isUnknown)
        for code in [400, 401, 403, 500, 503] { XCTAssertTrue(G.presence(status: code, body: nil, requestedId: "a", profile: "p").isUnknown) }
    }
}

// MARK: - fake backend (WS JSON-RPC + HTTP detail route)

final class FakeBackendState: @unchecked Sendable {
    struct HTTPRequest { let target: String; let tokenOK: Bool }
    private let lock = NSLock()
    private var _listed: [String: [StoredSessionRow]] = [:]
    private var _unlisted: [String: [StoredSessionRow]] = [:]
    private var _live: [LiveSessionRow] = []
    private var _closeCalls: [String] = []
    private var _deleteCalls: [String] = []
    private var _httpRequests: [HTTPRequest] = []
    private var _httpFault: [String: (Int, JSONValue)] = [:]
    private var _prefixResolve = false
    private var _recreateOnDelete: [String: StoredSessionRow] = [:]
    private var _messageCounts: [String: Int] = [:]
    let profiles = ["default", "translator", "code-reviewer"]

    var listed: [String: [StoredSessionRow]] { get { lock.withLock { _listed } } set { lock.withLock { _listed = newValue } } }
    var unlisted: [String: [StoredSessionRow]] { get { lock.withLock { _unlisted } } set { lock.withLock { _unlisted = newValue } } }
    var live: [LiveSessionRow] { get { lock.withLock { _live } } set { lock.withLock { _live = newValue } } }
    var httpFault: [String: (Int, JSONValue)] { get { lock.withLock { _httpFault } } set { lock.withLock { _httpFault = newValue } } }
    var prefixResolve: Bool { get { lock.withLock { _prefixResolve } } set { lock.withLock { _prefixResolve = newValue } } }
    /// `"profile:id"` → row put back into that profile's LISTED store right after a successful delete of
    /// that id (once): the late title-accounting writer (`hermes_state_usage.py:388-391`).
    var recreateOnDelete: [String: StoredSessionRow] { get { lock.withLock { _recreateOnDelete } } set { lock.withLock { _recreateOnDelete = newValue } } }
    /// `"profile:id"` → `message_count` of the detail route (omitted when not set: unknown count).
    var messageCounts: [String: Int] { get { lock.withLock { _messageCounts } } set { lock.withLock { _messageCounts = newValue } } }
    var closeCalls: [String] { lock.withLock { _closeCalls } }
    var deleteCalls: [String] { lock.withLock { _deleteCalls } }
    var httpRequests: [HTTPRequest] { lock.withLock { _httpRequests } }

    static func row(_ r: StoredSessionRow) -> JSONValue {
        ["id": .string(r.id), "title": .string(r.title), "preview": .string(r.preview), "source": .string(r.source),
         "started_at": .number(r.startedAt)]
    }

    /// JSON-RPC methods the cleanup uses.
    func rpc(_ method: String, _ params: JSONValue) -> JSONValue? {
        lock.withLock {
            switch method {
            case "profiles.list":
                return ["profiles": .array(profiles.map { ["name": .string($0)] })]
            case "session.list":
                let p = params["profile"]?.string ?? "default"
                return ["sessions": .array((_listed[p] ?? []).map(Self.row))]
            case "session.active_list":
                return ["sessions": .array(_live.map { ["id": .string($0.runtimeId), "session_key": .string($0.sessionKey),
                                                        "title": .string($0.title), "status": .string($0.status)] })]
            case "session.close":
                let id = params["session_id"]?.string ?? ""
                _closeCalls.append(id)
                let had = _live.contains { $0.runtimeId == id }
                _live.removeAll { $0.runtimeId == id }
                return ["closed": .bool(had), "messages": []]
            case "session.delete":
                let id = params["session_id"]?.string ?? "", p = params["profile"]?.string ?? "default"
                _deleteCalls.append("\(p):\(id)")
                if _live.contains(where: { $0.sessionKey == id }) {
                    return ["__error": ["code": 4023, "message": "cannot delete an active session"]]
                }
                let before = (_listed[p]?.count ?? 0) + (_unlisted[p]?.count ?? 0)
                _listed[p]?.removeAll { $0.id == id }
                _unlisted[p]?.removeAll { $0.id == id }
                if before == (_listed[p]?.count ?? 0) + (_unlisted[p]?.count ?? 0) {
                    return ["__error": ["code": 4007, "message": "session not found"]]
                }
                if let again = _recreateOnDelete.removeValue(forKey: "\(p):\(id)") { _listed[p, default: []].append(again) }
                return ["deleted": .string(id)]
            default:
                return nil
            }
        }
    }

    /// `GET /api/sessions/{id}?profile=` over the WHOLE store (listed + unlisted), like `db.get_session`.
    func http(target: String, token: String?, expected: String) -> (Int, JSONValue) {
        lock.withLock {
            _httpRequests.append(.init(target: target, tokenOK: token == expected))
            guard token == expected else { return (401, ["detail": "Unauthorized"]) }
            guard let c = URLComponents(string: "http://x" + target), c.path.hasPrefix("/api/sessions/") else { return (404, ["detail": "Not Found"]) }
            let id = String(c.path.dropFirst("/api/sessions/".count)).removingPercentEncoding ?? ""
            let p = c.queryItems?.first { $0.name == "profile" }?.value ?? "default"
            if let f = _httpFault[p] { return f }
            let all = (_listed[p] ?? []) + (_unlisted[p] ?? [])
            if let r = all.first(where: { $0.id == id }) {
                var body: [String: JSONValue] = ["id": .string(r.id), "source": .string(r.source), "profile": .string(p), "title": .string(r.title)]
                if let n = _messageCounts["\(p):\(id)"] { body["message_count"] = .number(Double(n)) }
                return (200, .object(body))
            }
            if _prefixResolve {
                let m = all.filter { $0.id.hasPrefix(id) }
                if m.count == 1 { return (200, ["id": .string(m[0].id), "source": .string(m[0].source), "profile": .string(p)]) }
            }
            return (404, ["detail": "Session not found"])
        }
    }
}

final class FakeBackend: @unchecked Sendable {
    let state: FakeBackendState
    let ws: FakeGateway
    let httpServer: FakeHTTPServer
    let client: GatewayClient
    let rest: SessionRESTAccess

    private init(state: FakeBackendState, ws: FakeGateway, http: FakeHTTPServer, client: GatewayClient, rest: SessionRESTAccess) {
        self.state = state; self.ws = ws; self.httpServer = http; self.client = client; self.rest = rest
    }

    static func start(token: String) async throws -> FakeBackend {
        let ws = try await FakeGateway.start()
        let state = FakeBackendState()
        ws.responder = { [state] m, p in state.rpc(m, p) }
        let http = try await FakeHTTPServer.start { target, headers in
            state.http(target: target, token: headers["x-hermes-session-token"], expected: token)
        }
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = Int(ws.port); c.path = "/api/ws"
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        let client = GatewayClient(url: c.url!)
        _ = try await client.connect(timeout: 10)
        return FakeBackend(state: state, ws: ws, http: http, client: client,
                           rest: SessionRESTAccess(base: URL(string: "http://127.0.0.1:\(http.port)")!, token: token))
    }

    func stop() { client.close(); ws.stop(); httpServer.stop() }
}

/// One-request-per-connection HTTP/1.1 stand-in on 127.0.0.1.
final class FakeHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ target: String, _ headers: [String: String]) -> (Int, JSONValue)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-http")
    private let handler: Handler
    private(set) var port: UInt16 = 0
    private var resolved = false

    private init(listener: NWListener, handler: @escaping Handler) { self.listener = listener; self.handler = handler }

    static func start(_ handler: @escaping Handler) async throws -> FakeHTTPServer {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let s = FakeHTTPServer(listener: try NWListener(using: p), handler: handler)
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.port = try await withCheckedThrowingContinuation { cont in
            s.listener.stateUpdateHandler = { [weak s] st in
                guard let s, !s.resolved else { return }
                switch st {
                case .ready: s.resolved = true; cont.resume(returning: s.listener.port?.rawValue ?? 0)
                case .failed(let e): s.resolved = true; cont.resume(throwing: e)
                default: break
                }
            }
            s.listener.start(queue: s.queue)
        }
        return s
    }

    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: b[..<end.lowerBound], as: UTF8.self))
            } else if error == nil && !done {
                self.read(c, b)
            } else {
                c.cancel()
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let (status, body) = handler(target, headers)
        let payload = Data(body.compactJSON().utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 503: "Service Unavailable"][status] ?? "Status"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(payload)
        c.send(content: out, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
