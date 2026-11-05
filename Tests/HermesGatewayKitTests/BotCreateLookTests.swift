import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import HermesGatewayKit

/// A7 / A10 wire shapes and Desktop ports (`BotCreate`, `BotLook`, `AvatarSources`) against the scripted fake
/// gateway: no profile is created, no asset uploaded, no image generated.
final class BotCreateLookTests: XCTestCase {
    typealias FakeGateway = BotProfileManagementTests.FakeGateway

    // MARK: names (Desktop's labels.ts)

    func testSlugFollowsDesktopsSlugifyProfileName() {
        XCTAssertEqual(BotCreate.slug("Inbox Triage"), "inbox-triage")
        XCTAssertEqual(BotCreate.slug("Résumé Bot"), "resume-bot", "accents fold to their base letters")
        XCTAssertEqual(BotCreate.slug("小助手"), "u5c0f-u52a9-u624b", "other letters become u<hex> tokens")
        XCTAssertEqual(BotCreate.slug("한글"), "ud55c-uae00")
        XCTAssertEqual(BotCreate.slug("  --Foo__Bar!! "), "foo__bar")
        XCTAssertEqual(BotCreate.slug("🤖"), "")
        let long = String(repeating: "abcdefghi-", count: 8)
        XCTAssertEqual(BotCreate.slug(long), String(String(repeating: "abcdefghi-", count: 6).dropLast()),
                       "cut at the last token boundary inside 64")
        XCTAssertEqual(BotCreate.slug(String(repeating: "a", count: 70)), String(repeating: "a", count: 64))
        XCTAssertLessThanOrEqual(BotCreate.slug(String(repeating: "小", count: 20)).count, 64)
    }

    func testNameRulesIdentityAndDisplayName() {
        XCTAssertTrue(BotCreate.isValidName("a"))
        XCTAssertTrue(BotCreate.isValidName("inbox_triage-2"))
        XCTAssertFalse(BotCreate.isValidName("-a"))
        XCTAssertFalse(BotCreate.isValidName("A"))
        XCTAssertFalse(BotCreate.isValidName(""))
        XCTAssertFalse(BotCreate.isValidName(String(repeating: "a", count: 65)))
        XCTAssertEqual(BotCreate.identity(name: " Inbox Triage ", title: "").title, "", "an ASCII name is no title")
        XCTAssertEqual(BotCreate.identity(name: "Café", title: "").title, "Café")
        XCTAssertEqual(BotCreate.identity(name: "x", title: " Boss ").title, "Boss")
        XCTAssertEqual(BotCreate.displayName(name: "inbox-triage", title: ""), "Inbox Triage")
        XCTAssertEqual(BotCreate.displayName(name: "a_b--c", title: ""), "A B C")
        XCTAssertEqual(BotCreate.displayName(name: "default", title: ""), "Hermes")
        XCTAssertEqual(BotCreate.displayName(name: "x", title: " Ada "), "Ada")
    }

    // MARK: SOUL (Desktop's composeSoul)

    func testComposedSoulMatchesDesktop() {
        let roster = [SoulProtocol.Teammate(name: "alpha", description: "Researches"), .init(name: "scout")]
        let identity = BotCreate.soul(name: "scout", title: "Scout", description: "Finds things", custom: "",
                                      roster: roster, serverInjects: true)
        XCTAssertEqual(identity, """
        # Scout

        **Role:** Scout
        **Mission:** Finds things

        You are Scout, a persistent named agent (profile `scout`) on this machine.
        You keep your own memory, skills, and conversation history across sessions.
        """)
        let bare = BotCreate.soul(name: "scout", title: "", description: "", custom: "", roster: roster, serverInjects: true)
        XCTAssertEqual(bare, "# Scout\n\n\nYou are Scout, a persistent named agent (profile `scout`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions.")
        let withSection = BotCreate.soul(name: "scout", title: "", description: "", custom: "", roster: roster, serverInjects: false)
        XCTAssertEqual(withSection, bare + "\n\n" + SoulProtocol.section(name: "scout", roster: roster))
        XCTAssertTrue(withSection.contains("- `alpha` — Researches"))
        XCTAssertFalse(withSection.contains("- `scout`"), "the bot is not its own teammate")
        let custom = BotCreate.soul(name: "scout", title: "Scout", description: "", custom: "  Be terse.  ", roster: roster, serverInjects: false)
        XCTAssertEqual(custom, "Be terse.\n\n" + SoulProtocol.section(name: "scout", roster: roster))
    }

