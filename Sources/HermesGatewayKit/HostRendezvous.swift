import CryptoKit
import Darwin
import Foundation

/// Reader for the `hermes serve` host rendezvous (hermes-agent `gateway/host_rendezvous.py`).
///
/// A backend that wins a host role publishes, in the per-OS-user lock dir:
/// - `host-<role>.json`: `{role, home, pid, createTime, startTime, host, port, protocolVersion,
///   tokenFingerprint, profiles, updatedAt}` (`HostRecord.to_json`, `host_rendezvous.py:107-120`);
/// - `host-<role>.token`: the live session token, owner-only 0600 (`publish_record`, `:465-507`).
///
/// Roles: `serve` (machine-level owner, standalone `hermes serve`) and `desktop-serve` (the Electron
/// app's own backend, `ROLE_DESKTOP_SERVE`, `:66-71`). The CLI attach ladder reads `serve` only
/// (`hermes_cli/main_dashboard.py:818-835`); this client reads both, `serve` first.
///
/// A record only nominates a candidate. It is accepted only when every check below passes, which
/// mirrors the Python side (`read_record`, `record_is_stale`, `record_token_is_consistent`,
/// `probe_owner`):
/// 1. record + token file owned by this uid inside a dir this uid owns (`_record_is_own`, `:178-199`);
///    stricter here: lock dir, record and token are never followed through a symlink, and a
///    group/world-writable lock dir is refused;
/// 2. `protocolVersion == 1` (`HOST_PROTOCOL_VERSION`, `:54`, `record_is_stale` `:257-271`);
/// 3. the PID is alive and its start-time fingerprint matches `startTime` within 200 centiseconds
///    (macOS: `round(psutil.create_time()*100)`, `gateway/status.py:470-507`, tolerance `:452`);
///    a record without `startTime` falls back to `createTime`;
/// 4. sha256(token)[:16] == `tokenFingerprint` (`token_fingerprint` `:220-222`, `:361-370`);
/// 5. the dial host is loopback (127.0.0.0/8, ::1, localhost): the token is never sent off-host;
/// 6. TCP connect to the recorded port, then `GET /api/host/identity` with the token answers
///    `{pid, role}` equal to the record (`probe_owner` `:285-325`, route `web_routers/status.py:130-145`).
///    Redirects are refused, so the token headers are never forwarded.
///
/// The token is read only into memory and is never logged or written anywhere by this type.
public enum HostRendezvous {
    public enum Role: String, Sendable, CaseIterable {
        case serve = "serve"
        case desktopServe = "desktop-serve"
    }

    public static let protocolVersion = 1
    public static let startTimeTolerance: Int64 = 200
    public static let identityPath = "/api/host/identity"

    public struct Record: Sendable, Decodable {
        public let role: String
        public let home: String?
        public let pid: Int32
        public let createTime: Double?
        public let startTime: Int64?
        public let host: String?
        public let port: Int?
        public let protocolVersion: Int?
        public let tokenFingerprint: String?
        public let profiles: [String]?
        public let updatedAt: String?

        /// Address to dial: a wildcard bind is reached over loopback (`dial_host`, `:279-282`).
        public var dialHost: String {
            let h = host ?? ""
            return ["0.0.0.0", "::", "*", ""].contains(h) ? "127.0.0.1" : h
        }
    }

    /// A record that passed every check. `token` stays in memory only.
    public struct Attachment: Sendable, CustomStringConvertible {
        public let role: Role
        public let record: Record
        public let token: String
        public let identity: JSONValue

        public var wsURL: URL {
            var c = URLComponents()
            c.scheme = "ws"; c.host = record.dialHost; c.port = record.port; c.path = "/api/ws"
            c.queryItems = [URLQueryItem(name: "token", value: token)]
            return c.url!
        }

        public var httpBase: URL { URL(string: "http://\(record.dialHost):\(record.port ?? 0)")! }

        /// Safe to log: no token.
        public var description: String {
            "role=\(role.rawValue) pid=\(record.pid) port=\(record.port ?? 0) host=\(record.dialHost)"
        }
    }

    /// One discovery verdict per role, in check order. Safe to log.
    public struct Verdict: Sendable, CustomStringConvertible {
        public let role: Role
        public let accepted: Bool
        public let reason: String
        public var description: String { "\(role.rawValue): \(accepted ? "ACCEPT" : "reject") (\(reason))" }
    }

