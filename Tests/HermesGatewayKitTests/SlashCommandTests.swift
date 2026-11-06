import Foundation
import XCTest
@testable import HermesGatewayKit

/// Slash commands: catalog curation + filter, directive decoding, client-side rewrites, and the
/// `slash.exec` → `command.dispatch` fallback against the fake gateway.
final class SlashCommandTests: XCTestCase {
    private let catalogResult: JSONValue = [
        "pairs": [["/goal", "Set a goal"], ["/voice", "Voice mode"], ["/sethome", "Set home"], ["/skills", "Skills hub"]],
        "canon": ["/g": "/goal"],
        "commands": ["/goal": ["argument_mode": "text", "desktop": nil],
                     "/voice": ["desktop": "composer-voice"],
                     "/sethome": ["desktop": "messaging"],
                     "/skills": ["desktop": nil, "desktop_subcommands": ["pending", "approve"]]],
        "categories": [["name": "Session", "pairs": [["/goal", "Set a goal"], ["/sethome", "Set home"]]],
                       ["name": "User commands", "pairs": [["/deploy", "Ship it"]]],
                       ["name": "Skills", "pairs": [["/gif-search", "Find a gif"]]]],
        "skills": ["gif-search": ["usage": 2, "origin": "local"]],
        "warning": "",
    ]

    // MARK: - catalog

    func testCatalogHidesNonDesktopBuiltinsAndKeepsExtensions() {
        let c = SlashCatalog(result: catalogResult)
        XCTAssertEqual(c.commands.map(\.name), ["/goal", "/deploy", "/gif-search", "/skills"])
        XCTAssertEqual(c.commands.first?.category, "Session")
        XCTAssertEqual(c.commands.first?.argumentMode, "text")
        XCTAssertEqual(c.canon["/g"], "/goal")
        XCTAssertEqual(c.desktopSubcommands["/skills"], ["pending", "approve"])
        XCTAssertNil(c.warning)
        XCTAssertEqual(c.filter("g").map(\.name), ["/goal", "/gif-search"])
        XCTAssertEqual(c.filter("/DEP").map(\.name), ["/deploy"])
        XCTAssertEqual(c.filter("search").map(\.name), ["/gif-search"], "substring after prefix matches")
        XCTAssertEqual(c.filter("").count, 4)
        XCTAssertEqual(SlashCatalog.subcommandRefusal("/skills", arg: "", allowed: ["pending"]),
                       "/skills needs a subcommand here: pending.")
        XCTAssertNil(SlashCatalog.subcommandRefusal("/skills", arg: "Pending now", allowed: ["pending"]))
    }

    // MARK: - directives

    func testDirectiveDecoding() {
        XCTAssertEqual(SlashDirective.execResult(["output": "done"], name: "x"), .output("done"))
        XCTAssertEqual(SlashDirective.execResult(["output": "done", "warning": "slow"], name: "x"), .output("warning: slow\ndone"))
        XCTAssertEqual(SlashDirective.execResult([:], name: "x"), .output("/x: no output"))
        XCTAssertEqual(SlashDirective.execResult(["type": "exec", "output": "o"], name: "x"), .output("o"))
        XCTAssertEqual(SlashDirective.directive(["type": "alias", "target": "goal"]), .alias(target: "goal"))
        XCTAssertEqual(SlashDirective.directive(["type": "send", "message": "m", "display": "/x", "notice": "n"]),
                       .send(message: "m", display: "/x", notice: "n"))
        XCTAssertEqual(SlashDirective.directive(["type": "skill", "name": "gif", "message": "body"]),
                       .skill(name: "gif", message: "body", display: nil))
        XCTAssertEqual(SlashDirective.directive(["type": "prefill", "message": "undo me"]), .prefill(message: "undo me", notice: nil))
        XCTAssertNil(SlashDirective.directive(["type": "send"]), "send without message is invalid")
        XCTAssertNil(SlashDirective.directive(["type": "mystery"]))
    }

    // MARK: - client-side rewrites

    func testClassify() {
        XCTAssertNil(SlashInvocation.classify("hello", canonical: true))
        XCTAssertNil(SlashInvocation.classify("/", canonical: true))
        XCTAssertNil(SlashInvocation.classify("//not a command", canonical: true))
        XCTAssertEqual(SlashInvocation.classify("/new", canonical: true), .compress(focus: "", rewrittenFrom: "/new"))
        XCTAssertEqual(SlashInvocation.classify(" /Reset ", canonical: true), .compress(focus: "", rewrittenFrom: "/reset"))
        XCTAssertEqual(SlashInvocation.classify("/compact the plan", canonical: true), .compress(focus: "the plan", rewrittenFrom: nil))
        XCTAssertEqual(SlashInvocation.classify("/stop", canonical: true), .stop)
        XCTAssertEqual(SlashInvocation.classify("/commands", canonical: true), .help)
        guard case .unavailable? = SlashInvocation.classify("/title New name", canonical: true) else { return XCTFail("title") }
        guard case .unavailable? = SlashInvocation.classify("/model", canonical: true) else { return XCTFail("model") }
        XCTAssertEqual(SlashInvocation.classify("/goal ship  v2", canonical: true), .exec(name: "goal", arg: "ship  v2"))
        XCTAssertEqual(SlashInvocation.classify("/gif-search\ncats", canonical: true), .exec(name: "gif-search", arg: "cats"))
    }

