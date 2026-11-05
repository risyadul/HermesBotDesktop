import Foundation
import Testing
@testable import HermesGatewayKit

@Suite struct MediaTagsTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    private func split(_ s: String) -> (text: String, media: [MediaRef]) { MediaTags.split(s, home: home) }

    @Test func plainTag() {
        let r = split("Here you go MEDIA:/tmp/a.png\nenjoy")
        #expect(r.media == [MediaRef(path: "/tmp/a.png", kind: .image)])
        #expect(r.text == "Here you go \nenjoy")
    }

    @Test func tagAtEndWithoutNewline() {
        let r = split("done\nMEDIA:/tmp/report.pdf")
        #expect(r.media.map(\.path) == ["/tmp/report.pdf"])
        #expect(r.media[0].kind == .pdf)
        #expect(r.text == "done")
    }

    @Test func multipleTagsInOrder() {
        let r = split("MEDIA:/a/one.png\ntext\nMEDIA:/a/two.mp3\nMEDIA:/a/three.mp4")
        #expect(r.media.map(\.kind) == [.image, .audio, .video])
        #expect(r.media.map(\.fileName) == ["one.png", "two.mp3", "three.mp4"])
        #expect(r.text == "\ntext")
    }

    @Test func gluedTagsSplitAtMediaKeyword() {
        let r = split("MEDIA:/a.pngMEDIA:/b.png")
        #expect(r.media.map(\.path) == ["/a.png", "/b.png"])
    }

    @Test func quotedPathsWithSpaces() {
        let r = split("MEDIA:\"/tmp/my report.pdf\" and MEDIA:'/tmp/a b.png' and MEDIA:`/tmp/c d.csv`")
        #expect(r.media.map(\.path) == ["/tmp/my report.pdf", "/tmp/a b.png", "/tmp/c d.csv"])
        #expect(r.text == " and  and")
    }

    @Test func unquotedPathWithSpacesEndingInKnownExtension() {
        let r = split("MEDIA:/tmp/my report final.pdf thanks")
        #expect(r.media.map(\.path) == ["/tmp/my report final.pdf"])
        #expect(r.text == " thanks")
    }

    @Test func sentenceFinalPeriodIsNotPartOfPath() {
        let r = split("See MEDIA:/tmp/data.csv.")
        #expect(r.media.map(\.path) == ["/tmp/data.csv"])
        #expect(r.text == "See")
    }

    @Test func multiPartExtensionKeepsGz() {
        let r = split("MEDIA:/tmp/archive.tar.gz\n")
        #expect(r.media.map(\.path) == ["/tmp/archive.tar.gz"])
    }

    @Test func emphasisMarkersAreStripped() {
        let r = split("**MEDIA:/tmp/x.pdf** ok")
        #expect(r.media.map(\.path) == ["/tmp/x.pdf"])
        #expect(r.text == " ok")
    }

    @Test func tildeExpandsToHome() {
        let r = split("MEDIA:~/Pictures/cat.jpg")
        #expect(r.media.map(\.path) == ["/Users/tester/Pictures/cat.jpg"])
    }

    @Test func relativePathIsNotATag() {
        let input = "MEDIA:relative/a.png and MEDIA:./b.png"
        let r = split(input)
        #expect(r.media.isEmpty)
        #expect(r.text == input)
    }

    @Test func windowsDrivePathIsATag() {
        let r = split(#"MEDIA:C:\Users\me\a.png"#)
        #expect(r.media.map(\.path) == [#"C:\Users\me\a.png"#])
        #expect(r.media[0].fileName == "a.png")
    }

    @Test func cjkTerminatorEndsPath() {
        let r = split("MEDIA:/tmp/早报.pdf（782.6 KB）")
        #expect(r.media.map(\.path) == ["/tmp/早报.pdf"])
        #expect(r.text == "（782.6 KB）")
    }

    @Test func fencedCodeLeftVerbatim() {
        let input = "Example:\n```\nMEDIA:/tmp/a.png\n```\nend"
        let r = split(input)
        #expect(r.media.isEmpty)
        #expect(r.text == input)
    }

    @Test func inlineCodeLeftVerbatim() {
        let input = "Use `MEDIA:/tmp/a.png` to send"
        let r = split(input)
        #expect(r.media.isEmpty)
        #expect(r.text == input)
    }

    @Test func tagOutsideCodeStillExtractedWhenCodePresent() {
        let r = split("```\nMEDIA:/x/in.png\n```\nMEDIA:/x/out.png")
        #expect(r.media.map(\.path) == ["/x/out.png"])
        #expect(r.text.contains("MEDIA:/x/in.png"))
        #expect(!r.text.contains("out.png"))
    }

    @Test func blockquoteLeftVerbatim() {
        let input = "> MEDIA:/tmp/a.png"
        let r = split(input)
        #expect(r.media.isEmpty)
        #expect(r.text == input)
    }

    @Test func directivesStrippedAndFlagsSet() {
        let r = split("[[audio_as_voice]] hi MEDIA:/tmp/v.ogg and MEDIA:/tmp/p.png [[as_document]]")
        #expect(!r.text.contains("[["))
        #expect(r.media[0] == MediaRef(path: "/tmp/v.ogg", kind: .audio, asVoice: true, asDocument: true))
        // voice flag applies to audio only (base.py:3337)
        #expect(r.media[1] == MediaRef(path: "/tmp/p.png", kind: .image, asVoice: false, asDocument: true))
    }

    @Test func directiveWithoutTagStillStripped() {
        let r = split("hello [[audio_as_voice]]")
        #expect(r.text == "hello")
        #expect(r.media.isEmpty)
    }

    @Test func duplicatesCollapse() {
        let r = split("MEDIA:/tmp/a.png\nMEDIA:/tmp/a.png\nMEDIA:~/x.png and MEDIA:/Users/tester/x.png")
        #expect(r.media.map(\.path) == ["/tmp/a.png", "/Users/tester/x.png"])
    }

    @Test func unknownExtensionIsLeftVisible() {
        let input = "MEDIA:/tmp/script.py"
        let r = split(input)
        #expect(r.media.isEmpty)
        #expect(r.text == input)
    }

    @Test func otherKnownExtensionsAreFileKind() {
        let r = split("MEDIA:/a/b.zip\nMEDIA:/a/c.docx\nMEDIA:/a/d.csv")
        #expect(r.media.map(\.kind) == [.file, .file, .file])
    }

    @Test func extensionsAreCaseInsensitive() {
        let r = split("MEDIA:/a/B.PNG\nMEDIA:/a/c.Mp3\nmedia:/a/d.PDF")
        #expect(r.media.map(\.kind) == [.image, .audio, .pdf])
    }

    @Test func emptyAndGarbageInput() {
        #expect(split("").text == "")
        #expect(split("").media.isEmpty)
        let junk = "MEDIA: MEDIA:MEDIA: \u{0} 💥 ``` ` [[ ]]"
        let r = split(junk)
        #expect(r.media.isEmpty)
        #expect(r.text == junk)
        #expect(split("MEDIA:").media.isEmpty)
        #expect(split("MEDIA:/").media.isEmpty)
    }

    @Test func plainTextUntouched() {
        let input = "  leading and trailing  \n\n\n\nkept\n\n\n"
        let r = split(input)
        #expect(r.text == input)  // no directive, returned verbatim (base.py:3356-3357)
    }

    @Test func whitespaceCleanupCollapsesBlankLinesAndRstrips() {
        let r = split("a\n\n\nMEDIA:/t/x.png\n\n\nb\n\n")
        #expect(r.text == "a\n\nb")
    }

    @Test func unicodeSurroundingTextSurvives() {
        let r = split("😀 hello MEDIA:/t/x.png 世界")
        #expect(r.text == "😀 hello  世界")
    }
}

