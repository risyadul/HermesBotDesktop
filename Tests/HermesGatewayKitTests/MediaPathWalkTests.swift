import Foundation
import XCTest
@testable import HermesGatewayKit

/// Security re-validation round: folded path classification (`ſ`, firmlink alias, `/.nofollow`), the
/// hop-by-hop symlink walk that replaced `realpath`, and the wider `VisibleText` reveal. Symlinks are made in
/// a temp dir and point at FAKE paths: nothing here resolves into real `/Volumes` or TCC folders.
final class MediaPathWalkTests: XCTestCase {
    private let home = "/Users/me"
    private var dir: URL!

    override func setUpWithError() throws {
        // Resolved, so expectations compare with the walk's kernel-style result (`/var` → `/private/var`).
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("hba-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: try XCTUnwrap(MediaPathPolicy.walk(raw.path, home: home, userInitiated: false).get()))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func link(_ name: String, to target: String) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    // MARK: classification on folded text

    func testUnicodeCaseFoldingCannotDodgeTheProtectedRoots() {
        XCTAssertEqual(MediaPathPolicy.classify("/Volumeſ/USB/a.png", home: home), .deferred)
        for sub in ["Deſktop", "Documentſ", "Downloadſ", "Library/Mobile Documentſ"] {
            XCTAssertEqual(MediaPathPolicy.classify("/Users/me/\(sub)/a.pdf", home: home), .deferred, sub)
        }
        XCTAssertEqual(MediaPathPolicy.classify("/Ｖｏｌｕｍｅｓ/x/a.png", home: home), .deferred, "width-folded")
    }

    func testFirmlinkAliasAndDotRootsAreCaught() {
        XCTAssertEqual(MediaPathPolicy.classify("/System/Volumes/Data/Users/me/Desktop/a.png", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/system/volumes/data/Volumes/USB/a.png", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/System/Volumes/Data/home/u/a.png", home: home), .remote)
        XCTAssertEqual(MediaPathPolicy.classify("/.nofollow/Users/me/a.png", home: home), .refused)
        XCTAssertEqual(MediaPathPolicy.classify("/.resolve/1/Users/me/a.png", home: home), .refused)
        XCTAssertEqual(MediaPathPolicy.classify("/.vol/16777220/2/a.png", home: home), .refused)
        XCTAssertEqual(MediaPathPolicy.classify("/Users/me/.hidden/a.png", home: home), .ordinary, "only a FIRST component")
    }

    func testDenylistComparesFoldedPaths() {
        let h = "/Users/me"
        XCTAssertTrue(MediaSafety.isForbidden("/system/volumes/data/etc/passwd", home: h))
        XCTAssertTrue(MediaSafety.isForbidden("/system/Library/x.plist", home: h), "case-insensitive /System")
        XCTAssertTrue(MediaSafety.isForbidden("/ſystem/Library/x.plist", home: h))
        XCTAssertTrue(MediaSafety.isForbidden("/.nofollow/Users/me/.docker/config.json", home: h))
        XCTAssertTrue(MediaSafety.isForbidden("/System/Volumes/Data/Users/me/.config/gh/hosts.yml", home: h))
        XCTAssertTrue(MediaSafety.isForbidden("/Users/ME/.hermes/auth.json", home: h))
        XCTAssertFalse(MediaSafety.isForbidden("/usr/local/share/a.png", home: h))
        let r = MediaSafety.check(MediaRef(path: "/.nofollow/Users/me/.hermes/auth.json", kind: .file),
                                  home: URL(fileURLWithPath: h))
        XCTAssertEqual(r, .failure(.forbidden))
    }

    // MARK: symlink walk

    func testSymlinkIntoAnExternalVolumeStopsBeforeTouchingIt() throws {
        let p = try link("a.png", to: "/Volumes/hba-fake-\(UUID().uuidString)/a.png")
        XCTAssertEqual(MediaPathPolicy.walk(p, home: home, userInitiated: false), .failure(.deferred),
                       "deferred (not notFound): classified before any lstat of the target")
        XCTAssertEqual(MediaSafety.check(MediaRef(path: p, kind: .image), home: URL(fileURLWithPath: home)),
                       .failure(.needsClick))
    }

    func testSymlinkIntoAProtectedHomeFolderNeedsAClick() throws {
        let fakeHome = dir.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: fakeHome, withIntermediateDirectories: true)  // no Desktop in it
        let p = try link("b.png", to: fakeHome + "/Desktop/b.png")
        XCTAssertEqual(MediaPathPolicy.walk(p, home: fakeHome, userInitiated: false), .failure(.deferred))
    }

    func testSymlinkToANetworkPathIsNeverFollowed() throws {
        let p = try link("c.png", to: "/net/host/c.png")
        XCTAssertEqual(MediaPathPolicy.walk(p, home: home, userInitiated: true), .failure(.remote), "not even on a click")
    }

    func testSymlinkToACredentialIsRefusedBeforeTheTargetIsTouched() throws {
        let fakeHome = dir.appendingPathComponent("home").path
        let p = try link("d.png", to: fakeHome + "/.ssh/id_ed25519")
        XCTAssertEqual(MediaSafety.check(MediaRef(path: p, kind: .image), home: URL(fileURLWithPath: fakeHome)),
                       .failure(.forbidden))
    }

    func testDotDotAfterASymlinkFollowsTheKernelNotTheText() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("deep/x"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("deep/target.png"))
        try Data([2]).write(to: dir.appendingPathComponent("sub/target.png"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("sub/link").path,
                                  withDestinationPath: dir.appendingPathComponent("deep/x").path)
        let p = dir.path + "/sub/link/../target.png"
        XCTAssertEqual(MediaPathPolicy.walk(p, home: home, userInitiated: false),
                       .success(dir.appendingPathComponent("deep/target.png").path))
        let r = MediaSafety.check(MediaRef(path: p, kind: .image), home: URL(fileURLWithPath: home))
        XCTAssertEqual(try r.get().path, dir.appendingPathComponent("deep/target.png").path)
    }

    func testSymlinkLoopStops() throws {
        _ = try link("loop-a", to: dir.appendingPathComponent("loop-b").path)
        let b = try link("loop-b", to: dir.appendingPathComponent("loop-a").path)
        XCTAssertEqual(MediaPathPolicy.walk(b, home: home, userInitiated: false), .failure(.tooManyLinks))
    }

    // MARK: VisibleText (S-N3)

    func testInvisibleAndBlankLookingCharactersAreRevealed() {
        let hidden: [UInt32] = [0x061C, 0x180E, 0x2060, 0x2064, 0x206A, 0x206F, 0x00AD, 0x034F, 0xFFF9, 0xFFFB,
                                0x115F, 0x3164, 0xFFA0, 0x2800, 0xFE00, 0xFE0F, 0xE0100, 0xE01EF, 0xE0001, 0xE007F]
        for v in hidden {
            let s = "a" + String(Character(Unicode.Scalar(v)!)) + "b"
            XCTAssertEqual(VisibleText.reveal(s), "a" + VisibleText.codePoint(v) + "b", String(v, radix: 16))
        }
        XCTAssertEqual(VisibleText.reveal("café ls"), "café ls", "ordinary accents stay")
    }

    func testStackedCombiningMarksAndBlankLineRunsAreShown() {
        XCTAssertEqual(VisibleText.reveal("e\u{301}\u{302}"), "e\u{301}\u{302}", "two marks are ordinary")
        XCTAssertEqual(VisibleText.reveal("e\u{301}\u{302}\u{303}x"), "e⟨U+0301⟩⟨U+0302⟩⟨U+0303⟩x")
        XCTAssertEqual(VisibleText.reveal("ls\n\n\n\nx"), "ls\n\n\n\nx", "three blank lines stay")
        XCTAssertEqual(VisibleText.reveal("ls" + String(repeating: "\n", count: 30) + "rm -rf ~"), "ls\n↵×30\nrm -rf ~")
        let once = VisibleText.reveal("a" + String(repeating: "\n \n", count: 10) + "b")
        XCTAssertEqual(VisibleText.reveal(once), once, "idempotent")
    }

    func testCommandDisplayIsForcedLeftToRightAndNonASCIIIsFlagged() {
        XCTAssertEqual(VisibleText.forcedLeftToRight("echo א\nls"), "\u{202D}echo א\u{202C}\n\u{202D}ls\u{202C}")
        XCTAssertTrue(VisibleText.hasNonASCII("echo א"))
        XCTAssertFalse(VisibleText.hasNonASCII("rm -rf build"))
    }
}