    // MARK: profiles.create / setup.runtime_check

    func testCreatePayloadIsDesktopsExactly() async throws {
        let gw = FakeGateway()
        gw.on("profiles.create") { _ in ["ok": true, "name": "scout", "path": "/h/profiles/scout", "soul_written": true, "model_set": false] }
        var r = BotCreate.Request(name: "scout", title: "Scout", description: "Finds things", soul: "S")
        let created = try await BotProfileAPI(call: gw.call).create(r)
        XCTAssertEqual(created, .init(name: "scout", path: "/h/profiles/scout", soulWritten: true, modelSet: false))
        XCTAssertEqual(gw.params("profiles.create"), [[
            "name": "scout", "description": "Scout — Finds things", "clone_from": "default", "no_skills": false,
            "share_auth": true, "soul": "S",
        ]])
        r.cloneFrom = nil
        r.title = ""
        r.provider = " openrouter "
        r.model = "a/b"
        XCTAssertEqual(r.params, ["name": "scout", "description": "Finds things", "clone_from": .null, "no_skills": false,
                                  "share_auth": true, "soul": "S", "model": "a/b", "provider": "openrouter"])
        r.model = ""
        XCTAssertNil(r.params["model"], "half a model pin is not sent")
        XCTAssertEqual(BotCreate.Created(["ok": true], requested: "scout"), .init(name: "scout"), "an older reply reads as done")
    }

    func testReadinessAsksForTheNewProfileAndOnlyOkFalseCounts() async {
        let gw = FakeGateway()
        gw.on("setup.runtime_check") { _ in ["ok": false, "provider": "openrouter", "error": "No API key"] }
        let r = await BotCreate.readiness(profile: "scout", call: gw.call, sleep: { _ in })
        XCTAssertEqual(r, .noModel(provider: "openrouter", model: nil, reason: "No API key"))
        XCTAssertEqual(gw.params("setup.runtime_check"), [["profile": "scout"]])

        let busy = FakeGateway()
        busy.on("setup.runtime_check") { _ in throw GatewayClient.RPCError(code: 5097, message: "in progress", data: nil) }
        busy.on("setup.runtime_check") { _ in ["ok": true] }
        let ready = await BotCreate.readiness(profile: "scout", call: busy.call, sleep: { _ in })
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(busy.methods.count, 2)

        let old = FakeGateway()
        old.on("setup.runtime_check") { _ in throw GatewayClient.RPCError(code: -32601, message: "unknown method", data: nil) }
        let unknown = await BotCreate.readiness(profile: "scout", call: old.call, sleep: { _ in })
        XCTAssertEqual(unknown, .unknown, "an older gateway goes ahead, as in Desktop")
    }

    // MARK: BotLook (Desktop's avatar.tsx)

