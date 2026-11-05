import Foundation
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// C2.1: Group Chat attachment chips. Size and kind on the chip, Quick Look on click (reveal-only formats are
/// only revealed), and a plain note when the app's own copy was deleted. Headless: temp files, no windows.
final class RoomAttachmentViewsTests: XCTestCase {
    private var home: URL!
    private var store: URL!
    private let room = "hba-9c63e77525ef"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("RoomAttachmentViewsTests-\(UUID().uuidString)")
        store = home.appendingPathComponent("Room Attachments")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A copy made the way a send makes it (`RoomAttachmentStore.copy`).
    private func copy(_ name: String, bytes: Int = 2048) throws -> URL {
        let original = home.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: original)
        return try RoomAttachmentStore.copy(try RoomAttachments.check(original), room: room, root: store)
    }

    private func resolve(_ ref: MediaRef) -> MediaResolution { MediaResolver.resolve(ref, home: home) }

    func testAvailableCopyShowsKindAndSizeAndPreviewsOnClick() throws {
        let url = try copy("report.pdf", bytes: 2048)
        let ref = RoomAttachments.mediaRefs([url.path])[0]
        let fresh = resolve(ref)
        let p = RoomAttachmentPresentation.presentation(ref: ref, resolution: fresh, ownCopy: true)
        XCTAssertTrue(p.isEnabled)
        XCTAssertEqual(p.detail, "PDF · " + ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        XCTAssertEqual(p.help, "Quick Look report.pdf")
        guard case .quickLook(let target) = RoomAttachmentPresentation.click(ref: ref, fresh: fresh) else {
            return XCTFail("a checked copy opens in Quick Look")
        }
        XCTAssertEqual(target.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
    }

    func testFormatsThatCanRunCodeAreOnlyRevealed() throws {
        let url = try copy("page.html")
        let ref = RoomAttachments.mediaRefs([url.path])[0]
        let fresh = resolve(ref)
        XCTAssertEqual(RoomAttachmentPresentation.presentation(ref: ref, resolution: fresh, ownCopy: true).help,
                       "Reveal page.html in Finder")
        guard case .reveal = RoomAttachmentPresentation.click(ref: ref, fresh: fresh) else {
            return XCTFail("never previewed or opened")
        }
    }

    func testDeletedCopySaysSoInPlainWords() throws {
        let url = try copy("notes.txt")
        try FileManager.default.removeItem(at: url)
        let ref = RoomAttachments.mediaRefs([url.path])[0]
        let fresh = resolve(ref)
        XCTAssertTrue(RoomAttachmentPresentation.isMissing(fresh))
        let p = RoomAttachmentPresentation.presentation(ref: ref, resolution: fresh, ownCopy: true)
        XCTAssertFalse(p.isEnabled)
        XCTAssertEqual(p.detail, RoomAttachmentPresentation.deletedCopy)
        XCTAssertEqual(p.help, RoomAttachmentPresentation.deletedCopy)
        XCTAssertEqual(p.title, "notes.txt", "the chip still names the file")
        XCTAssertEqual(RoomAttachmentPresentation.click(ref: ref, fresh: fresh), .none)
    }

    func testAMissingPathThatIsNotOurCopyKeepsTheGenericReason() {
        let ref = MediaRef(path: home.appendingPathComponent("elsewhere/gone.txt").path, kind: .file)
        let p = RoomAttachmentPresentation.presentation(ref: ref, resolution: resolve(ref), ownCopy: false)
        XCTAssertEqual(p.detail, MediaSafetyError.notFound.errorDescription)
    }

    func testOtherPathsWaitForAClickAndARefusedPathStaysRefused() throws {
        let ref = MediaRef(path: "/Volumes/Share/x.png", kind: .image)
        XCTAssertEqual(RoomAttachmentPresentation.click(ref: ref, fresh: .deferred), .check)
        let deferred = RoomAttachmentPresentation.presentation(ref: ref, resolution: .deferred, ownCopy: false)
        XCTAssertEqual(deferred.detail, "Click to check")
        let refused = MediaRef(path: home.appendingPathComponent(".ssh/id.txt").path, kind: .file)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("k".utf8).write(to: URL(fileURLWithPath: refused.path))
        let fresh = resolve(refused)
        XCTAssertFalse(RoomAttachmentPresentation.presentation(ref: refused, resolution: fresh, ownCopy: false).isEnabled)
        XCTAssertEqual(RoomAttachmentPresentation.click(ref: refused, fresh: fresh), .none)
    }

    func testOnlyTheRoomsOwnCopiesCountAsOwn() throws {
        let url = try copy("a.txt")
        XCTAssertTrue(RoomAttachmentStore.contains(url.path, room: room, root: store))
        XCTAssertFalse(RoomAttachmentStore.contains(url.path, room: "hba-other", root: store))
        XCTAssertFalse(RoomAttachmentStore.contains(home.appendingPathComponent("a.txt").path, room: room, root: store))
    }
}
