import Foundation
import XCTest
@testable import HermesGatewayKit

/// Pure helpers from the security round: `VisibleText` (hidden / bidi characters and whitespace padding),
/// `MediaPathPolicy` (text-only triage before any filesystem call), hidden built-in slash commands.
final class VisibleTextTests: XCTestCase {
    func testHiddenCharactersAreShownByCodePoint() {
        XCTAssertEqual(VisibleText.reveal("rm -rf /\u{202E}gpj.exe"), "rm -rf /⟨U+202E⟩gpj.exe")
        XCTAssertEqual(VisibleText.reveal("a\u{200B}b\u{FEFF}c\u{2066}d\u{2069}"), "a⟨U+200B⟩b⟨U+FEFF⟩c⟨U+2066⟩d⟨U+2069⟩")
        XCTAssertEqual(VisibleText.reveal("x\u{0}y\u{1B}[2Jz\u{7F}"), "x⟨U+0000⟩y⟨U+001B⟩[2Jz⟨U+007F⟩")
        XCTAssertEqual(VisibleText.reveal("line1\nline2\tcol"), "line1\nline2\tcol", "newline and tab stay")
        XCTAssertEqual(VisibleText.reveal("a\u{2028}b"), "a⟨U+2028⟩b")
        XCTAssertEqual(VisibleText.reveal("plain ascii 123"), "plain ascii 123")
    }

    func testLongWhitespaceRunsAreMarked() {
        XCTAssertEqual(VisibleText.reveal("ls" + String(repeating: " ", count: 8) + "x"), "ls        x", "8 is ordinary")
        XCTAssertEqual(VisibleText.reveal("ls" + String(repeating: " ", count: 40) + "; rm -rf ~"), "ls␠×40; rm -rf ~")
        XCTAssertEqual(VisibleText.reveal("a" + String(repeating: "\t", count: 9) + "b"), "a␠×9b")
        XCTAssertEqual(VisibleText.reveal(String(repeating: " ", count: 12) + "\n" + "b"), "␠×12\nb", "a newline ends a run")
        let once = VisibleText.reveal("x\u{202E}" + String(repeating: " ", count: 20))
        XCTAssertEqual(VisibleText.reveal(once), once, "idempotent")
    }

    func testPathPolicyIsTextOnly() {
        let home = "/Users/me"
        XCTAssertEqual(MediaPathPolicy.classify("/net/host/a.pdf", home: home), .remote)
        XCTAssertEqual(MediaPathPolicy.classify("/NETWORK/Servers/a.pdf", home: home), .remote, "case-insensitive volume")
        XCTAssertEqual(MediaPathPolicy.classify("/tmp/../net/h/a.pdf", home: home), .remote, ".. is folded first")
        XCTAssertEqual(MediaPathPolicy.classify("/Volumes/USB/a.png", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/Users/me/Downloads/a.zip", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/users/ME/documents/x/a.pdf", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/Users/me/Library/Mobile Documents/a.pdf", home: home), .deferred)
        XCTAssertEqual(MediaPathPolicy.classify("/Users/me/Projects/a.pdf", home: home), .ordinary)
        XCTAssertEqual(MediaPathPolicy.classify("/Users/me/Desktopper/a.pdf", home: home), .ordinary)
        XCTAssertEqual(MediaPathPolicy.classify("/tmp/out/a.png", home: home), .ordinary)
        XCTAssertEqual(MediaPathPolicy.lexical("//a/./b/../c/"), "/a/c")
    }

    func testCredentialPathIsRefusedBeforeAnyFilesystemCall() {
        // The file does not exist: a refusal (not "not found") proves the text check ran first.
        let home = URL(fileURLWithPath: "/Users/nobody-\(UUID().uuidString)")
        let r = MediaSafety.check(MediaRef(path: home.path + "/.ssh/id_ed25519", kind: .file), home: home)
        XCTAssertEqual(r, .failure(.forbidden))
    }

    func testHiddenBuiltInsAreRefusedWithDesktopText() {
        let c = SlashCatalog(result: [
            "pairs": [["/goal", "Set a goal"]], "canon": ["/exit": "/quit"],
            "commands": ["/quit": ["desktop": "terminal"], "/platforms": ["desktop": "messaging"],
                         "/config": ["desktop": "settings"], "/goal": ["desktop": nil]],
        ])
        XCTAssertEqual(c.unavailableMessage("quit"), "/quit is only available in the terminal interface.")
        XCTAssertEqual(c.unavailableMessage("EXIT"), "/quit is only available in the terminal interface.", "alias")
        XCTAssertEqual(c.unavailableMessage("platforms"), "/platforms is only used from messaging platforms.")
        XCTAssertNotNil(c.unavailableMessage("config"))
        XCTAssertNil(c.unavailableMessage("goal"))
        XCTAssertNil(c.unavailableMessage("skills"), "unknown to the catalog: the backend decides")
    }
}
