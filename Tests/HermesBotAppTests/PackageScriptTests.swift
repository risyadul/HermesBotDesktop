import Foundation
import XCTest

/// E3: scripts/package-app.sh flag parsing and its signing/notarization plan, through `bash -n` and `--dry-run`
/// (nothing is built, signed or uploaded). The environment is spelled out, so a maintainer's own
/// DEVELOPER_ID_APPLICATION / NOTARY_PROFILE never leaks in.
final class PackageScriptTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let script = repo.appendingPathComponent("scripts/package-app.sh")

    private struct Run {
        let status: Int32
        let out: String
        let err: String
    }

    private func run(_ args: [String], env extra: [String: String] = [:]) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script.path] + args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory()].merging(extra) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }

    func testScriptParses() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", Self.script.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "bash -n scripts/package-app.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.script.path))
    }

    func testEntitlementsAreAMinimalPlist() throws {
        let url = Self.repo.appendingPathComponent("scripts/HermesBot.entitlements")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Bool])
        XCTAssertEqual(plist["com.apple.security.network.client"], true)
        XCTAssertNil(plist["com.apple.security.app-sandbox"], "not sandboxed: the app runs `hermes` and reads ~/.hermes")
        for key in plist.keys {
            XCTAssertFalse(key.contains("cs.disable-library-validation") || key.contains("cs.allow-jit")
                           || key.contains("cs.allow-unsigned-executable-memory") || key.contains("get-task-allow"),
                           "no hardened-runtime exception: \(key)")
        }
    }

    /// The committed icon is a well-formed .icns with every size macOS asks for (16 to 512 pt, 1× and 2×), and the
    /// script bundles it and names it in Info.plist.
    func testAppIconIsBundledWithEverySize() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/AppIcon.icns"))
        func uint32(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        XCTAssertEqual(uint32(4), data.count, "header length matches the file")
        var types = Set<String>(), offset = 8
        while offset + 8 <= data.count {
            let length = uint32(offset + 4)
            XCTAssertGreaterThan(length, 8, "chunk at \(offset)")
            guard length > 8 else { break }
            types.insert(String(decoding: data[offset..<offset + 4], as: UTF8.self))
            offset += length
        }
        XCTAssertEqual(offset, data.count, "chunks tile the file")
        // ic04/ic11 16 pt, ic05/ic12 32 pt, ic07/ic13 128 pt, ic08/ic14 256 pt, ic09/ic10 512 pt (1× / 2×).
        for type in ["ic04", "ic11", "ic05", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"] {
            XCTAssertTrue(types.contains(type), "missing \(type) in \(types.sorted())")
        }
        let script = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertTrue(script.contains(#"cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns""#))
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
    }

    func testUniversalDryRunPlansBothArchitecturesAndAdHocSigning() throws {
        let r = try run(["0.2.0", "--universal", "--dry-run"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("version: 0.2.0\n"), r.out)
        XCTAssertTrue(r.out.contains("architectures: arm64 x86_64\n"), r.out)
        XCTAssertTrue(r.out.contains("zip: dist/Herald-0.2.0-macos-universal.zip\n"), r.out)
        XCTAssertTrue(r.out.contains("signing: ad-hoc"), r.out)
        XCTAssertTrue(r.out.contains("notarization: skipped"), r.out)
    }

    func testFlagOrderAndTagPrefixDoNotMatter() throws {
        let r = try run(["--dry-run", "--universal", "v1.4"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("version: 1.4\n"), r.out)
        XCTAssertTrue(r.out.contains("zip: dist/Herald-1.4-macos-universal.zip\n"), r.out)
    }

    func testWithoutUniversalOnlyTheHostArchitecture() throws {
        let r = try run(["0.2.0", "--dry-run"])
        XCTAssertEqual(r.status, 0, r.err)
        #if arch(arm64)
        let host = "arm64"
        #else
        let host = "x86_64"
        #endif
        XCTAssertTrue(r.out.contains("architectures: \(host)\n"), r.out)
        XCTAssertTrue(r.out.contains("zip: dist/Herald-0.2.0-macos-\(host).zip\n"), r.out)
    }

    func testDeveloperIDAndNotaryProfilePlanNotarization() throws {
        let identity = "Developer ID Application: Example (ABCDE12345)"
        let signedOnly = try run(["0.2.0", "--universal", "--dry-run"], env: ["DEVELOPER_ID_APPLICATION": identity])
        XCTAssertEqual(signedOnly.status, 0, signedOnly.err)
        XCTAssertTrue(signedOnly.out.contains("signing: Developer ID \"\(identity)\" (hardened runtime, scripts/HermesBot.entitlements)"), signedOnly.out)
        XCTAssertTrue(signedOnly.out.contains("notarization: skipped"), signedOnly.out)

        let notarized = try run(["0.2.0", "--universal", "--dry-run"],
                                env: ["DEVELOPER_ID_APPLICATION": identity, "NOTARY_PROFILE": "hermesbot-notary"])
        XCTAssertEqual(notarized.status, 0, notarized.err)
        XCTAssertTrue(notarized.out.contains("notarization: notarytool profile \"hermesbot-notary\", then stapled"), notarized.out)
    }

    func testNotaryProfileWithoutDeveloperIDIsAnError() throws {
        let r = try run(["0.2.0", "--dry-run"], env: ["NOTARY_PROFILE": "hermesbot-notary"])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("DEVELOPER_ID_APPLICATION is not"), r.err)
    }

    func testBadArguments() throws {
        let unknown = try run(["0.2.0", "--fat"])
        XCTAssertEqual(unknown.status, 2)
        XCTAssertTrue(unknown.err.contains("unknown option '--fat'"), unknown.err)
        let twoVersions = try run(["0.2.0", "0.3.0", "--dry-run"])
        XCTAssertEqual(twoVersions.status, 2)
        for bad in ["1.2.3.4", "1.2-beta", "latest"] {
            let r = try run([bad, "--dry-run"])
            XCTAssertEqual(r.status, 1, bad)
            XCTAssertTrue(r.err.contains("must look like 1.2.3"), r.err)
        }
        let help = try run(["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.out.hasPrefix("Usage: scripts/package-app.sh [version] [--universal] [--dry-run]"), help.out)
        XCTAssertTrue(help.out.contains("NOTARY_PROFILE"), help.out)
    }
}
