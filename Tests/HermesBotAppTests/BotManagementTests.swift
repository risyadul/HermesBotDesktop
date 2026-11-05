import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A8 / A9 / A11 / A12 app behaviour with a recording fake service: nothing reaches Hermes, no profile is
/// created, edited or deleted, no hermes runs and no asset is uploaded.
@MainActor
final class BotManagementTests: XCTestCase {
    final class FakeService: BotProfileService, @unchecked Sendable {
        let lock = NSLock()
        enum Call: Equatable {
            case describe, modelOptions, roster
            case title(String)
            case configure(BotProfileAPI.Changes)
            case setAvatar(Int), clearAvatar, unsetModel, duplicate(String), delete(String)
        }
        private var _calls: [Call] = []
        var calls: [Call] { lock.withLock { _calls } }
        var configureCalls: [BotProfileAPI.Changes] {
            calls.compactMap { if case .configure(let c) = $0 { return c }; return nil }
        }

        var snapshot = BotProfileAPI.Snapshot()
        var describeError: Error?
        var providers: [BotProfileAPI.ModelProvider] = []
        var rosterValue = BotProfileAPI.Roster(["profiles": []])
        var titleOutcome: BotMetaSync.Outcome = .persisted(BotUIMeta())
        var configureResults: [BotProfileAPI.ConfigureResult] = []
        var avatarError: Error?
        var unsetError: Error?
        var duplicateResult: Result<BotDuplicate.Result, Error> = .success(.init(name: "a-2", path: "/p/a-2", warnings: []))
        var deleteError: Error?
        var setAvatarData: Data?

        private func record(_ c: Call) { lock.withLock { _calls.append(c) } }

        func describe(_ name: String) async throws -> BotProfileAPI.Snapshot {
            record(.describe)
            if let describeError { throw describeError }
            return snapshot
        }
        func modelOptions(_ name: String) async throws -> [BotProfileAPI.ModelProvider] { record(.modelOptions); return providers }
        func roster() async throws -> BotProfileAPI.Roster { record(.roster); return rosterValue }
        func saveTitle(_ name: String, _ title: String) async throws -> BotMetaSync.Outcome { record(.title(title)); return titleOutcome }
        func configure(_ name: String, _ changes: BotProfileAPI.Changes) async throws -> BotProfileAPI.ConfigureResult {
            record(.configure(changes))
            return lock.withLock { configureResults.isEmpty ? .init(applied: [:]) : configureResults.removeFirst() }
        }
        func setAvatar(_ name: String, _ image: Data) async throws {
            record(.setAvatar(image.count))
            lock.withLock { setAvatarData = image }
            if let avatarError { throw avatarError }
        }
        func clearAvatar(_ name: String) async throws { record(.clearAvatar); if let avatarError { throw avatarError } }
        func unsetModel(_ name: String) async throws { record(.unsetModel); if let unsetError { throw unsetError } }
        func duplicate(_ name: String, description: String,
                       progress: @escaping @Sendable (BotDuplicate.Step) async -> Void) async throws -> BotDuplicate.Result {
            record(.duplicate(name))
            await progress(.creating("a-2"))
            await progress(.copyingLook)
            return try duplicateResult.get()
        }
        func delete(_ name: String) async throws { record(.delete(name)); if let deleteError { throw deleteError } }
    }

    struct Boom: Error, RedactionSafeError { var description = "boom" }

    private func bot(_ name: String, title: String? = nil, description: String? = nil, isDefault: Bool = false,
                     path: String? = nil) -> Bot {
        var row: [String: JSONValue] = ["name": .string(name), "is_default": .bool(isDefault)]
        if let title { row["ui_meta"] = ["hermes-bots": ["title": .string(title)]] }
        if let description { row["description"] = .string(description) }
        if let path { row["path"] = .string(path) }
        return Bot(.object(row))!
    }

    private final class Closed { var changed: [Bool] = []; var avatars: [Data?] = [] }

    private func editor(_ service: FakeService, bot b: Bot? = nil, hadAvatar: Bool = false) -> (BotEditorModel, Closed) {
        let m = BotEditorModel(bot: b ?? bot("alpha", title: "Ada", description: "Researches"), service: service, hadAvatar: hadAvatar)
        let closed = Closed()
        m.onClose = { closed.changed.append($0) }
        m.onAvatarSaved = { closed.avatars.append($0) }
        return (m, closed)
    }