    func testColoursAndDefaultShapesMatchDesktop() {
        XCTAssertEqual(BotLook.profileColor("alpha"), "hsl(38 68% 58%)")
        XCTAssertEqual(BotLook.profileColor("inbox-triage"), "hsl(99 68% 58%)")
        XCTAssertNil(BotLook.profileColor("default"))
        XCTAssertNil(BotLook.profileColor(" "))
        XCTAssertEqual(BotLook.color(nil, name: "default"), BotLook.primaryColor)
        XCTAssertEqual(BotLook.color("", name: "alpha"), "hsl(38 68% 58%)")
        XCTAssertEqual(BotLook.color("#fff", name: "alpha"), "#fff")
        XCTAssertEqual(BotLook.defaultShape(for: "alpha"), "triangle")
        XCTAssertEqual(BotLook.defaultShape(for: "inbox-triage"), "cloud")
        XCTAssertEqual(BotLook.defaultShape(for: "scout"), "circle")
        XCTAssertEqual(BotLook.swatches.count, 12)
        XCTAssertEqual(BotLook.swatches[1], "hsl(30 68% 58%)")
        XCTAssertEqual(BotLook.shapes, ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"])
    }

    func testColourParsingAndDesktopsDarkQuirk() throws {
        let red = try XCTUnwrap(BotLook.rgb("hsl(0 68% 58%)"))
        XCTAssertEqual(red.r, 220.932, accuracy: 0.5)
        XCTAssertEqual(red.g, 75.068, accuracy: 0.5)
        XCTAssertEqual(red.b, 75.068, accuracy: 0.5)
        XCTAssertNotNil(BotLook.rgb("hsl(120, 50%, 50%)"))
        let hex = try XCTUnwrap(BotLook.rgb("#8b5cf6"))
        XCTAssertEqual([hex.r, hex.g, hex.b], [139, 92, 246])
        XCTAssertNotNil(BotLook.rgb("#abc"))
        XCTAssertNil(BotLook.rgb("red"))
        XCTAssertTrue(BotLook.isDark("hsl(60 68% 58%)"), "Desktop reads hsl() as 0, so every swatch gets cream eyes")
        XCTAssertFalse(BotLook.isDark("#ffffff"))
        XCTAssertTrue(BotLook.isDark("#202020"))
    }

    func testFaceRasterIsDesktops160PixelPngWithTheBodyColour() throws {
        for shape in BotLook.shapes {
            let data = try XCTUnwrap(BotLook.facePNG(shape: shape, color: "#ff0000", name: "alpha"), shape)
            XCTAssertTrue(BotLook.isFaceRaster(data), shape)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual([image.width, image.height], [160, 160])
            let px = try pixels(image)
            XCTAssertEqual(px(2, 2).a, 0, "\(shape): transparent corner")
            let body = px(80, 100)
            XCTAssertEqual([body.r, body.g, body.b, body.a], [255, 0, 0, 255], "\(shape): body colour below the eyes")
        }
        XCTAssertGreaterThan(BotLook.ring("circle").count, 40)
        XCTAssertFalse(BotLook.isFaceRaster(try XCTUnwrap(BotLook.png(try XCTUnwrap(BotLook.render(shape: "circle", color: nil, name: "a", edge: 256))))))
        XCTAssertFalse(BotLook.isFaceRaster(Data([0xFF, 0xD8, 0xFF])))
    }

    private func pixels(_ image: CGImage) throws -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let copy = buffer
        return { x, y in
            let i = (y * w + x) * 4  // row 0 is the top row in this buffer
            return (copy[i], copy[i + 1], copy[i + 2], copy[i + 3])
        }
    }

    func testLookPatchesAreDesktopsBotMetaFields() {
        XCTAssertEqual(BotLook.shapePatch(shape: "pill", color: "#123456"),
                       .init(fields: ["shape": "pill", "color": "#123456", "imageKind": "shape", "custom": true]))
        XCTAssertEqual(BotLook.shapePatch(shape: "pill", color: nil),
                       .init(fields: ["shape": "pill", "imageKind": "shape", "custom": true], removing: ["color"]))
        XCTAssertEqual(BotLook.imagePatch(hasImage: true), .init(fields: ["imageKind": "photo", "custom": true]))
        let created = BotLook.createPatch(shape: "drop", color: nil, hasImage: false, title: "Scout",
                                          created: Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(created, .init(fields: ["shape": "drop", "imageKind": "shape", "title": "Scout", "created": 1_700_000_000_500]))
        XCTAssertNil(created.fields["custom"], "Desktop's create does not mark the look custom")
    }

    func testLookSaveMergesRemovesAndRetriesOnConflict() async throws {
        let gw = FakeGateway()
        let row: JSONValue = ["name": "alpha", "ui_meta": ["hermes-bots": ["title": "Ada", "color": "#111111", "chat": "x"]],
                              "ui_meta_revisions": ["hermes-bots": 4]]
        gw.on("profiles.list") { _ in ["profiles": [row]] }
        gw.on("profiles.configure") { _ in ["applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots"]]] }
        gw.on("profiles.configure") { _ in ["applied": ["ui_meta": true]] }
        let outcome = try await BotLook.save(name: "alpha", patch: BotLook.shapePatch(shape: "pill", color: nil), call: gw.call)
        XCTAssertEqual(outcome, .persisted(BotUIMeta()))
        XCTAssertEqual(gw.params("profiles.configure").count, 2, "a conflict is a re-read, not an overwrite")
        XCTAssertEqual(gw.params("profiles.configure").last, [
            "name": "alpha",
            "ui_meta": ["hermes-bots": ["title": "Ada", "shape": "pill", "imageKind": "shape", "custom": true]],
            "ui_meta_expected_revisions": ["hermes-bots": 4],
        ])

        let old = FakeGateway()
        old.on("profiles.list") { _ in ["profiles": [["name": "alpha"]]] }
        old.on("profiles.configure") { _ in ["ok": true] }
        let unsupported = try await BotLook.save(name: "alpha", patch: BotLook.imagePatch(hasImage: true), call: old.call)
        XCTAssertEqual(unsupported, .unsupported)

