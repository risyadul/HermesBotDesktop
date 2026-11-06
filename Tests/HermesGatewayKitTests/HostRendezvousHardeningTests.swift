import Foundation
import XCTest
@testable import HermesGatewayKit

/// Loopback-only dial hosts and lock-dir/record trust. Uses temp lock dirs only; no backend is dialled.
final class HostRendezvousHardeningTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hba-rdv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeLockDir(_ name: String = "locks", mode: Int = 0o700, host: String = "127.0.0.1") throws -> URL {
        let dir = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: nil)
        try writeRecord(in: dir, host: host)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
        return dir
    }

    private func writeRecord(in dir: URL, host: String) throws {
        let json = #"{"role":"serve","pid":\#(getpid()),"host":"\#(host)","port":9,"protocolVersion":1,"tokenFingerprint":"x"}"#
        let url = dir.appendingPathComponent("host-serve.json")
        FileManager.default.createFile(atPath: url.path, contents: Data(json.utf8), attributes: [.posixPermissions: 0o600])
    }

    private func reason(_ dir: URL) async -> String {
        let (found, verdicts) = await HostRendezvous.discover(lockDir: dir, roles: [.serve], probeTimeout: 0.2)
        XCTAssertNil(found)
        return verdicts.first?.reason ?? ""
    }

    // MARK: - loopback

    func testIsLoopback() {
        for h in ["127.0.0.1", "127.1.2.3", "127.255.255.254", "::1", "0:0:0:0:0:0:0:1", "[::1]", "localhost", "LOCALHOST"] {
            XCTAssertTrue(HostRendezvous.isLoopback(h), h)
        }
        for h in ["10.0.0.5", "192.168.1.2", "128.0.0.1", "0.0.0.0", "::", "::ffff:10.0.0.1", "example.com",
                  "localhost.evil.com", "", "126.255.255.255"] {
            XCTAssertFalse(HostRendezvous.isLoopback(h), h)
        }
    }

    func testWildcardBindStillDialsLoopback() throws {
        for h in ["0.0.0.0", "::", "*", ""] {
            let rec = try JSONDecoder().decode(HostRendezvous.Record.self,
                                               from: Data(#"{"role":"serve","pid":1,"host":"\#(h)"}"#.utf8))
            XCTAssertEqual(rec.dialHost, "127.0.0.1")
            XCTAssertTrue(HostRendezvous.isLoopback(rec.dialHost))
        }
    }

    func testNonLoopbackRecordIsRejected() async throws {
        let dir = try makeLockDir(host: "10.0.0.5")
        let why = await reason(dir)
        XCTAssertEqual(why, "dial host 10.0.0.5 is not loopback")
    }

    func testLoopbackRecordPassesDirAndHostChecks() async throws {
        let dir = try makeLockDir()
        let why = await reason(dir)
        // Gets as far as the (absent) token file: every dir/record/host check passed.
        XCTAssertTrue(why.hasPrefix("token file missing"), why)
    }

    // MARK: - lock dir + record trust

    func testLockDirProblemPure() {
        let me: uid_t = 501
        XCTAssertNil(HostRendezvous.lockDirProblem(mode: S_IFDIR | 0o700, owner: me, me: me))
        XCTAssertNil(HostRendezvous.lockDirProblem(mode: S_IFDIR | 0o755, owner: me, me: me))
        XCTAssertEqual(HostRendezvous.lockDirProblem(mode: S_IFDIR | 0o775, owner: me, me: me),
                       "lock dir mode 775 is group/world-writable")
        XCTAssertNotNil(HostRendezvous.lockDirProblem(mode: S_IFDIR | 0o757, owner: me, me: me))
        XCTAssertEqual(HostRendezvous.lockDirProblem(mode: S_IFLNK | 0o755, owner: me, me: me), "lock dir is a symlink")
        XCTAssertEqual(HostRendezvous.lockDirProblem(mode: S_IFREG | 0o700, owner: me, me: me), "lock dir is not a directory")
        XCTAssertEqual(HostRendezvous.lockDirProblem(mode: S_IFDIR | 0o700, owner: 0, me: me), "lock dir not owned by this uid")
    }

    func testWorldWritableLockDirIsRejected() async throws {
        let dir = try makeLockDir(mode: 0o777)
        let why = await reason(dir)
        XCTAssertEqual(why, "lock dir mode 777 is group/world-writable")
    }

    func testSymlinkedLockDirIsRejected() async throws {
        let real = try makeLockDir()
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let why = await reason(link)
        XCTAssertEqual(why, "lock dir is a symlink")
    }

    func testSymlinkedRecordIsRejected() async throws {
        let dir = tmp.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let elsewhere = tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try writeRecord(in: elsewhere, host: "127.0.0.1")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("host-serve.json"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("host-serve.json"))
        let why = await reason(dir)
        XCTAssertEqual(why, "record is a symlink, not a regular file, or unreadable")
    }

    func testMissingRecordStillReportsNoRecord() async throws {
        let dir = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let why = await reason(dir)
        XCTAssertEqual(why, "no record")
    }

    /// The real per-user default dir (when present on this machine) must not trip the new checks.
    func testDefaultLockDirPasses() throws {
        let dir = HostRendezvous.lockDir(environment: [:])
        guard HostRendezvous.lstatInfo(dir) != nil else { throw XCTSkip("no default lock dir at \(dir.path)") }
        XCTAssertNil(HostRendezvous.lockDirProblem(dir))
    }
}