    private func loadAdvanced(_ m: BotEditorModel) async throws {
        m.toggleAdvanced()
        let end = Date().addingTimeInterval(5)
        while m.advancedPhase == .loading || m.loadingModels {
            if Date() > end { return XCTFail("advanced settings did not load") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func pngFile(width: Int = 300, height: Int = 200) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hba-avatar-\(UUID().uuidString).png")
        try (out as Data).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: A8 basics

    func testNothingChangedSavesNothingAndCloses() async {
        let s = FakeService()
        let (m, closed) = editor(s)
        XCTAssertFalse(m.canSave)
        m.title = " Ada "  // whitespace only is not an edit
        await m.save()
        XCTAssertTrue(s.calls.isEmpty)
        XCTAssertEqual(closed.changed, [false])
    }

    func testOnlyTheChangedFieldIsWritten() async {
        let s = FakeService()
        let (m, closed) = editor(s)
        m.title = "  Ada Lovelace "
        XCTAssertEqual(m.dirtyFields, [.title])
        await m.save()
        XCTAssertEqual(s.calls, [.title("Ada Lovelace")], "description, avatar and settings untouched")
        XCTAssertEqual(closed.changed, [true])
    }

    func testDescriptionGoesThroughProfilesConfigure() async {
        let s = FakeService()
        s.configureResults = [.init(applied: ["description": true])]
        let (m, closed) = editor(s)
        m.description = " Writes the weekly report "
        await m.save()
        var expected = BotProfileAPI.Changes()
        expected.description = "Writes the weekly report"
        XCTAssertEqual(s.calls, [.configure(expected)])
        XCTAssertEqual(closed.changed, [true])
    }

    func testEachFieldReportsItsOwnFailureAndSaveAgainRetriesOnlyThat() async {
        let s = FakeService()
        s.titleOutcome = .failed
        s.configureResults = [.init(applied: ["description": true])]
        let (m, closed) = editor(s)
        m.title = "New"
        m.description = "New description"
        await m.save()
        XCTAssertNotNil(m.errors[.title])
        XCTAssertNil(m.errors[.description])
        XCTAssertTrue(closed.changed.isEmpty, "the sheet stays open while a field failed")
        XCTAssertEqual(m.dirtyFields, [.title], "the saved description is the new baseline")

        s.titleOutcome = .persisted(BotUIMeta())
        await m.save()
        XCTAssertEqual(s.calls.suffix(1), [.title("New")])
        XCTAssertEqual(closed.changed, [true])
    }

    func testTitleOutcomesSayWhy() async {
        for (outcome, words) in [(BotMetaSync.Outcome.unsupported, "Update Hermes"), (.notFound, "no longer lists")] {
            let s = FakeService()
            s.titleOutcome = outcome
            let (m, _) = editor(s)
            m.title = "X"
            await m.save()
            XCTAssertTrue(m.errors[.title]?.contains(words) == true, m.errors[.title] ?? "")
        }
    }

    func testAvatarIsResizedAndUploadedOnlyOnSave() async throws {
        let s = FakeService()
        let (m, closed) = editor(s)
        m.pickAvatar(try pngFile())
        XCTAssertTrue(s.calls.isEmpty, "nothing is uploaded until Save")
        XCTAssertEqual(m.dirtyFields, [.avatar])
        XCTAssertNotNil(m.avatarPreview)
        await m.save()
        let data = try XCTUnwrap(s.setAvatarData)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual([image.width, image.height], [256, 256])
        XCTAssertEqual(closed.avatars, [data], "the new avatar shows at once")
        XCTAssertEqual(closed.changed, [true])
    }

    func testAvatarRemoveClearsTheAssetAndBadFilesAreRefused() async throws {
        let s = FakeService()
        let (m, closed) = editor(s, hadAvatar: true)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("hba-junk-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        m.pickAvatar(junk)
        XCTAssertEqual(m.errors[.avatar], "Choose a PNG or JPEG image.")
        XCTAssertEqual(m.avatar, .unchanged)
        m.removeAvatar()
        XCTAssertFalse(m.showsAvatarImage)
        await m.save()
        XCTAssertEqual(s.calls, [.clearAvatar])
        XCTAssertEqual(closed.avatars, [nil])

        let s2 = FakeService()
        let (m2, _) = editor(s2, hadAvatar: false)
        m2.removeAvatar()
        XCTAssertEqual(m2.avatar, .unchanged, "nothing to remove")
    }

    func testAvatarUploadFailureStaysOnTheAvatarField() async throws {
        let s = FakeService()
        s.avatarError = GatewayClient.RPCError(code: 4069, message: "asset too large", data: nil)
        let (m, closed) = editor(s)
        m.pickAvatar(try pngFile())
        await m.save()
        XCTAssertEqual(m.errors[.avatar], "asset too large")
        XCTAssertTrue(closed.changed.isEmpty)
    }

    // MARK: A9 advanced

    private func advancedService() -> FakeService {
        let s = FakeService()
        s.snapshot = .init(description: "Researches", soul: "# Ada\nBe brief.", provider: "openrouter", model: "a/b",
                           skills: [.init(name: "web", enabled: true), .init(name: "pdf", enabled: false)],
                           toolsets: [.init(name: "terminal", enabled: true), .init(name: "browser", enabled: true)],
                           mcpServers: [.init(name: "jira", enabled: false)])
        s.providers = [.init(slug: "openrouter", name: "OpenRouter", aliases: ["or"], models: ["a/b", "c/d"]),
                       .init(slug: "anthropic", models: ["claude-x"])]
        s.rosterValue = BotProfileAPI.Roster(["profiles": [["name": "alpha"], ["name": "bravo", "description": "Codes"]]])
        return s
    }

    func testAdvancedLoadsDescribeRosterAndModelOptionsThenSendsOnlyDirtySections() async throws {
        let s = advancedService()
        s.configureResults = [.init(applied: ["skills": true, "toolsets": true, "mcp_servers": true])]
        let (m, closed) = editor(s)
        try await loadAdvanced(m)
        XCTAssertEqual(m.advancedPhase, .loaded)
        XCTAssertEqual(s.calls.count, 3)
        for c in [FakeService.Call.describe, .roster, .modelOptions] { XCTAssertTrue(s.calls.contains(c)) }
        XCTAssertEqual(m.providerTag, "openrouter")
        XCTAssertTrue(m.dirtyFields.isEmpty, "loading is not an edit")
        m.setSkill("pdf", true)
        m.setSkill("web", false)
        m.setToolset("browser", false)
        m.setMcp("jira", true)
        await m.save()
        var expected = BotProfileAPI.Changes()
        expected.disabledSkills = ["web"]
        expected.enabledToolsets = ["terminal"]
        expected.enabledMcpServers = ["jira"]
        XCTAssertEqual(s.configureCalls, [expected])
        XCTAssertEqual(closed.changed, [true])
    }

    func testTogglingBackIsNotAnEdit() async throws {
        let s = advancedService()
        let (m, _) = editor(s)
        try await loadAdvanced(m)
        m.setSkill("pdf", true)
        m.setSkill("pdf", false)
        XCTAssertTrue(m.dirtyFields.isEmpty)
    }

    func testModelPickerFollowsDesktop() async throws {
        let s = advancedService()
        let (m, _) = editor(s)
        try await loadAdvanced(m)
        XCTAssertFalse(m.usesFreeTextModel)
        m.chooseProvider("anthropic")
        XCTAssertEqual([m.provider, m.model], ["anthropic", "claude-x"], "a provider without the model takes its first")
        m.model = "c/d"
        m.chooseProvider("openrouter")
        XCTAssertEqual(m.model, "c/d", "a provider that offers the model keeps it")
        m.chooseProvider(BotEditorModel.inheritTag)
        XCTAssertEqual([m.provider, m.model], ["", ""])
        XCTAssertEqual(m.providerTag, BotEditorModel.inheritTag)
        m.chooseProvider(BotEditorModel.manualTag)
        XCTAssertTrue(m.usesFreeTextModel)
        m.manualModelEntry = nil
        m.provider = "custom-gw"
        XCTAssertTrue(m.usesFreeTextModel, "a provider the catalog does not know is typed in")
        m.provider = "OR"
        XCTAssertEqual(m.activeProvider?.slug, "openrouter", "aliases match")
    }

    func testPinnedModelIsSentAndExpensiveModelWaitsForConfirmation() async throws {
        let s = advancedService()
        s.configureResults = [.init(applied: [:], confirmMessage: "claude-x costs $$"), .init(applied: ["model": true])]
        let (m, closed) = editor(s)
        try await loadAdvanced(m)
        m.chooseProvider("anthropic")
        await m.save()
        XCTAssertEqual(m.pendingConfirm, .init(message: "claude-x costs $$", provider: "anthropic", model: "claude-x"))
        XCTAssertTrue(closed.changed.isEmpty, "nothing was written: the sheet waits for the answer")
        XCTAssertFalse(m.canSave)
        await m.confirmModel()
        var first = BotProfileAPI.Changes()
        first.model = ("anthropic", "claude-x")
        var confirmed = first
        confirmed.confirmExpensiveModel = true
        XCTAssertEqual(s.configureCalls, [first, confirmed], "the confirmed resend carries only the model section")
        XCTAssertEqual(closed.changed, [true])
    }

    func testDecliningTheExpensiveModelKeepsTheSheetOpen() async throws {
        let s = advancedService()
        s.configureResults = [.init(applied: [:], confirmMessage: "pricey")]
        let (m, closed) = editor(s)
        try await loadAdvanced(m)
        m.chooseProvider("anthropic")
        await m.save()
        m.declineModel()
        XCTAssertNil(m.pendingConfirm)
        XCTAssertEqual(m.errors[.model], "Model not changed.")
        XCTAssertTrue(closed.changed.isEmpty)
        XCTAssertEqual(s.configureCalls.count, 1)
    }

    func testInheritRunsConfigUnsetAndAHalfPinIsRefused() async throws {
        let s = advancedService()
        let (m, closed) = editor(s)
        try await loadAdvanced(m)
        m.provider = "openrouter"; m.model = ""
        await m.save()
        XCTAssertEqual(m.errors[.model], "Choose both a provider and a model, or Inherit.")
        XCTAssertTrue(s.configureCalls.isEmpty)
        m.chooseProvider(BotEditorModel.inheritTag)
        await m.save()
        XCTAssertEqual(s.calls.filter { $0 == .unsetModel }.count, 1)
        XCTAssertTrue(s.configureCalls.isEmpty, "Inherit is not a profiles.configure model pin")
        XCTAssertEqual(closed.changed, [true])

        let failing = advancedService()
        failing.unsetError = Boom()
        let (m2, _) = editor(failing)
        try await loadAdvanced(m2)
        m2.chooseProvider(BotEditorModel.inheritTag)
        await m2.save()
        XCTAssertEqual(m2.errors[.model], "Could not switch to the inherited model: boom")
    }

    func testEditedSoulKeepsTheMessagingProtocolSection() async throws {
        let s = advancedService()
        s.configureResults = [.init(applied: ["soul": true])]
        let (m, _) = editor(s)
        try await loadAdvanced(m)
        m.soul = "# Ada\nBe very brief."
        await m.save()
        let sent = try XCTUnwrap(s.configureCalls.first?.soul)
        let roster = [SoulProtocol.Teammate(name: "alpha"), .init(name: "bravo", description: "Codes")]
        XCTAssertEqual(sent, "# Ada\nBe very brief.\n\n" + SoulProtocol.section(name: "alpha", roster: roster))
        XCTAssertEqual(m.soul, sent, "the editor shows what was saved")

        let injected = advancedService()
        injected.rosterValue = BotProfileAPI.Roster(["profiles": [["name": "alpha"]], "bot_mode_protocol": true])
        injected.configureResults = [.init(applied: ["soul": true])]
        let (m2, _) = editor(injected)
        try await loadAdvanced(m2)
        m2.soul = "Mine only"
        await m2.save()
        XCTAssertEqual(injected.configureCalls.first?.soul, "Mine only")
    }

    func testSectionThatDidNotApplyIsReportedOnItsOwnField() async throws {
        let s = advancedService()
        s.configureResults = [.init(applied: ["soul": true, "skills": false])]
        let (m, closed) = editor(s)
        try await loadAdvanced(m)
        m.soul = "## Messaging other agents\nkept"
        m.setSkill("pdf", true)
        await m.save()
        XCTAssertEqual(m.errors[.skills], "Hermes did not save the skills.")
        XCTAssertNil(m.errors[.soul])
        XCTAssertEqual(m.dirtyFields, [.skills])
        XCTAssertTrue(closed.changed.isEmpty)
        m.cancel()
        XCTAssertEqual(closed.changed, [true], "Cancel after a partial save still refreshes the roster")
    }

    func testAdvancedLoadFailureCanBeRetried() async throws {
        let s = advancedService()
        s.describeError = GatewayClient.RPCError(code: 4064, message: "profile 'alpha' not found", data: nil)
        let (m, _) = editor(s)
        try await loadAdvanced(m)
        XCTAssertEqual(m.advancedPhase, .failed("profile 'alpha' not found"))
        s.describeError = nil
        m.loadAdvanced()
        let end = Date().addingTimeInterval(5)
        while m.advancedPhase != .loaded && Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(m.advancedPhase, .loaded)
    }

    func testModelCatalogFailureFallsBackToFreeText() async throws {
        let s = advancedService()
        s.providers = []
        let (m, _) = editor(s)
        try await loadAdvanced(m)
        XCTAssertTrue(m.usesFreeTextModel)
    }

    // MARK: A11 duplicate

    func testDuplicateShowsProgressThenTheNewBot() async {
        let s = FakeService()
        let m = BotDuplicateModel(source: bot("a", description: "Desc"), service: s)
        var created: [String] = []
        m.onCreated = { created.append($0.name) }
        await m.start()
        XCTAssertEqual(s.calls, [.duplicate("a")])
        XCTAssertEqual(m.phase, .done(.init(name: "a-2", path: "/p/a-2", warnings: [])))
        XCTAssertEqual(created, ["a-2"])
        await m.start()
        XCTAssertEqual(s.calls.count, 1, "runs once")
        XCTAssertEqual(BotDuplicateModel.text(.creating("a-2")), "Creating @a-2…")
    }

    func testDuplicateFailureSaysWhy() async {
        let s = FakeService()
        s.duplicateResult = .failure(GatewayClient.RPCError(code: 4062, message: "Profile 'a-2' already exists", data: nil))
        let m = BotDuplicateModel(source: bot("a"), service: s)
        await m.start()
        XCTAssertEqual(m.phase, .failed("Profile 'a-2' already exists"))
        XCTAssertFalse(m.isRunning)
    }

    // MARK: A12 delete

    func testDefaultProfileIsNeverDeletable() async {
        XCTAssertFalse(BotDeleteModel.canDelete(bot("default", isDefault: true)))
        XCTAssertFalse(BotDeleteModel.canDelete(bot("default")))
        XCTAssertFalse(BotDeleteModel.canDelete(bot("main", isDefault: true)))
        XCTAssertTrue(BotDeleteModel.canDelete(bot("alpha")))
        XCTAssertEqual(BotRowMenu.manageItems(bot("default", isDefault: true)), [.edit, .duplicate])
        XCTAssertEqual(BotRowMenu.manageItems(bot("alpha")), [.edit, .duplicate, .delete])
        XCTAssertEqual(BotRowMenu.title(.delete), "Delete…")
        let s = FakeService()
        let m = BotDeleteModel(bot: bot("default", isDefault: true), service: s)
        await m.confirm()
        XCTAssertTrue(s.calls.isEmpty)
    }

    func testDeleteNamesThePathRunsOnlyOnConfirmAndReportsFailure() async {
        let s = FakeService()
        let m = BotDeleteModel(bot: bot("alpha", path: "/Users/x/.hermes/profiles/alpha"), service: s)
        XCTAssertEqual(m.profilePath, "/Users/x/.hermes/profiles/alpha")
        XCTAssertTrue(s.calls.isEmpty, "nothing runs before the user confirms")
        var deleted: [String] = []
        var released: [String] = []
        var closed = 0
        m.beforeDelete = { released.append($0) }
        m.onDeleted = { deleted.append($0) }
        m.onClose = { closed += 1 }
        s.deleteError = ProfileCLI.Failure(description: "Profile is in use")
        await m.confirm()
        XCTAssertEqual(m.error, "Profile is in use")
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(deleted.isEmpty)
        s.deleteError = nil
        await m.confirm()
        XCTAssertEqual(s.calls, [.delete("alpha"), .delete("alpha")])
        XCTAssertEqual(deleted, ["alpha"])
        XCTAssertEqual(released, ["alpha", "alpha"], "the app lets go of the bot before each attempt")
        XCTAssertEqual(closed, 1)
        XCTAssertNil(m.error)
    }

    func testDeletedBotLeavesSelectionChatsAndMeta() {
        let app = AppModel()
        let alpha = bot("alpha"), bravo = bot("bravo")
        app.bots = [alpha, bravo]
        app.botMeta.load(app.bots)
        app.selection = .bot("alpha")
        let chat = app.chat(for: alpha)
        _ = app.chat(for: bravo)
        app.botDeleted("alpha")
        XCTAssertNil(app.selection)
        XCTAssertNil(app.chats["alpha"])
        XCTAssertNotNil(app.chats["bravo"])
        XCTAssertTrue(chat.closed)
        XCTAssertNil(app.botMeta.meta["alpha"])
        XCTAssertEqual(app.bots.map(\.name), ["bravo"])
    }

    func testReleaseBeforeDeleteLeavesThePaneAndDetachesTheChat() {
        let app = AppModel()
        let alpha = bot("alpha")
        app.bots = [alpha]
        app.selection = .bot("alpha")
        let chat = app.chat(for: alpha)
        app.releaseBot("alpha")
        XCTAssertNil(app.selection)
        XCTAssertTrue(chat.closed)
        XCTAssertEqual(app.bots.map(\.name), ["alpha"], "the roster row stays until the delete succeeded")
        XCTAssertFalse(app.chat(for: alpha) === chat, "a failed delete leaves a fresh chat model for the next open")
    }

    func testRefreshedRosterUpdatesOpenChatsAndKeepsSelection() {
        let app = AppModel()
        let alpha = bot("alpha", title: "Old")
        app.bots = [alpha]
        app.botMeta.load(app.bots)
        app.selection = .bot("alpha")
        let chat = app.chat(for: alpha)
        app.applyRoster([bot("alpha", title: "New"), bot("alpha-2")])
        XCTAssertEqual(chat.bot.title, "New", "the open Bot Chat shows the edited title")
        XCTAssertEqual(app.selection, .bot("alpha"))
        XCTAssertNotNil(app.botMeta.meta["alpha-2"])
    }

    func testSheetsOpenOneAtATime() {
        let app = AppModel()
        let s = FakeService()
        app.presentEdit(bot("alpha"), service: s)
        guard case .edit? = app.botSheet else { return XCTFail("no edit sheet") }
        app.presentDelete(bot("bravo"), service: s)
        guard case .edit? = app.botSheet else { return XCTFail("a second sheet replaced the first") }
        app.botSheet = nil
        app.presentDelete(bot("default", isDefault: true), service: s)
        XCTAssertNil(app.botSheet, "no delete sheet for the default profile")
        app.presentDuplicate(bot("alpha"), service: s)
        guard case .duplicate? = app.botSheet else { return XCTFail("no duplicate sheet") }
    }

    /// Live UI test 2026-11-06 (round 2): a bot with no Bot Mode title showed an empty Title field with no
    /// placeholder, because `profiles.list` sends `display_name: ""`.
    func testTitlePlaceholderIsTheNameTheBotShowsNow() {
        let s = FakeService()
        let empty = BotEditorModel(bot: Bot(["name": "generalist", "display_name": ""])!, service: s, hadAvatar: false)
        XCTAssertEqual(empty.title, "", "no title set: the field starts empty")
        XCTAssertEqual(empty.titlePlaceholder, "generalist", "an empty display_name falls back to the name")
        XCTAssertEqual(BotEditorModel.titlePlaceholder(Bot(["name": "alpha"])!), "alpha", "no display_name at all")
        XCTAssertEqual(BotEditorModel.titlePlaceholder(Bot(["name": "alpha", "display_name": "  "])!), "alpha")
        XCTAssertEqual(BotEditorModel.titlePlaceholder(Bot(["name": "alpha", "display_name": "Alpha Bot"])!), "Alpha Bot")
    }
}
