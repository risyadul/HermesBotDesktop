import AppKit
import CoreGraphics
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A10 avatar picker, A13 Find Skills and A14 MCP servers in the bot sheets, with the recording fake service:
/// no image is generated, no skill or MCP server installed, no sign-in page opened.
@MainActor
final class BotAvatarSkillsMcpTests: XCTestCase {
    typealias FakeService = BotManagementTests.FakeService
    struct Boom: Error, RedactionSafeError { var description = "boom" }

    private func bot(_ name: String = "alpha") -> Bot { Bot(["name": .string(name)])! }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func png(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(BotLook.png(try XCTUnwrap(ctx.makeImage())))
    }

    private func size(_ data: Data) -> [Int] {
        guard let i = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return [] }
        return [i.width, i.height]
    }

    private func picker(_ s: FakeService, staged: @escaping (BotAvatarEdit) -> Void = { _ in }) -> BotAvatarPickerModel {
        BotAvatarPickerModel(service: s, seed: { .init(name: "alpha", title: "Ada", description: "Researches") },
                             apply: staged, monogram: {})
    }

    // MARK: A10 picker

    func testShapeColourAndRandomizeStageAFace() {
        var staged: [BotAvatarEdit] = []
        let p = picker(FakeService()) { staged.append($0) }
        XCTAssertEqual(p.shape, BotLook.defaultShape(for: "alpha"), "starts on Desktop's default face for the name")
        p.chooseShape("cloud")
        p.chooseColor(BotLook.swatches[2])
        p.chooseColor(nil)
        var picks = [1, 5]
        p.randomIndex = { _ in picks.removeFirst() }
        p.randomize()
        XCTAssertEqual(staged, [.shape("cloud", color: nil), .shape("cloud", color: BotLook.swatches[2]),
                                .shape("cloud", color: nil), .shape(BotLook.shapes[1], color: BotLook.swatches[5])])
        p.showCurrent(shape: "hexagon", color: "#123456")
        XCTAssertEqual(p.shape, "hexagon")
        p.showCurrent(shape: "blobatar:abc", color: nil)
        XCTAssertEqual(p.shape, "hexagon", "a Desktop blob face is not one of the offered shapes")
    }

    func testGenerateProbesFirstAndStagesA256PixelImage() async throws {
        let s = FakeService()
        s.imagenAvailable = false
        var staged: [BotAvatarEdit] = []
        let p = picker(s) { staged.append($0) }
        p.tab = .generate
        try await waitUntil { p.imagen == .unavailable }
        await p.generate()
        XCTAssertTrue(staged.isEmpty, "nothing is generated without a backend")
        s.imagenAvailable = true
        p.tab = .shape
        p.tab = .generate
        try await waitUntil { p.imagen == .available }
        XCTAssertEqual(s.reads.filter { $0 == "probe" }.count, 2, "a 'no' is asked again when the tab is chosen")

        s.generated = .success(try png(512, 300))
        await p.generate()
        guard case .set(let data)? = staged.last else { return XCTFail("\(staged)") }
        XCTAssertEqual(size(data), [256, 256])
        XCTAssertEqual(s.calls.last, .generate(AvatarSources.prompt(custom: "", name: "alpha", title: "Ada", description: "Researches")))
        p.prompt = "a red fox"
        s.generated = .failure(GatewayClient.RPCError(code: 5071, message: "provider down", data: nil))
        await p.generate()
        XCTAssertEqual(p.error, "Could not generate an avatar: provider down")
        XCTAssertEqual(s.calls.last, .generate("a red fox. Avatar for an AI agent: centered, bold flat vector style, solid color background, no text."))
        XCTAssertFalse(p.generating)
    }

    func testPetGalleryIsSearchableAndAPetsFrameIsStagedAsIs() async throws {
        let s = FakeService()
        let pets = (0..<30).map { AvatarSources.Pet(slug: "pet-\($0)", displayName: "Pet \($0)", curated: $0 == 29) }
            + [AvatarSources.Pet(slug: "mochi", displayName: "Mochi", installed: true)]
        s.gallery = .success(pets)
        let frame = try png(96, 104)
        s.thumbData = ["mochi": frame]
        var staged: [BotAvatarEdit] = []
        let p = picker(s) { staged.append($0) }
        p.tab = .pet
        try await waitUntil { p.pets != nil }
        XCTAssertEqual(p.visiblePets.count, BotAvatarPickerModel.petPage)
        XCTAssertEqual(p.visiblePets.prefix(2).map(\.slug), ["mochi", "pet-29"], "installed, then curated first")
        p.showMorePets()
        XCTAssertEqual(p.visiblePets.count, 31)
        p.petQuery = "moch"
        XCTAssertEqual(p.visiblePets.map(\.slug), ["mochi"])
        XCTAssertEqual(p.petLimit, BotAvatarPickerModel.petPage, "a new search starts from the first page")

        await p.pickPet(pets[30])
        XCTAssertEqual(staged, [.set(frame)], "the frame is kept as the backend cropped it (Desktop)")
        XCTAssertEqual(p.selectedPet, "mochi")
        await p.loadThumb(pets[30])
        XCTAssertEqual(s.reads.filter { $0 == "thumb:mochi" }.count, 1, "a thumbnail is fetched once")

        await p.pickPet(pets[0])
        XCTAssertEqual(p.error, "Could not load Pet 0's picture. Try again.")
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(s.reads.filter { $0 == "thumb:pet-0" }.count, 1)
        await p.loadThumb(pets[0])
        XCTAssertEqual(s.reads.filter { $0 == "thumb:pet-0" }.count, 2, "a failure is asked again")

        let s2 = FakeService()
        s2.gallery = .failure(Boom())
        let p2 = picker(s2)
        await p2.loadPets()
        XCTAssertEqual(p2.error, "Could not load the pet gallery: boom")
    }

    // MARK: A10 in the Edit sheet

    func testEditSavesAShapeAsDesktopsLookThenTheFaceRaster() async throws {
        let s = FakeService()
        let m = BotEditorModel(bot: bot(), service: s, hadAvatar: true)
        var saved: [Data?] = []
        m.onAvatarSaved = { saved.append($0) }
        m.picker.chooseShape("drop")
        XCTAssertEqual(m.dirtyFields, [.avatar])
        XCTAssertNotNil(m.avatarPreview)
        await m.save()
        XCTAssertEqual(s.calls.first, .look(BotLook.shapePatch(shape: "drop", color: nil)))
        XCTAssertEqual(BotLook.shapePatch(shape: "drop", color: nil).removing, ["color"], "match the name: no stored colour")
        let face = try XCTUnwrap(s.setAvatarData)
        XCTAssertEqual(size(face), [160, 160])
        XCTAssertEqual(saved, [face])
    }

    func testEditPictureWritesImageKindPhotoAndALookFailureKeepsTheEdit() async throws {
        let s = FakeService()
        s.lookOutcome = .failed
        let m = BotEditorModel(bot: bot(), service: s, hadAvatar: false)
        m.stageAvatar(.set(try png(256, 256)))
        await m.save()
        XCTAssertEqual(s.calls, [.look(BotLook.imagePatch(hasImage: true))])
        XCTAssertEqual(m.errors[.avatar], "Hermes did not save the avatar (another app may have changed this bot). Try again.")
        XCTAssertNotEqual(m.avatar, .unchanged, "Save again retries")
        s.lookOutcome = .unsupported
        await m.save()
        XCTAssertEqual(s.calls.suffix(2).first, .look(BotLook.imagePatch(hasImage: true)))
        XCTAssertNotNil(s.setAvatarData, "an older gateway without ui_meta still gets the picture")
    }

    func testEditPickerStartsFromTheBotsCurrentLook() async throws {
        let s = FakeService()
        s.rosterValue = BotProfileAPI.Roster(["profiles": [["name": "alpha", "ui_meta": ["hermes-bots": ["shape": "pill", "color": "#112233"]]]]])
        let m = BotEditorModel(bot: bot(), service: s, hadAvatar: false)
        m.toggleAvatarPicker()
        try await waitUntil { m.picker.shape == "pill" }
        XCTAssertEqual(m.picker.color, "#112233")
        XCTAssertEqual(m.avatar, .unchanged, "opening the picker is not an edit")
    }

    // MARK: A13

    func testFindSkillsSearchesConfirmsInstallsAndRefreshesTheList() async throws {
        let s = FakeService()
        s.snapshot = .init(skills: [.init(name: "web", enabled: false)])
        let m = BotEditorModel(bot: bot(), service: s, hadAvatar: false)
        m.toggleAdvanced()
        try await waitUntil { m.advancedPhase == .loaded && !m.loadingModels }
        let f = m.skillsFinder
        s.skillResults = .success([.init(name: "pdf-tools", description: "PDFs"), .init(name: "bad name;rm")])
        f.query = "pdf"
        await f.search()
        XCTAssertEqual(f.results?.map(\.name), ["pdf-tools", "bad name;rm"])
        f.requestInstall(.init(name: "bad name;rm"))
        XCTAssertNil(f.confirming)
        XCTAssertEqual(f.error, "bad name;rm cannot be installed from here.")

        f.requestInstall(.init(name: "pdf-tools"))
        XCTAssertEqual(f.confirming?.name, "pdf-tools")
        XCTAssertFalse(s.calls.contains(.installSkill("pdf-tools", "alpha")), "nothing installs before the confirmation")
        f.cancelInstall()
        XCTAssertNil(f.confirming)

        s.snapshot = .init(skills: [.init(name: "web", enabled: true), .init(name: "pdf-tools", enabled: true)])
        f.requestInstall(.init(name: "pdf-tools"))
        await f.confirmInstall()
        XCTAssertTrue(s.calls.contains(.installSkill("pdf-tools", "alpha")))
        XCTAssertEqual(f.installed, ["pdf-tools"])
        XCTAssertEqual(m.skills.map(\.name), ["web", "pdf-tools"], "the new skill joins the list")
        XCTAssertFalse(m.skills[0].enabled, "the user's unsaved toggles are kept")
        XCTAssertFalse(m.dirtyFields.contains(.skills), "an installed skill is already saved")

        s.installError = GatewayClient.RPCError(code: 5031, message: "blocked by the security scan", data: nil)
        f.requestInstall(.init(name: "other"))
        await f.confirmInstall()
        XCTAssertEqual(f.error, "Could not install other: blocked by the security scan")
        XCTAssertNil(f.installing)

        s.skillResults = .failure(Boom())
        await f.search()
        XCTAssertEqual(f.error, "Could not search the skills hub: boom")
    }

    // MARK: A14

    private func mcpEditor(_ s: FakeService) async throws -> BotEditorModel {
        let m = BotEditorModel(bot: bot(), service: s, hadAvatar: false)
        m.toggleAdvanced()
        try await waitUntil { m.advancedPhase == .loaded && m.mcp.phase != .loading && m.mcp.phase != .idle }
        return m
    }

    func testMcpListJoinsTheTogglesAndOlderGatewaysSayWhy() async throws {
        let s = FakeService()
        s.snapshot = .init(mcpServers: [.init(name: "jira", enabled: false, detail: "http")])
        s.mcpList = .success([.init(name: "jira", transport: "http", url: "https://j", auth: "oauth", oauthTokensPresent: false, enabled: false),
                              .init(name: "fs", command: "npx", enabled: true)])
        let m = try await mcpEditor(s)
        XCTAssertEqual(m.mcp.phase, .loaded)
        XCTAssertEqual(m.mcpServers.map(\.name), ["jira", "fs"])
        XCTAssertFalse(m.dirtyFields.contains(.mcp))
        XCTAssertTrue(m.mcp.server("jira")?.canSignIn == true)
        XCTAssertEqual(BotMcpSection.detail(m.mcpServers[0], m.mcp.server("jira")), " · URL · needs sign-in")

        let s2 = FakeService()
        s2.mcpList = .failure(GatewayClient.RPCError(code: -32601, message: "unknown method: mcp.servers.list", data: nil))
        let m2 = try await mcpEditor(s2)
        XCTAssertEqual(m2.mcp.phase, .unsupported)
    }

    func testAddServerValidatesThenAddsAndReloads() async throws {
        let s = FakeService()
        let m = try await mcpEditor(s)
        let mcp = m.mcp
        mcp.toggleAdd()
        mcp.addName = "bad name"
        await mcp.submitAdd()
        XCTAssertEqual(mcp.addError, "Use letters, digits, '.', '-' or '_' for the name (64 at most).")
        mcp.addName = "files"
        mcp.addCommand = "npx"
        mcp.addArguments = "-y \"@scope/server files\" /tmp"
        mcp.addEnvironment = "DEBUG=1"
        s.mcpList = .success([.init(name: "files", command: "npx", enabled: true)])
        await mcp.submitAdd()
        XCTAssertEqual(s.calls.last, .addMcp(.init(name: "files", transport: .command("npx", args: ["-y", "@scope/server files", "/tmp"], env: ["DEBUG": "1"]))))
        XCTAssertFalse(mcp.addOpen)
        XCTAssertEqual(mcp.addName, "")
        XCTAssertEqual(m.mcpServers.map(\.name), ["files"], "the new server joins the toggles")
        XCTAssertFalse(m.dirtyFields.contains(.mcp))

        mcp.toggleAdd()
        mcp.addKind = .url
        mcp.addName = "files"
        mcp.addURL = "https://x"
        await mcp.submitAdd()
        XCTAssertEqual(mcp.addError, "This bot already has a server named files.")
        mcp.addName = "web"
        mcp.addURL = "ftp://x"
        await mcp.submitAdd()
        XCTAssertEqual(mcp.addError, "Enter an http:// or https:// URL.")
        s.mcpError = GatewayClient.RPCError(code: 4090, message: "server 'web' already exists", data: nil)
        mcp.addURL = "https://example.com/mcp"
        await mcp.submitAdd()
        XCTAssertEqual(mcp.addError, "Could not add the server: server 'web' already exists")
        XCTAssertTrue(mcp.addOpen, "the form stays for another try")
    }

    func testApiKeyIsSentOnceClearedAndTested() async throws {
        let s = FakeService()
        s.mcpList = .success([.init(name: "fs", command: "npx", env: ["FS_TOKEN"])])
        let m = try await mcpEditor(s)
        let mcp = m.mcp
        mcp.openKey("fs")
        XCTAssertEqual(mcp.keyServer, "fs")
        await mcp.submitKey()
        XCTAssertEqual(mcp.status["fs"], .init(text: "Enter the key first.", isError: true))
        mcp.keyEnvVar = "FS_TOKEN"
        mcp.keyValue = "  sk-secret-value  "
        await mcp.submitKey()
        XCTAssertEqual(s.lastKey, "sk-secret-value")
        XCTAssertEqual(mcp.keyValue, "", "the secret does not stay in the field")
        XCTAssertNil(mcp.keyServer)
        XCTAssertEqual(Array(s.calls.suffix(2)), [.mcpKey("fs", "FS_TOKEN"), .testMcp("fs")])
        XCTAssertEqual(mcp.status["fs"], .init(text: "Connected · 2 tools.", isError: false))

        s.mcpTestResult = MCPServers.TestResult(ok: false, error: "OAuth authentication required — no token found.", oauthNeeded: true)
        await mcp.test("fs")
        XCTAssertEqual(mcp.status["fs"], .init(text: "Sign in first. OAuth authentication required — no token found.", isError: true))

        s.mcpError = Boom()
        mcp.openKey("fs")
        mcp.keyValue = "k"
        await mcp.submitKey()
        XCTAssertEqual(mcp.status["fs"], .init(text: "Could not save the key: boom", isError: true))
        XCTAssertEqual(mcp.keyValue, "")
    }

    func testSignInSucceedsFailsOrIsCancelled() async throws {
        let s = FakeService()
        s.mcpList = .success([.init(name: "jira", transport: "http", url: "https://j", auth: "oauth")])
        let m = try await mcpEditor(s)
        let mcp = m.mcp
        await mcp.signIn("jira")
        XCTAssertEqual(mcp.status["jira"], .init(text: "Signed in.", isError: false))
        XCTAssertNil(mcp.busy["jira"])

        s.signInError = MCPServers.Failure("OAuth authorization failed")
        await mcp.signIn("jira")
        XCTAssertEqual(mcp.status["jira"], .init(text: "Could not sign in: OAuth authorization failed", isError: true))

        s.signInError = nil
        s.signInWaitsForCancel = true
        let running = Task { await mcp.signIn("jira") }
        try await waitUntil { mcp.signingIn.contains("jira") }
        XCTAssertEqual(mcp.busy["jira"], "Finish signing in in your browser…")
        m.cancel()
        await running.value
        XCTAssertEqual(mcp.status["jira"], .init(text: "Sign-in cancelled.", isError: false), "closing the sheet stops the wait")
        XCTAssertEqual(s.calls.filter { $0 == .signIn("jira") }.count, 3)
    }
}
