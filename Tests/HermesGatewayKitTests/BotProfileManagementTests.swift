import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HermesGatewayKit

/// A8 / A9 / A11 / A12 wire shapes and rules (`BotProfileAPI`, `SoulProtocol`, `ProfileAvatar`, `ProfileCLI`,
/// `BotDuplicate`) against a scripted fake gateway and `FakeCommandRunner`: no real profile is created,
/// edited or deleted, no hermes runs, no asset is uploaded.
final class BotProfileManagementTests: XCTestCase {
    /// Records every call; answers per method from a script (a closure may throw).
    final class FakeGateway: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(String, JSONValue)] = []
        var answers: [String: [@Sendable (JSONValue) throws -> JSONValue]] = [:]

        func on(_ method: String, _ answer: @escaping @Sendable (JSONValue) throws -> JSONValue) {
            lock.withLock { answers[method, default: []].append(answer) }
        }

        var call: BotMetaSync.Call {
            { method, params in
                let answer = try self.lock.withLock { () -> @Sendable (JSONValue) throws -> JSONValue in
                    self.calls.append((method, params))
                    guard var list = self.answers[method], !list.isEmpty else {
                        throw GatewayClient.ClientError.badFrame("unexpected \(method)")
                    }
                    let first = list.count > 1 ? list.removeFirst() : list[0]
                    self.answers[method] = list
                    return first
                }
                return try answer(params)
            }
        }

        func params(_ method: String) -> [JSONValue] { lock.withLock { calls.filter { $0.0 == method }.map(\.1) } }
        var methods: [String] { lock.withLock { calls.map(\.0) } }
    }

    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    // MARK: profiles.describe / model.options / configure

    func testDescribeParsesEveryEditorSection() async throws {
        let gw = FakeGateway()
        gw.on("profiles.describe") { _ in
            ["name": "alpha", "description": "Researches", "soul": "# Alpha",
             "model": ["provider": "openrouter", "default": "a/b"],
             "skills": [["name": "web", "enabled": true], ["name": "pdf", "enabled": false], ["enabled": true]],
             "toolsets": [["name": "terminal", "label": "Terminal", "description": "Run commands", "tool_count": 3, "enabled": true]],
             "toolsets_pinned": false,
             "mcp_servers": [["name": "jira", "enabled": false, "transport": "http"], ["name": "fs", "transport": "stdio"]]]
        }
        let s = try await BotProfileAPI(call: gw.call).describe("alpha")
        XCTAssertEqual(gw.params("profiles.describe"), [["name": "alpha"]])
        XCTAssertEqual(s.description, "Researches")
        XCTAssertEqual(s.soul, "# Alpha")
        XCTAssertEqual(s.provider, "openrouter")
        XCTAssertEqual(s.model, "a/b")
        XCTAssertEqual(s.skills.map(\.name), ["web", "pdf"], "a row without a name is dropped")
        XCTAssertEqual(s.skills.map(\.enabled), [true, false])
        XCTAssertEqual(s.toolsets.first?.label, "Terminal")
        XCTAssertEqual(s.toolsets.first?.toolCount, 3)
        XCTAssertEqual(s.mcpServers.map(\.enabled), [false, true], "an MCP row without `enabled` reads as on (Desktop)")
        XCTAssertEqual(s.mcpServers.first?.detail, "http")
        XCTAssertEqual(BotProfileAPI.Snapshot(["name": "x"]), BotProfileAPI.Snapshot())
    }

    func testModelOptionsAsksInTheBotsProfileAndReadsSlugsOrObjects() async throws {
        let gw = FakeGateway()
        gw.on("model.options") { _ in
            ["providers": [["slug": "openrouter", "name": "OpenRouter", "aliases": ["or"], "models": ["a/b", "c/d"]],
                           ["slug": "old", "models": [["id": "x"], ["name": "y"], ["id": ""]]],
                           ["name": "no slug", "models": ["z"]]]]
        }
        let providers = try await BotProfileAPI(call: gw.call).modelOptions(profile: "alpha")
        XCTAssertEqual(gw.params("model.options"), [["include_unconfigured": true, "explicit_only": false, "profile": "alpha"]])
        XCTAssertEqual(providers.map(\.slug), ["openrouter", "old"])
        XCTAssertEqual(providers[1].models, ["x", "y"])
        XCTAssertEqual(providers[0].label, "OpenRouter (openrouter)")
        XCTAssertEqual(providers[1].label, "old")
        XCTAssertTrue(providers[0].matches("OR"), "aliases match, ignoring case")
        XCTAssertTrue(providers[0].matches("OpenRouter"))
        XCTAssertFalse(providers[0].matches(""))
    }

    func testConfigureSendsOnlyTheSetSectionsAndReadsAppliedAndConfirm() async throws {
        var c = BotProfileAPI.Changes()
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.params(name: "a"), ["name": "a"])
        c.description = "d"
        c.model = ("p", "m")
        c.enabledToolsets = []
        XCTAssertEqual(c.params(name: "a"), ["name": "a", "description": "d", "model": "m", "provider": "p", "enabled_toolsets": []])
        c.confirmExpensiveModel = true
        c.soul = "s"; c.disabledSkills = ["x"]; c.enabledMcpServers = ["m1"]
        XCTAssertEqual(c.params(name: "a"), ["name": "a", "description": "d", "model": "m", "provider": "p", "confirm_expensive_model": true,
                                             "enabled_toolsets": [], "soul": "s", "disabled_skills": ["x"], "enabled_mcp_servers": ["m1"]])

        let gw = FakeGateway()
        gw.on("profiles.configure") { _ in ["ok": false, "applied": ["description": true, "soul": false], "confirm_required": true,
                                            "confirm_message": "This model is expensive."] }
        let r = try await BotProfileAPI(call: gw.call).configure("a", c)
        XCTAssertEqual(r.applied, ["description": true, "soul": false])
        XCTAssertEqual(r.confirmMessage, "This model is expensive.")
        XCTAssertTrue(r.confirmRequired)
        XCTAssertFalse(BotProfileAPI.ConfigureResult(["applied": [:]]).confirmRequired)
    }

    func testToolsetPinRuleAllOrNoneClearsThePin() {
        let all = [BotProfileAPI.Capability(name: "a", enabled: true), .init(name: "b", enabled: true)]
        let none = [BotProfileAPI.Capability(name: "a", enabled: false), .init(name: "b", enabled: false)]
        let some = [BotProfileAPI.Capability(name: "a", enabled: true), .init(name: "b", enabled: false)]
        XCTAssertEqual(BotProfileAPI.enabledToolsets(all), [])
        XCTAssertEqual(BotProfileAPI.enabledToolsets(none), [])
        XCTAssertEqual(BotProfileAPI.enabledToolsets(some), ["a"])
    }

    func testAvatarAssetCallsSendADataURLOrClearAndDecodeTheReply() async throws {
        let gw = FakeGateway()
        gw.on("profiles.set_asset") { _ in ["ok": true] }
        gw.on("profiles.get_asset") { _ in ["found": true, "mime": "image/png", "data": "data:image/png;base64,AQID"] }
        let api = BotProfileAPI(call: gw.call)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])
        try await api.setAvatar("a", image: png)
        try await api.clearAvatar("a")
        XCTAssertEqual(gw.params("profiles.set_asset"), [
            ["name": "a", "asset": "avatar", "data": .string("data:image/png;base64," + png.base64EncodedString())],
            ["name": "a", "asset": "avatar", "clear": true],
        ])
        let fetched = try await api.avatar("a")
        XCTAssertEqual(fetched, Data([1, 2, 3]))
        XCTAssertEqual(ProfileAvatar.dataURL(Data([0xFF, 0xD8, 0xFF, 0])).prefix(23), "data:image/jpeg;base64,")
        let none = FakeGateway()
        none.on("profiles.get_asset") { _ in ["found": false] }
        let missing = try await BotProfileAPI(call: none.call).avatar("a")
        XCTAssertNil(missing)
    }

    func testRosterEnvelopeTeammatesAndProtocolFlag() {
        let r = BotProfileAPI.Roster(["profiles": [["name": "a", "description": "A bot"], ["name": "b"]], "bot_mode_protocol": true])
        XCTAssertTrue(r.injectsProtocol)
        XCTAssertEqual(r.names, ["a", "b"])
        XCTAssertEqual(r.teammates, [.init(name: "a", description: "A bot"), .init(name: "b")])
        XCTAssertFalse(BotProfileAPI.Roster(["profiles": []]).injectsProtocol)
    }

    func testBotTitleFollowsDesktopOrderMetaTitleThenDisplayNameThenName() {
        XCTAssertEqual(Bot(["name": "a", "display_name": "Disp", "ui_meta": ["hermes-bots": ["title": " Meta "]], "path": "/p/a"])?.title, "Meta")
        XCTAssertEqual(Bot(["name": "a", "display_name": "Disp", "ui_meta": ["hermes-bots": ["title": ""]]])?.title, "Disp")
        XCTAssertEqual(Bot(["name": "a"])?.title, "a")
        XCTAssertEqual(Bot(["name": "a", "path": "/p/a"])?.path, "/p/a")
    }

    // MARK: SOUL messaging protocol (soul.ts)

    func testSoulKeepsTheMessagingProtocolExactlyLikeDesktop() {
        let roster = [SoulProtocol.Teammate(name: "alpha", description: "Me"), .init(name: "bravo", description: "Writes code"), .init(name: "c")]
        let section = SoulProtocol.section(name: "alpha", roster: roster)
        let lines = section.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "## Messaging other agents")
        XCTAssertTrue(lines.contains("hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from \u{1F916} alpha (@alpha): your message\""))
        XCTAssertEqual(Array(lines.suffix(2)), ["- `bravo` — Writes code", "- `c`"], "teammates exclude the bot itself")
        XCTAssertEqual(section, Self.desktopSection, "byte-for-byte what soul.ts renders for the same roster")

        let edited = SoulProtocol.ensure("  # Alpha\nBe brief.\n\n", name: "alpha", roster: roster, serverInjects: false)
        XCTAssertEqual(edited, "# Alpha\nBe brief.\n\n" + section)
        XCTAssertEqual(SoulProtocol.ensure(edited, name: "alpha", roster: roster, serverInjects: false), edited, "never added twice")
        XCTAssertEqual(SoulProtocol.ensure("", name: "alpha", roster: roster, serverInjects: false), section)
        XCTAssertEqual(SoulProtocol.ensure(" mine ", name: "alpha", roster: roster, serverInjects: true), "mine",
                       "a backend that injects the protocol keeps SOUL.md the user's text")
        XCTAssertTrue(SoulProtocol.section(name: "default", roster: []).contains("Message from \u{1F916} hermes (@hermes)"))
        XCTAssertTrue(SoulProtocol.section(name: "solo", roster: []).hasSuffix("- (none yet)"))
        XCTAssertFalse(SoulProtocol.hasSection("x\n## Messaging other agentsX"))
    }

    // MARK: avatar file

    private func png(width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testAvatarIsCroppedToA256PixelSquarePNG() throws {
        let out = try ProfileAvatar.normalize(try png(width: 600, height: 300))
        XCTAssertEqual(ProfileAvatar.format(out), .png)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        XCTAssertLessThan(out.count, 2_000_000, "inside the gateway's set_asset limit")
    }

    func testAvatarRefusesOtherFormatsAndFilesOver15MB() throws {
        XCTAssertThrowsError(try ProfileAvatar.normalize(Data("GIF89a....".utf8))) { XCTAssertEqual($0 as? ProfileAvatar.Failure, .notAnImage) }
        XCTAssertThrowsError(try ProfileAvatar.normalize(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]))) {
            XCTAssertEqual($0 as? ProfileAvatar.Failure, .unreadable)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hba-avatar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanup.append(dir)
        let big = dir.appendingPathComponent("big.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(ProfileAvatar.maxBytes + 1))  // sparse: nothing is really written
        try h.close()
        XCTAssertThrowsError(try ProfileAvatar.read(big)) {
            XCTAssertEqual($0 as? ProfileAvatar.Failure, .tooLarge(ProfileAvatar.maxBytes + 1))
            XCTAssertEqual(Redaction.describe($0), "The image is larger than 15 MB.")
        }
        let small = dir.appendingPathComponent("small.png")
        try png(width: 10, height: 10).write(to: small)
        XCTAssertEqual(ProfileAvatar.format(try ProfileAvatar.read(small)), .png)
    }

    // MARK: hermes CLI (delete, inherit model)

    private func makeCLI(_ runner: FakeCommandRunner) throws -> (ProfileCLI, URL, URL) {
        let (home, hermes) = try TempFS.home()
        cleanup.append(home)
        return (ProfileCLI(home: home, environment: ["HERMES_BOT_APP_HERMES_BIN": hermes.path], runner: runner), home, hermes)
    }

    func testDeleteRunsTheTrustedHermesWithoutAShellAndNeverForDefault() async throws {
        let runner = FakeCommandRunner()
        let (cli, home, hermes) = try makeCLI(runner)
        try await cli.deleteProfile("alpha-2")
        try await cli.unsetModel("alpha")
        XCTAssertEqual(runner.calls.map(\.arguments), [["profile", "delete", "alpha-2", "--yes"],
                                                       ["--profile", "alpha", "config", "unset", "model"]])
        XCTAssertEqual(runner.calls.first?.executable, TempFS.real(hermes))
        XCTAssertEqual(runner.calls.first?.environment?["HERMES_HOME"], home.appendingPathComponent(".hermes").path)
        XCTAssertNil(runner.calls.first?.environment?["HERMES_BOT_APP_HERMES_BIN"], "clean environment")
        for bad in ["default", "Default", " default "] {
            do { try await cli.deleteProfile(bad); XCTFail("deleted \(bad)") } catch {
                XCTAssertEqual(Redaction.describe(error), "The default profile cannot be deleted.")
            }
        }
        for bad in ["--help", "a b", "../x", ""] {
            do { try await cli.deleteProfile(bad); XCTFail("accepted \(bad)") } catch { XCTAssertTrue(error is ProfileCLI.Failure) }
        }
        XCTAssertEqual(runner.calls.count, 2, "refused names never reach the command line")
    }

    func testCLIFailureIsTheScrubbedLastLine() async throws {
        let runner = FakeCommandRunner { _, _ in CommandResult(status: 1, output: "Working…\nError: Authorization: Bearer abcdefgh12345 refused\n") }
        let (cli, _, _) = try makeCLI(runner)
        do { try await cli.deleteProfile("bob"); XCTFail("expected failure") } catch {
            let text = Redaction.describe(error)
            XCTAssertTrue(text.hasPrefix("Error: Authorization"), text)
            XCTAssertFalse(text.contains("abcdefgh12345"), text)
        }
        let slow = FakeCommandRunner { _, _ in CommandResult(status: 15, output: "", timedOut: true) }
        let (cli2, _, _) = try makeCLI(slow)
        do { try await cli2.unsetModel("bob"); XCTFail("expected timeout") } catch {
            XCTAssertEqual(error as? ProfileCLI.Failure, .init(description: "timed out"))
        }
    }

    // MARK: duplicate (profile-ops.ts duplicateBot)

    func testDuplicateNameIsTheFirstFreeSuffixAndCutsTheBaseNotTheSuffix() {
        XCTAssertEqual(BotDuplicate.name(for: "alpha", taken: ["alpha"]), "alpha-2")
        XCTAssertEqual(BotDuplicate.name(for: "alpha", taken: ["alpha", "alpha-2", "alpha-3"]), "alpha-4")
        let long = String(repeating: "a", count: 64)
        let n = BotDuplicate.name(for: long, taken: [long])
        XCTAssertEqual(n, String(repeating: "a", count: 62) + "-2")
        XCTAssertEqual(n?.count, 64)
        XCTAssertNil(BotDuplicate.name(for: "x", taken: Set((2..<100).map { "x-\($0)" })))
    }

    func testDuplicateLookDropsChatAndCreatedAndMarksTheTitleAsACopy() {
        let row: JSONValue = ["name": "a", "ui_meta": ["hermes-bots": ["title": "Ada", "color": "#fff", "chat": "s1", "created": 5, "pinned": true]]]
        XCTAssertEqual(BotDuplicate.look(row: row), ["title": "Ada (copy)", "color": "#fff", "pinned": true])
        XCTAssertEqual(BotDuplicate.look(row: ["name": "a", "ui_meta": ["hermes-bots": ["color": "#000"]]]), ["color": "#000", "title": ""])
        XCTAssertNil(BotDuplicate.look(row: ["name": "a"]))
    }

    func testDuplicateCreatesTheCloneThenCopiesLookAndAvatar() async throws {
        let gw = FakeGateway()
        let roster: JSONValue = ["profiles": [["name": "alpha", "description": "Researcher", "has_avatar": true,
                                               "ui_meta": ["hermes-bots": ["title": "Ada", "chat": "s1"]]],
                                              ["name": "alpha-2"]]]
        let afterCreate: JSONValue = ["profiles": [["name": "alpha"], ["name": "alpha-2"],
                                                   ["name": "alpha-3", "ui_meta_revisions": [:]]]]
        gw.on("profiles.list") { _ in roster }
        gw.on("profiles.list") { _ in afterCreate }
        gw.on("profiles.create") { _ in ["ok": true, "name": "alpha-3", "path": "/h/.hermes/profiles/alpha-3"] }
        gw.on("profiles.configure") { _ in ["applied": ["ui_meta": true]] }
        gw.on("profiles.get_asset") { _ in ["found": true, "data": "data:image/png;base64,AQID"] }
        gw.on("profiles.set_asset") { _ in ["ok": true] }
        final class Steps: @unchecked Sendable { var list: [BotDuplicate.Step] = [] }
        let steps = Steps()
        let r = try await BotDuplicate.run(source: "alpha", description: "Researcher", api: BotProfileAPI(call: gw.call), call: gw.call) {
            steps.list.append($0)
        }
        XCTAssertEqual(r, BotDuplicate.Result(name: "alpha-3", path: "/h/.hermes/profiles/alpha-3", warnings: []))
        XCTAssertEqual(steps.list, [.creating("alpha-3"), .copyingLook, .copyingAvatar])
        XCTAssertEqual(gw.params("profiles.create"), [["name": "alpha-3", "clone_from": "alpha", "description": "Researcher"]])
        XCTAssertEqual(gw.params("profiles.configure"), [["name": "alpha-3", "ui_meta": ["hermes-bots": ["title": "Ada (copy)"]],
                                                          "ui_meta_expected_revisions": ["hermes-bots": 0]]])
        XCTAssertEqual(gw.params("profiles.get_asset"), [["name": "alpha", "asset": "avatar"]])
        XCTAssertEqual(gw.params("profiles.set_asset"), [["name": "alpha-3", "asset": "avatar", "data": "data:image/png;base64,AQID"]])
    }

    func testDuplicateReportsALookFailureButKeepsTheCopy() async throws {
        let gw = FakeGateway()
        gw.on("profiles.list") { _ in ["profiles": [["name": "b", "has_avatar": true, "ui_meta": ["hermes-bots": ["title": "B"]]]]] }
        gw.on("profiles.create") { _ in ["path": "/p/b-2"] }
        gw.on("profiles.configure") { _ in throw GatewayClient.RPCError(code: 5064, message: "boom", data: nil) }
        gw.on("profiles.get_asset") { _ in throw GatewayClient.RPCError(code: 5066, message: "gone", data: nil) }
        let r = try await BotDuplicate.run(source: "b", description: "", api: BotProfileAPI(call: gw.call), call: gw.call)
        XCTAssertEqual(r.name, "b-2")
        XCTAssertEqual(r.warnings.count, 2)
        XCTAssertFalse(gw.methods.contains("profiles.set_asset"))

        let failing = FakeGateway()
        failing.on("profiles.list") { _ in ["profiles": [["name": "b"]]] }
        failing.on("profiles.create") { _ in throw GatewayClient.RPCError(code: 4062, message: "Profile 'b-2' already exists", data: nil) }
        do { _ = try await BotDuplicate.run(source: "b", description: "", api: BotProfileAPI(call: failing.call), call: failing.call); XCTFail() } catch {
            XCTAssertTrue(Redaction.describe(error).contains("already exists"))
        }
        XCTAssertFalse(failing.methods.contains("profiles.configure"), "no look is written when the profile was not created")
    }

    /// `messagingProtocolSection('alpha', [alpha, bravo, c])` rendered by Desktop's soul.ts (node), verbatim.
    static let desktopSection = #"""
## Messaging other agents

You work alongside other named agents. Every agent (including you) has
ONE canonical conversation titled "Bot Chat" — created with the agent,
so it always exists. Agent-to-agent messages are delivered straight
into it, like a DM. To message a teammate, run:

```
hermes -p <agent-name> chat --in ~ -c "Bot Chat" --create-if-missing -Q -q "Message from 🤖 alpha (@alpha): your message"

Run the send with background=true and notify_on_complete=true on the
terminal tool, then finish your turn — the reply arrives later as a
background process notification. Never block waiting for it.
```

(`--in ~ -c "Bot Chat" --create-if-missing` resumes their canonical
conversation in the home workspace, creating it if the target has no
"Bot Chat" yet. `-Q` keeps output clean. Always open with the
"Message from 🤖 alpha (@alpha):" prefix so they know
who is talking (the @handle lets the app show your avatar to them).
Their reply prints to stdout — relay the relevant part back to the
user, and say which agent it came from.)

If a message in YOUR chat starts with "Message from 🤖 <name>", it is
a teammate messaging you, not the user. Answer it directly — your reply
reaches them via their own delivery — and use the same command if you
need to start a conversation yourself.

When the user writes @<agent-name> or says "ask <name> to ..." /
"tell <name> ...", that is a handoff: message that agent, wait for the
reply, and report back.

The roster grows over time — run `hermes profile list` for the LIVE
teammate list before a handoff. Teammates when you were created:
- `bravo` — Writes code
- `c`
"""#
}
