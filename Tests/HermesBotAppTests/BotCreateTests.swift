import AppKit
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// A7 New Bot with the recording fake service: no profile is created, no asset uploaded, no image generated.
@MainActor
final class BotCreateTests: XCTestCase {
    typealias FakeService = BotManagementTests.FakeService

    private func bot(_ name: String) -> Bot { Bot(["name": .string(name)])! }

    private final class Seen { var created: [(String, Data?)] = []; var opened: [(String, Bool)] = []; var closed = 0; var edited: [String] = [] }

    private func sheet(_ s: FakeService, roster: [String] = ["default", "alpha"]) -> (BotCreateModel, Seen) {
        let m = BotCreateModel(roster: roster.map(bot), service: s)
        let seen = Seen()
        m.onCreated = { seen.created.append(($0, $1)) }
        m.onOpen = { seen.opened.append(($0, $1)) }
        m.onClose = { seen.closed += 1 }
        m.onEditModel = { seen.edited.append($0) }
        return (m, seen)
    }

    private func service(roster names: [String] = ["default", "alpha"], injects: Bool = true) -> FakeService {
        let s = FakeService()
        s.rosterValue = BotProfileAPI.Roster(["profiles": .array(names.map { ["name": .string($0)] }),
                                              "bot_mode_protocol": .bool(injects)])
        s.createResult = .success(.init(name: "inbox-triage", path: "/h/profiles/inbox-triage"))
        return s
    }

    // MARK: name

    func testNameBecomesTheSlugAndTakenOrInvalidNamesCannotBeCreated() {
        let (m, _) = sheet(FakeService())
        XCTAssertFalse(m.canCreate)
        XCTAssertNil(m.nameProblem, "an empty name says nothing yet")
        m.name = "Inbox Triage"
        XCTAssertEqual(m.slug, "inbox-triage")
        XCTAssertTrue(m.canCreate)
        m.name = "Alpha"
        XCTAssertEqual(m.nameProblem, "A bot named @alpha already exists.")
        XCTAssertFalse(m.canCreate)
        m.name = "!!!"
        XCTAssertEqual(m.nameProblem, "Use letters or digits for the name.")
        m.name = "小助手"
        XCTAssertEqual(m.slug, "u5c0f-u52a9-u624b")
        XCTAssertEqual(m.botTitle, "小助手", "a non-ASCII name stays the title")
    }

    // MARK: create

    func testCreateSendsDesktopsPayloadThenLookFaceAndReadinessThenOpensWithTheIntro() async throws {
        let s = service()
        let (m, seen) = sheet(s)
        m.name = "inbox-triage"
        m.title = "Inbox Triage"
        m.description = " Sorts mail "
        await m.create()

        let r = try XCTUnwrap(s.lastCreate)
        XCTAssertEqual(r.params, [
            "name": "inbox-triage", "description": "Inbox Triage — Sorts mail", "clone_from": "default",
            "no_skills": false, "share_auth": true,
            "soul": .string(BotCreate.soul(name: "inbox-triage", title: "Inbox Triage", description: "Sorts mail", custom: "",
                                           roster: [], serverInjects: true)),
        ])
        XCTAssertTrue(r.soul.hasPrefix("# Inbox Triage\n\n**Role:** Inbox Triage\n**Mission:** Sorts mail"))

        let look = try XCTUnwrap(s.looks.first)
        XCTAssertEqual(look.fields["shape"], .string(BotLook.defaultShape(for: "inbox-triage")), "Desktop's default face")
        XCTAssertEqual(look.fields["imageKind"], "shape")
        XCTAssertEqual(look.fields["title"], "Inbox Triage")
        XCTAssertNotNil(look.fields["created"]?.double)
        XCTAssertNil(look.fields["color"], "no colour picked: the name's hue")

        let face = try XCTUnwrap(s.setAvatarData)
        XCTAssertTrue(BotLook.isFaceRaster(face), "the face goes up as Desktop's 160 px raster")
        XCTAssertEqual(s.calls.filter { if case .setAvatar = $0 { return false }; if case .look = $0 { return false }; if case .create = $0 { return false }; return true },
                       [.roster, .readiness("inbox-triage")])
        XCTAssertEqual(seen.created.map(\.0), ["inbox-triage"])
        XCTAssertEqual(seen.created.first?.1, face, "the app shows the new face at once")
        XCTAssertEqual(seen.opened.map(\.0), ["inbox-triage"])
        XCTAssertEqual(seen.opened.first?.1, true, "Say hello is on by default (Desktop)")
    }