        let gone = FakeGateway()
        gone.on("profiles.list") { _ in ["profiles": []] }
        let notFound = try await BotLook.save(name: "alpha", patch: .init(), call: gone.call)
        XCTAssertEqual(notFound, .notFound)
    }

    // MARK: AvatarSources (Desktop's avatar-image.ts / pet.tsx)

    func testGeneratePromptsAndReplies() throws {
        XCTAssertEqual(AvatarSources.prompt(custom: "", name: "scout", title: "Scout", description: "Finds things"),
                       "Cute minimal robot avatar for an AI agent named \"Scout — Finds things\". Friendly simple mascot face, bold flat vector style, solid color background, centered, no text.")
        XCTAssertEqual(AvatarSources.prompt(custom: "", name: "scout", title: "", description: ""),
                       "Cute minimal robot avatar for an AI agent named \"scout\". Friendly simple mascot face, bold flat vector style, solid color background, centered, no text.")
        XCTAssertEqual(AvatarSources.prompt(custom: " a fox ", name: "scout", title: "", description: ""),
                       "a fox. Avatar for an AI agent: centered, bold flat vector style, solid color background, no text.")
        XCTAssertEqual(AvatarSources.generateParams(prompt: "p"), ["prompt": "p", "aspect_ratio": "square"])
        XCTAssertEqual(AvatarSources.probeParams, ["probe": true])
        XCTAssertTrue(AvatarSources.available(["available": true]))
        XCTAssertFalse(AvatarSources.available([:]))

        XCTAssertEqual(try AvatarSources.generatedImage(["success": true, "image_data": "data:image/png;base64,AQID"]), Data([1, 2, 3]))
        XCTAssertEqual(try AvatarSources.generatedImage(["success": true, "image": "data:image/webp;base64,AQI="]), Data([1, 2]))
        XCTAssertThrowsError(try AvatarSources.generatedImage(["success": true, "image": "/tmp/out.png"])) {
            XCTAssertEqual(Redaction.describe($0), "Hermes made the image but could not send it to the app.", "a path is never read")
        }
        XCTAssertThrowsError(try AvatarSources.generatedImage(["success": false, "error": "No image generation backend configured"])) {
            XCTAssertEqual(Redaction.describe($0), "No image generation backend configured")
        }
        XCTAssertNil(AvatarSources.decodeDataURL("https://example.com/a.png"))
        XCTAssertNil(AvatarSources.decodeDataURL("data:image/png,raw"))
    }

    func testPetGalleryParsingRankingAndThumbs() {
        let pets = AvatarSources.pets(["pets": [
            ["slug": "a", "displayName": "Alpha"], ["slug": "b", "displayName": "Bravo", "curated": true],
            ["slug": "c", "displayName": "Charlie", "installed": true, "spritesheetUrl": ""], ["displayName": "no slug"],
        ]])
        XCTAssertEqual(pets.map(\.slug), ["a", "b", "c"])
        XCTAssertEqual(AvatarSources.ranked(pets, query: "").map(\.slug), ["c", "b", "a"])
        XCTAssertEqual(AvatarSources.ranked(pets, query: "ALP").map(\.slug), ["a"])
        XCTAssertEqual(AvatarSources.ranked(pets, query: "c").map(\.slug), ["c"], "slug match")
        XCTAssertEqual(AvatarSources.thumbParams(.init(slug: "a", spritesheetURL: "https://cdn/a.webp")), ["slug": "a", "url": "https://cdn/a.webp"])
        // A real 1 × 1 PNG: thumbs must have a readable header within the pixel limit to be decoded.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        XCTAssertEqual(AvatarSources.thumb(["ok": true, "dataUri": .string("data:image/png;base64," + png.base64EncodedString())]), png)
        XCTAssertNil(AvatarSources.thumb(["ok": false, "slug": "a"]))
        XCTAssertNil(AvatarSources.thumb(["ok": true, "dataUri": "data:image/png;base64,AQID"]), "not an image")
    }

    func testGeneratedImagesOfAnyReadableFormatBecome256PixelPngs() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertThrowsError(try ProfileAvatar.normalize(out as Data), "uploads stay PNG/JPEG only")
        let normalized = try ProfileAvatar.normalizeGenerated(out as Data)
        XCTAssertEqual(ProfileAvatar.format(normalized), .png)
        XCTAssertThrowsError(try ProfileAvatar.normalizeGenerated(Data("junk".utf8)))
    }
}