    /// `HERMES_GATEWAY_LOCK_DIR`, else `$XDG_STATE_HOME/hermes/gateway-locks` (absolute only),
    /// else `~/.local/state/hermes/gateway-locks` (`gateway/status.py:319-335`).
    public static func lockDir(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let o = env["HERMES_GATEWAY_LOCK_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        let xdg = env["XDG_STATE_HOME"] ?? ""
        let state = xdg.hasPrefix("/") ? URL(fileURLWithPath: xdg)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return state.appendingPathComponent("hermes/gateway-locks")
    }

    /// Tries `serve`, then `desktop-serve`. Returns the first accepted attachment plus every verdict.
    public static func discover(lockDir: URL, roles: [Role] = [.serve, .desktopServe],
                                probeTimeout: TimeInterval = 2) async -> (Attachment?, [Verdict]) {
        var verdicts: [Verdict] = []
        for role in roles {
            switch await check(role: role, lockDir: lockDir, probeTimeout: probeTimeout) {
            case .success(let a):
                verdicts.append(Verdict(role: role, accepted: true, reason: a.description))
                return (a, verdicts)
            case .failure(let why):
                verdicts.append(Verdict(role: role, accepted: false, reason: why.reason))
            }
        }
        return (nil, verdicts)
    }

    struct Rejection: Error { let reason: String }

    static func check(role: Role, lockDir: URL, probeTimeout: TimeInterval) async -> Result<Attachment, Rejection> {
        let recordURL = lockDir.appendingPathComponent("host-\(role.rawValue).json")
        let tokenURL = lockDir.appendingPathComponent("host-\(role.rawValue).token")
        guard lstatInfo(recordURL) != nil else { return .failure(.init(reason: "no record")) }
        if let why = lockDirProblem(lockDir) { return .failure(.init(reason: why)) }
        guard let (data, recordInfo) = readNoFollow(recordURL) else {
            return .failure(.init(reason: "record is a symlink, not a regular file, or unreadable"))
        }
        guard recordInfo.st_uid == getuid() else { return .failure(.init(reason: "record not owned by this uid")) }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return .failure(.init(reason: "record unreadable/corrupt"))
        }
        guard record.role == role.rawValue, record.pid > 0 else { return .failure(.init(reason: "record role/pid invalid")) }
        guard record.protocolVersion == protocolVersion else {
            return .failure(.init(reason: "protocolVersion \(record.protocolVersion.map(String.init) ?? "nil") != \(protocolVersion)"))
        }
        guard let port = record.port, port > 0, port <= 65535 else { return .failure(.init(reason: "record has no port")) }
        guard isLoopback(record.dialHost) else {
            return .failure(.init(reason: "dial host \(record.dialHost) is not loopback"))
        }
        switch incarnationMatches(record) {
        case .some(false): return .failure(.init(reason: "pid \(record.pid) dead or start time mismatch (stale)"))
        case .none: break  // unprovable: the identity probe below decides, as in record_is_stale
        case .some(true): break
        }
        guard let (tokenData, tokenInfo) = readNoFollow(tokenURL), tokenInfo.st_uid == getuid(),
              let raw = String(data: tokenData, encoding: .utf8) else {
            return .failure(.init(reason: "token file missing/symlinked/unreadable/not owned"))
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.init(reason: "token empty")) }
        if tokenInfo.st_mode & 0o077 != 0 {
            return .failure(.init(reason: "token file mode \(String(tokenInfo.st_mode & 0o777, radix: 8)) is not owner-only"))
        }
        let fp = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        guard let want = record.tokenFingerprint, !want.isEmpty, String(fp) == want else {
            return .failure(.init(reason: "token fingerprint mismatch (torn restart?)"))
        }
        guard tcpConnects(host: record.dialHost, port: port, timeout: probeTimeout) else {
            return .failure(.init(reason: "nothing listening on \(record.dialHost):\(port)"))
        }
        guard let identity = await probeIdentity(host: record.dialHost, port: port, token: token, timeout: probeTimeout) else {
            return .failure(.init(reason: "identity probe failed"))
        }
        guard identity["pid"]?.int == Int(record.pid), identity["role"]?.string == role.rawValue else {
            return .failure(.init(reason: "identity answered pid=\(identity["pid"]?.int ?? -1) role=\(identity["role"]?.string ?? "?") ≠ record"))
        }
        return .success(Attachment(role: role, record: record, token: token, identity: identity))
    }

    // MARK: - process + file checks

    /// `lstat`: never follows a symlink.
    static func lstatInfo(_ url: URL) -> stat? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st : nil
    }

    /// Why the lock dir must not be trusted, or nil. `mode` includes the file-type bits (from `lstat`).
    static func lockDirProblem(mode: mode_t, owner: uid_t, me: uid_t = getuid()) -> String? {
        switch mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: return "lock dir is a symlink"
        default: return "lock dir is not a directory"
        }
        if owner != me { return "lock dir not owned by this uid" }
        if mode & 0o022 != 0 { return "lock dir mode \(String(mode & 0o777, radix: 8)) is group/world-writable" }
        return nil
    }

    static func lockDirProblem(_ url: URL) -> String? {
        guard let st = lstatInfo(url) else { return "lock dir missing" }
        return lockDirProblem(mode: st.st_mode, owner: st.st_uid)
    }

    /// Contents + `fstat` of a regular file opened with `O_NOFOLLOW` (no check/read race); nil for a
    /// symlink, a non-regular file, or a read error.
    static func readNoFollow(_ url: URL) -> (Data, stat)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        do { return (try handle.readToEnd() ?? Data(), st) } catch { return nil }
    }

    /// 127.0.0.0/8, ::1 (any spelling) or `localhost`.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if h.lowercased() == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// Start time of `pid` in the same unit hermes records on macOS: centiseconds since the epoch.
    public static func processStartCentiseconds(_ pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Int64(((Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6) * 100).rounded())
    }

    static func pidAlive(_ pid: Int32) -> Bool? {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM ? true : (errno == ESRCH ? false : nil)
    }

    /// true/false when provable, nil when not (mirrors `_record_incarnation_matches`).
    static func incarnationMatches(_ r: Record) -> Bool? {
        guard let alive = pidAlive(r.pid) else { return nil }
        if !alive { return false }
        guard let now = processStartCentiseconds(r.pid) else { return nil }
        if let recorded = r.startTime { return abs(now - recorded) <= startTimeTolerance }
        if let ct = r.createTime { return abs(Double(now) / 100 - ct) < 1.0 }
        return nil
    }

    static func tcpConnects(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else { return false }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    static func probeIdentity(host: String, port: Int, token: String, timeout: TimeInterval) async -> JSONValue? {
        guard let url = URL(string: "http://\(host):\(port)\(identityPath)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(token, forHTTPHeaderField: "X-Hermes-Token")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONDecoder().decode(JSONValue.self, from: data), v.object != nil else { return nil }
        return v
    }

    /// A 3xx comes back as the response itself (≠ 200, so the probe fails) instead of being followed.
    final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