    func testOptionsReachThePayload() async throws {
        let s = service(injects: false)
        let (m, seen) = sheet(s)
        m.name = "scout"
        m.cloneFrom = nil
        m.skipBundledSkills = true
        m.shareKeys = false
        m.provider = "openrouter"
        m.model = "a/b"
        m.soul = "Be brief."
        m.sayHello = false
        s.createResult = .success(.init(name: "scout"))
        await m.create()
        let p = try XCTUnwrap(s.lastCreate?.params)
        XCTAssertEqual(p["clone_from"], .null, "fresh profile")
        XCTAssertEqual(p["no_skills"], true)
        XCTAssertEqual(p["share_auth"], false)
        XCTAssertEqual(p["model"], "a/b")
        XCTAssertEqual(p["provider"], "openrouter")
        let soul = try XCTUnwrap(p["soul"]?.string)
        XCTAssertTrue(soul.hasPrefix("Be brief.\n\n## Messaging other agents"), "a custom SOUL keeps the messaging section")
        XCTAssertTrue(soul.contains("- `alpha`"), "the live roster is the teammate list")
        XCTAssertEqual(seen.opened.first?.1, false, "no intro when Say hello is off")
    }

    func testSkipBundledSkillsIsOnlySentForAFreshProfile() async throws {
        let s = service()
        let (m, _) = sheet(s)
        m.name = "scout"
        m.skipBundledSkills = true
        await m.create()
        XCTAssertEqual(s.lastCreate?.params["no_skills"], false, "Hermes refuses no_skills with a clone")
    }

    func testHalfAModelIsRefusedBeforeAnythingIsCreated() async {
        let s = service()
        let (m, _) = sheet(s)
        m.name = "scout"
        m.provider = "openrouter"
        await m.create()
        XCTAssertEqual(m.error, "Choose both a provider and a model, or Inherit.")
        XCTAssertTrue(s.calls.isEmpty)
        XCTAssertEqual(m.phase, .editing)
    }

    func testANameTakenSinceTheSheetOpenedIsCaughtByTheLiveRoster() async {
        let s = service(roster: ["default", "alpha", "scout"])
        let (m, seen) = sheet(s)
        m.name = "scout"
        await m.create()
        XCTAssertEqual(m.error, "A bot named @scout already exists.")
        XCTAssertNil(s.lastCreate)
        XCTAssertTrue(seen.created.isEmpty)
    }

    func testCreateFailureLeavesTheSheetEditableAndSaysWhy() async {
        let s = service()
        s.createResult = .failure(GatewayClient.RPCError(code: 4062, message: "Profile 'scout' already exists", data: nil))
        let (m, seen) = sheet(s)
        m.name = "scout"
        await m.create()
        XCTAssertEqual(m.phase, .editing)
        XCTAssertEqual(m.error, "Could not create the bot: Profile 'scout' already exists")
        XCTAssertTrue(s.looks.isEmpty, "nothing else runs")
        XCTAssertTrue(seen.created.isEmpty)
    }

    func testAProfileThatExistsDespiteAnErrorIsReportedNotLeftBehind() async {
        let s = service()
        s.createResult = .failure(GatewayClient.ClientError.timeout("profiles.create"))
        s.rosterAfterCreateFailure = BotProfileAPI.Roster(["profiles": [["name": "default"], ["name": "scout"]]])
        let (m, seen) = sheet(s)
        m.name = "scout"
        await m.create()
        guard case .created(let o) = m.phase else { return XCTFail("\(m.phase)") }
        XCTAssertEqual(o.name, "scout")
        XCTAssertTrue(o.warnings.first?.hasPrefix("Hermes reported an error, but @scout was created") == true, "\(o.warnings)")
        XCTAssertEqual(seen.created.map(\.0), ["scout"], "the roster is refreshed")
        XCTAssertTrue(seen.opened.isEmpty, "the user reads what happened first")
        m.openCreated()
        XCTAssertEqual(seen.opened.first?.0, "scout")
    }