@Suite struct MediaSafetyTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("mediasafety-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func ref(_ path: String) -> MediaRef { MediaRef(path: path, kind: .file) }

    @Test func tempFileAllowed() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("a.png")
        try write(file)
        let result = MediaSafety.check(ref(file.path), home: root.appendingPathComponent("home"))
        guard case .success(let url) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(url.lastPathComponent == "a.png")
    }

    @Test func relativePathRefused() {
        #expect(MediaSafety.check(ref("a/b.png")) == .failure(.notAbsolute))
        #expect(MediaSafety.check(ref("~/b.png")) == .failure(.notAbsolute))
        #expect(MediaSafety.check(ref("")) == .failure(.notAbsolute))
    }

    @Test func missingRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        #expect(MediaSafety.check(ref(root.appendingPathComponent("nope.png").path)) == .failure(.notFound))
    }

    @Test func directoryRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        #expect(MediaSafety.check(ref(root.path)) == .failure(.notRegularFile))
    }

    @Test func envAndKeyNamesRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for name in [".env", "prod.env", ".env.local", "server.pem", "tls.key", "id_rsa", "id_rsa.pub", "id_ed25519", "cert.p12"] {
            let file = root.appendingPathComponent(name)
            try write(file)
            #expect(MediaSafety.check(ref(file.path), home: root) == .failure(.forbidden), "\(name)")
        }
    }

    @Test func credentialDirsUnderHomeRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for sub in [".ssh/config", ".aws/credentials", ".gnupg/pubring.kbx", "Library/Keychains/login.keychain-db", ".config/x/y.txt"] {
            let file = root.appendingPathComponent(sub)
            try write(file)
            #expect(MediaSafety.check(ref(file.path), home: root) == .failure(.forbidden), "\(sub)")
        }
    }

    @Test func symlinkIntoSshRefused() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        let secret = root.appendingPathComponent(".ssh/notes.txt")
        try write(secret)
        let link = root.appendingPathComponent("innocent.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(MediaSafety.check(ref(link.path), home: root) == .failure(.forbidden))
    }

    @Test func hermesSecretsRefusedButOtherFilesAllowed() throws {
        let root = try makeRoot(); defer { try? fm.removeItem(at: root) }
        for name in [".hermes/auth.json", ".hermes/google_token.json", ".hermes/config.yaml", ".hermes/state.db", ".hermes/sessions/s1.json", ".hermes/skills/my_secret_notes.md"] {
            let file = root.appendingPathComponent(name)
            try write(file)
            #expect(MediaSafety.check(ref(file.path), home: root) == .failure(.forbidden), "\(name)")
        }
        let ok = root.appendingPathComponent(".hermes/skills/report.png")
        try write(ok)
        guard case .success = MediaSafety.check(ref(ok.path), home: root) else { Issue.record("expected allowed"); return }
    }

    @Test func systemLocationsRefused() {
        #expect(MediaSafety.check(ref("/etc/hosts")) == .failure(.forbidden))
        #expect(MediaSafety.check(ref("/private/etc/hosts")) == .failure(.forbidden))
        #expect(MediaSafety.check(ref("/System/Library/CoreServices/SystemVersion.plist")) == .failure(.forbidden))
        #expect(MediaSafety.check(ref("/bin/ls")) == .failure(.forbidden))
        #expect(MediaSafety.check(ref("/usr/bin/true")) == .failure(.forbidden))
        #expect(MediaSafety.check(ref("/sbin/ping")) == .failure(.forbidden))
    }

    @Test func errorsHaveMessages() {
        for e in [MediaSafetyError.notAbsolute, .notFound, .notRegularFile, .forbidden] {
            #expect(e.errorDescription?.isEmpty == false)
        }
    }
}