    // MARK: - exec + fallback over the wire

    private func session(_ gw: FakeGateway) async throws -> (Backend, BotChatSession) {
        let backend = try await Parity.backend(gw)
        return (backend, try await BotChatSession.open(backend, bot: Parity.bot, title: nil))
    }

    func testExecPlainOutputAndAliasHop() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, p in
            guard m == "slash.exec" else { return Parity.defaults(m) }
            return p["command"]?.string == "g now" ? ["type": "alias", "target": "goal"] : ["output": "goal set"]
        }
        let (backend, s) = try await session(gw)
        defer { backend.client.close() }
        let d = try await s.runSlash(name: "/g", arg: "now")
        XCTAssertEqual(d, .output("goal set"))
        XCTAssertEqual(gw.received.filter { $0["method"] == "slash.exec" }.map { $0["params"] },
                       [["session_id": "rt-1", "command": "g now"], ["session_id": "rt-1", "command": "goal now"]])
    }

    func testExecErrorFallsBackToDispatch() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "slash.exec": return ["__error": ["code": 4018, "message": "skill command: use command.dispatch for /gif-search"]]
            case "command.dispatch": return ["type": "skill", "name": "gif-search", "message": "SKILL BODY", "display": "/gif-search cats"]
            default: return Parity.defaults(m)
            }
        }
        let (backend, s) = try await session(gw)
        defer { backend.client.close() }
        let d = try await s.runSlash(name: "gif-search", arg: "cats")
        XCTAssertEqual(d, .skill(name: "gif-search", message: "SKILL BODY", display: "/gif-search cats"))
        XCTAssertEqual(gw.received.first { $0["method"] == "command.dispatch" }?["params"],
                       ["session_id": "rt-1", "name": "gif-search", "arg": "cats"])
    }

    func testRoutingNoiseFromDispatchRethrowsTheExecError() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in
            switch m {
            case "slash.exec": return ["__error": ["code": 5030, "message": "slash worker failed to start"]]
            case "command.dispatch": return ["__error": ["code": 4018, "message": "not a quick/plugin/bundle/skill command: foo"]]
            default: return Parity.defaults(m)
            }
        }
        let (backend, s) = try await session(gw)
        defer { backend.client.close() }
        do { _ = try await s.runSlash(name: "foo", arg: ""); XCTFail("succeeded") }
        catch let e as GatewayClient.RPCError { XCTAssertEqual(e.code, 5030) }
    }

    func testSubcommandGateStopsBeforeTheWire() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        gw.responder = { m, _ in Parity.defaults(m) }
        let (backend, s) = try await session(gw)
        defer { backend.client.close() }
        let d = try await s.runSlash(name: "skills", arg: "install foo", catalog: SlashCatalog(result: catalogResult))
        guard case .output(let text) = d else { return XCTFail("\(d)") }
        XCTAssertTrue(text.contains("not available here"), text)
        XCTAssertFalse(Parity.methods(gw).contains("slash.exec"))
    }

    func testCompressAndCatalogRequests() async throws {
        let gw = try await FakeGateway.start()
        defer { gw.stop() }
        let catalog = catalogResult
        gw.responder = { m, _ in
            switch m {
            case "commands.catalog": return catalog
            case "session.compress": return ["removed": 4, "before_messages": 10, "after_messages": 6,
                                             "messages": [["role": "assistant", "text": "summary"]]]
            default: return Parity.defaults(m)
            }
        }
        let (backend, s) = try await session(gw)
        defer { backend.client.close() }
        let c = try await s.slashCatalog()
        XCTAssertEqual(c.commands.count, 4)
        let o = try await s.compress(focus: "plan")
        XCTAssertEqual(o, CompressOutcome(compressed: true, message: nil, beforeMessages: 10, afterMessages: 6,
                                          history: [ChatHistoryMessage(role: .assistant, text: "summary")]))
        XCTAssertEqual(gw.received.first { $0["method"] == "commands.catalog" }?["params"], ["session_id": "rt-1"])
        XCTAssertEqual(gw.received.first { $0["method"] == "session.compress" }?["params"], ["session_id": "rt-1", "focus_topic": "plan"])
    }
}