    func testLookAndAvatarFailuresAreWarningsOnTheCreatedBot() async {
        let s = service()
        s.lookOutcome = .failed
        s.avatarError = Boom()
        let (m, seen) = sheet(s)
        m.name = "inbox-triage"
        await m.create()
        guard case .created(let o) = m.phase else { return XCTFail("\(m.phase)") }
        XCTAssertEqual(o.warnings, ["The title and look were not saved. Set them with Edit….", "The avatar was not saved: boom"])
        XCTAssertEqual(seen.created.first?.1, nil, "no picture to show")
    }

    func testNeedsAModelSkipsTheIntroAndOffersSetUp() async {
        let s = service()
        s.readinessValue = .noModel(provider: "openrouter", model: nil, reason: "No API key for openrouter")
        let (m, seen) = sheet(s)
        m.name = "inbox-triage"
        await m.create()
        guard case .created(let o) = m.phase else { return XCTFail("\(m.phase)") }
        XCTAssertEqual(o.needsModel, "No API key for openrouter")
        XCTAssertTrue(seen.opened.isEmpty)
        m.openCreated()
        XCTAssertEqual(seen.opened.first?.1, false, "no intro for a bot that cannot reply")
        m.editModel()
        XCTAssertEqual(seen.edited, ["inbox-triage"])
    }

    func testPickedPictureAndShapeAreWhatCreateSaves() async throws {
        let s = service()
        let (m, seen) = sheet(s)
        m.name = "inbox-triage"
        m.picker.chooseShape("hexagon")
        m.picker.chooseColor(BotLook.swatches[3])
        XCTAssertEqual(m.effectiveAvatar, .shape("hexagon", color: BotLook.swatches[3]))
        await m.create()
        XCTAssertEqual(s.looks.first?.fields["shape"], "hexagon")
        XCTAssertEqual(s.looks.first?.fields["color"], .string(BotLook.swatches[3]))
        XCTAssertEqual(s.setAvatarData, BotLook.facePNG(shape: "hexagon", color: BotLook.swatches[3], name: "inbox-triage"))
        XCTAssertEqual(seen.opened.count, 1)

        let s2 = service()
        let (m2, _) = sheet(s2)
        m2.name = "inbox-triage"
        m2.picker.monogram()
        await m2.create()
        XCTAssertNil(s2.looks.first?.fields["shape"], "Monogram: no face is written")
        XCTAssertNil(s2.setAvatarData, "and no picture uploaded")
    }

    // MARK: app wiring

    func testNewBotSheetOpensOnceAndTheIntroIsSentWhenTheChatIsReady() async throws {
        let app = AppModel()
        app.presentCreate(service: FakeService())
        guard case .create? = app.botSheet else { return XCTFail("no New Bot sheet") }
        app.presentCreate(service: FakeService())
        guard case .create? = app.botSheet else { return XCTFail("replaced") }
        app.botSheet = nil

        let scout = bot("scout")
        app.bots = [scout]
        let link = FakeChatLink()
        let chat = ChatModel(bot: scout, opener: { _ in link })
        chat.log = { _ in }
        app.chats["scout"] = chat
        app.openNewBot("scout", kickoff: true, wait: 5)
        XCTAssertEqual(app.selection, .bot("scout"))
        let end = Date().addingTimeInterval(5)
        while !link.calls.contains(where: { $0.hasPrefix("send:") }) && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(link.calls.filter { $0.hasPrefix("send:") }, ["send:\(BotCreate.kickoff)|"])
        XCTAssertEqual(chat.lines.first?.text, BotCreate.kickoff)
    }

    func testNoIntroIntoAChatThatAlreadyHasMessages() async throws {
        let app = AppModel()
        let scout = bot("scout")
        app.bots = [scout]
        let link = FakeChatLink(history: [ChatHistoryMessage(role: .user, text: "hi")])
        let chat = ChatModel(bot: scout, opener: { _ in link })
        chat.log = { _ in }
        app.chats["scout"] = chat
        app.openNewBot("scout", kickoff: true, wait: 5)
        let end = Date().addingTimeInterval(2)
        while !chat.isReady && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("send:") })
    }

    struct Boom: Error, RedactionSafeError { var description = "boom" }
}
