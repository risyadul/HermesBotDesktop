import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// MEDIA rendering: ref -> chip presentation (symbol, label, enabled or disabled with the reason), the lazy
/// on-disk resolution against a fake home, thumbnail sizing and decode, and the `MessageBody` text split.
/// Headless: no windows; temp files only.
final class MediaViewsTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaViewsTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 2048) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url.path
    }

    // MARK: presentation

    func testSymbolPerKind() {
        XCTAssertEqual(MediaPresentation.symbol(for: .image), "photo")
        XCTAssertEqual(MediaPresentation.symbol(for: .audio), "waveform")
        XCTAssertEqual(MediaPresentation.symbol(for: .video), "film")
        XCTAssertEqual(MediaPresentation.symbol(for: .pdf), "doc.richtext")
        XCTAssertEqual(MediaPresentation.symbol(for: .file), "doc")
    }

    func testAccessibilityLabels() {
        let image = MediaPresentation(ref: MediaRef(path: "/x/cat.png", kind: .image), resolution: nil)
        XCTAssertEqual(image.accessibilityLabel, "Image attachment cat.png")
        let pdf = MediaPresentation(ref: MediaRef(path: "/x/report.pdf", kind: .pdf), resolution: nil)
        XCTAssertEqual(pdf.accessibilityLabel, "File attachment report.pdf")
        XCTAssertEqual(pdf.title, "report.pdf")
    }

    func testPendingIsDisabledUntilChecked() {
        let p = MediaPresentation(ref: MediaRef(path: "/x/a.csv", kind: .file), resolution: nil)
        XCTAssertFalse(p.isEnabled, "nothing opens before the safety check finished")
        XCTAssertEqual(p.detail, "Checking…")
    }

    func testAvailableFileIsEnabledWithKindAndSize() throws {
        let path = try file("out/data.csv", bytes: 2048)
        let ref = MediaRef(path: path, kind: .file)
        let resolution = MediaResolver.resolve(ref, home: home)
        guard case .available(let url, let size, _) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertEqual(size, 2048)
        XCTAssertEqual(url.lastPathComponent, "data.csv")
        let p = MediaPresentation(ref: ref, resolution: resolution)
        XCTAssertTrue(p.isEnabled)
        XCTAssertTrue(p.detail.hasPrefix("CSV · "), p.detail)
        XCTAssertEqual(p.help, "Open data.csv")
    }

    func testVoiceNoteLabel() throws {
        let path = try file("v.ogg")
        let ref = MediaRef(path: path, kind: .audio, asVoice: true)
        let p = MediaPresentation(ref: ref, resolution: MediaResolver.resolve(ref, home: home))
        XCTAssertTrue(p.detail.hasPrefix("Voice note · "), p.detail)
    }

    func testMissingFileIsDisabledWithReason() {
        let ref = MediaRef(path: home.appendingPathComponent("gone.pdf").path, kind: .pdf)
        let p = MediaPresentation(ref: ref, resolution: MediaResolver.resolve(ref, home: home))
        XCTAssertFalse(p.isEnabled)
        XCTAssertEqual(p.help, MediaSafetyError.notFound.errorDescription)
        XCTAssertEqual(p.detail, p.help)
    }

    func testRelativePathIsDisabled() {
        let ref = MediaRef(path: "notes/a.txt", kind: .file)
        XCTAssertEqual(MediaResolver.resolve(ref, home: home), .unavailable(reason: MediaSafetyError.notAbsolute.errorDescription!))
    }

    func testCredentialPathIsRefused() throws {
        for relative in [".ssh/config.txt", ".hermes/.env.json", ".aws/creds.json"] {
            let path = try file(relative)
            let p = MediaPresentation(ref: MediaRef(path: path, kind: .file), resolution: MediaResolver.resolve(MediaRef(path: path, kind: .file), home: home))
            XCTAssertFalse(p.isEnabled, relative)
            XCTAssertEqual(p.help, MediaSafetyError.forbidden.errorDescription, relative)
        }
    }

    func testDirectoryIsRefused() throws {
        let dir = home.appendingPathComponent("folder.zip")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = MediaResolver.resolve(MediaRef(path: dir.path, kind: .file), home: home)
        XCTAssertEqual(r, .unavailable(reason: MediaSafetyError.notRegularFile.errorDescription!))
    }

    func testSymlinkToADifferentTypeIsRefused() throws {
        let script = try file("bin/run.command")
        let link = home.appendingPathComponent("report.pdf")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: script)
        let r = MediaResolver.resolve(MediaRef(path: link.path, kind: .pdf), home: home)
        XCTAssertEqual(r, .unavailable(reason: MediaResolver.typeMismatch), "Open must never launch a script behind a .pdf name")
    }

    func testSymlinkToSameTypeResolvesToTarget() throws {
        let target = try file("real/photo.PNG")
        let link = home.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        guard case .available(let url, _, _) = MediaResolver.resolve(MediaRef(path: link.path, kind: .image), home: home) else {
            return XCTFail("same extension, different case, must resolve")
        }
        XCTAssertEqual(url.lastPathComponent, "photo.PNG")
    }

    // MARK: cache

    func testCacheKeepsOnlySuccessfulResolutions() {
        let cache = MediaCache()
        cache.store(.unavailable(reason: "x"), for: "/a")
        XCTAssertNil(cache.resolution(for: "/a"), "a missing file is re-checked next time")
        let ok = MediaResolution.available(url: URL(fileURLWithPath: "/a"), size: 1, modified: .distantPast)
        cache.store(ok, for: "/a")
        XCTAssertEqual(cache.resolution(for: "/a"), ok)
        cache.store(.unavailable(reason: "gone"), for: "/a")
        XCTAssertNil(cache.resolution(for: "/a"), "a later failure evicts the cached success")
        XCTAssertNotEqual(MediaCache.thumbnailKey(path: "/a", modified: Date(timeIntervalSinceReferenceDate: 1)),
                          MediaCache.thumbnailKey(path: "/a", modified: Date(timeIntervalSinceReferenceDate: 2)))
    }

    // MARK: thumbnails

    func testDisplaySizeFitsBoundsAndNeverUpscales() {
        XCTAssertEqual(MediaThumbnail.displaySize(for: CGSize(width: 640, height: 480)), CGSize(width: 320, height: 240))
        XCTAssertEqual(MediaThumbnail.displaySize(for: CGSize(width: 1000, height: 100)), CGSize(width: 320, height: 32))
        XCTAssertEqual(MediaThumbnail.displaySize(for: CGSize(width: 100, height: 1000)), CGSize(width: 24, height: 240))
        XCTAssertEqual(MediaThumbnail.displaySize(for: CGSize(width: 50, height: 40)), CGSize(width: 50, height: 40))
        XCTAssertEqual(MediaThumbnail.displaySize(for: .zero), .zero)
    }

    func testLargeImageGetsAQuickLookThumbnail() async throws {
        let url = home.appendingPathComponent("big.png")
        try writePNG(width: 2000, height: 1000, to: url)
        let made = await MediaThumbnail.load(url: url)
        let thumb = try XCTUnwrap(made, "Quick Look makes it out of process")
        XCTAssertLessThanOrEqual(max(thumb.image.width, thumb.image.height), Int(DS.Size.mediaDecodePixels))
        XCTAssertEqual(thumb.size, CGSize(width: 320, height: 160))
    }

    func testUndecodableImageYieldsNoThumbnail() async throws {
        let path = try file("broken.png", bytes: 64)
        let made = await MediaThumbnail.load(url: URL(fileURLWithPath: path))
        XCTAssertNil(made, "falls back to the chip")
    }

    // MARK: path policy (SM3) and click actions (SL1)

    func testNetworkPathsAreRefusedAndProtectedFoldersWaitForAClick() throws {
        for path in ["/net/host/share/a.pdf", "/Network/Servers/x/a.png", "/automount/a.txt", "/home/u/a.txt"] {
            XCTAssertEqual(MediaResolver.resolve(MediaRef(path: path, kind: .file), home: home),
                           .unavailable(reason: MediaResolver.remote), path)
            XCTAssertEqual(MediaResolver.resolve(MediaRef(path: path, kind: .file), userInitiated: true, home: home),
                           .unavailable(reason: MediaResolver.remote), "a click never touches a network path: \(path)")
        }
        let doc = try file("Documents/plan.pdf")
        let ref = MediaRef(path: doc, kind: .pdf)
        XCTAssertEqual(MediaResolver.resolve(ref, home: home), .deferred, "no stat on appear")
        let p = MediaPresentation(ref: ref, resolution: .deferred)
        XCTAssertTrue(p.isEnabled)
        XCTAssertEqual(p.detail, "Click to check")
        guard case .available = MediaResolver.resolve(ref, userInitiated: true, home: home) else {
            return XCTFail("a click checks it")
        }
        XCTAssertEqual(MediaResolver.resolve(MediaRef(path: "/Volumes/USB/a.png", kind: .image), home: home), .deferred)
    }

    func testRiskyTypesAreRevealedNotOpened() throws {
        for ext in ["html", "HTM", "svg", "xml", "xhtml", "doc", "xls", "ppt", "docm", "xlsm", "pptm", "zip", "apk", "ipa",
                    "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "odt", "ods", "odp", "kml", "kmz"] {
            XCTAssertTrue(MediaOpenPolicy.revealsOnly("/tmp/a.\(ext)"), ext)
        }
        for ext in ["pdf", "png", "docx", "csv", "mp3"] { XCTAssertFalse(MediaOpenPolicy.revealsOnly("/tmp/a.\(ext)"), ext) }
        let path = try file("page.html")
        let p = MediaPresentation(ref: MediaRef(path: path, kind: .file),
                                  resolution: MediaResolver.resolve(MediaRef(path: path, kind: .file), home: home))
        XCTAssertEqual(p.help, "Reveal page.html in Finder")
    }

    func testChipTitleShowsHiddenCharacters() {
        let p = MediaPresentation(ref: MediaRef(path: "/tmp/report\u{202E}fdp.exe.pdf", kind: .pdf), resolution: nil)
        XCTAssertEqual(p.title, "report⟨U+202E⟩fdp.exe.pdf")
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

/// `MessageBody` lifts MEDIA tags out of the displayed text for both Group Chat and Bot Chat.
@MainActor
final class MessageBodyMediaTests: XCTestCase {
    func testTextWithoutTagsIsUnchanged() {
        let text = "Hello **there**\n\n```\nlet x = 1\n```\nbye"
        let content = MessageBody.content(text)
        XCTAssertTrue(content.media.isEmpty)
        XCTAssertEqual(content.blocks, MarkdownBlock.parse(text))
    }

    func testTagsAreRemovedFromDisplayedText() {
        let content = MessageBody.content("Here is the chart:\nMEDIA:/tmp/out/chart.png\nand the data MEDIA:/tmp/out/data.csv")
        XCTAssertEqual(content.media.map(\.path), ["/tmp/out/chart.png", "/tmp/out/data.csv"])
        XCTAssertEqual(content.media.map(\.kind), [.image, .file])
        let shown = content.blocks.map(\.plainText).joined(separator: "\n")
        XCTAssertFalse(shown.contains("MEDIA:"), shown)
        XCTAssertTrue(shown.contains("Here is the chart:"), shown)
    }

    func testTagOnlyMessageHasNoEmptyProse() {
        let content = MessageBody.content("MEDIA:/tmp/report.pdf")
        XCTAssertEqual(content.blocks, [])
        XCTAssertEqual(content.media, [MediaRef(path: "/tmp/report.pdf", kind: .pdf)])
    }

    func testTagInsideCodeStaysText() {
        let text = "```\nMEDIA:/tmp/a.png\n```"
        let content = MessageBody.content(text)
        XCTAssertTrue(content.media.isEmpty)
        XCTAssertEqual(content.blocks, [.code(language: nil, "MEDIA:/tmp/a.png")])
    }

    func testPartialTagsRenderAsTextWithoutCrashing() {
        let full = "Saved it: MEDIA:/tmp/out/report.pdf done"
        for end in full.indices {
            let content = MessageBody.content(String(full[..<end]))
            XCTAssertTrue(content.media.allSatisfy { $0.path.hasPrefix("/tmp/") })
        }
        XCTAssertTrue(MessageBody.content("Saved it: MEDIA:/tmp/out/rep").media.isEmpty)
    }

    func testApprovalCommandWrapsLongLinesAndCapsItsHeight() {
        func height(_ text: String) -> CGFloat {
            NSHostingView(rootView: ApprovalCommandView(text: text).frame(width: 400)).fittingSize.height
        }
        let one = height("ls -la")
        XCTAssertLessThan(one, DS.Size.commandMaxHeight, "a short command is not padded to the cap")
        XCTAssertGreaterThan(height(String(repeating: "a", count: 600)), one, "a long line wraps instead of hiding")
        let tall = height(Array(repeating: "rm -rf /tmp/x", count: 200).joined(separator: "\n"))
        XCTAssertEqual(tall, DS.Size.commandMaxHeight, accuracy: 1, "a tall command scrolls inside the cap")
    }

    func testBodyWithAttachmentsLaysOutHeadless() {
        let host = NSHostingView(rootView: MessageBody(text: "See MEDIA:/nonexistent/dir/a.png and MEDIA:/nonexistent/b.pdf")
            .frame(width: 480))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
