import HermesGatewayKit
import XCTest
@testable import HermesBotApp

/// Hermes Desktop-style transcript presentation: tool titles, counts and details, group summaries, tool
/// runs folded into groups, and one avatar header per bot turn.
final class TranscriptPresentationTests: XCTestCase {
    private func tool(_ name: String, _ text: String = "", state: ToolLine.State = .done, label: String? = nil,
                      args: JSONValue? = nil, result: JSONValue? = nil, diff: String? = nil) -> ChatLine {
        ChatLine(role: .tool, text: text, tool: ToolLine(toolId: UUID().uuidString, name: name, state: state, label: label,
                                                          args: args, result: result, inlineDiff: diff))
    }

    // MARK: titles and meta

    func testTitlesFollowDesktop() {
        XCTAssertEqual(ToolRowPresentation(tool("terminal", args: ["command": "python3 script/apply-jira.py CUST-6564 --stack android"])).title,
                       "Ran python3 script/apply-jira.py CUST-6564 --stack android")
        XCTAssertEqual(ToolRowPresentation(tool("execute_code", args: ["code": "import json, re\n\nx = 1\nprint(x)"])).title,
                       "Ran code import json, re + 2 commands", "blank lines are not commands")
        XCTAssertEqual(ToolRowPresentation(tool("mcp_atlassian_getjiraissue", "{\"key\":1}", label: "Atlassian · getjiraissue")).title,
                       "Atlassian · getjiraissue", "a connector label replaces the tool name")
        XCTAssertEqual(ToolRowPresentation(tool("read_file", args: ["path": "/tmp/a.swift"])).title, "Read /tmp/a.swift")
        let other = ToolRowPresentation(tool("todo", "  add   item "))
        XCTAssertEqual(other.title, "todo")
        XCTAssertEqual(other.context, "add item")
        let long = ToolRowPresentation(tool("terminal", args: ["command": .string(String(repeating: "a", count: 400))])).title
        XCTAssertEqual(long.count, "Ran ".count + 160)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testShellSummaryPeelsPlumbingLikeDesktop() {
        let cases: [(String, String)] = [
            ("cd /Users/x/agent-knowledge-workflow && python3 script/apply-jira.py CUST-6564 --stack android 2>&1 | tail -20; echo \"x_exit=${PIPESTATUS[0]}\"",
             "python3 script/apply-jira.py CUST-6564 --stack android"),
            ("cd /repo && git status && git diff --stat", "git status + 1 command"),
            ("cd /repo && export A=1 && FOO=bar make test > out.log", "FOO=bar make test"),
            ("echo 'a && b'; ls", "echo 'a && b' + 1 command"),
            ("cd /only", "cd /only"),
            ("ls -la | grep x", "ls -la | grep x"),
            ("", ""),
        ]
        for (input, expected) in cases { XCTAssertEqual(ShellSummary.summarize(input), expected, input) }
        XCTAssertEqual(ToolRowPresentation(tool("terminal", args: ["command": "cd /a && npm test"])).title, "Ran npm test")
    }

    func testCountsFromResults() {
        XCTAssertEqual(ToolRowPresentation.countLabel(["stdout_bytes_total": 360, "output": "x"]), "360 stdout_bytes")
        XCTAssertEqual(ToolRowPresentation.countLabel(["items": [1]]), "1 item")
        XCTAssertEqual(ToolRowPresentation.countLabel([1, 2, 3]), "3 items")
        XCTAssertNil(ToolRowPresentation.countLabel("plain output"))
        XCTAssertNil(ToolRowPresentation.countLabel(["ratio_total": .number(0.5)]), "only whole numbers are counts")
        XCTAssertNil(ToolRowPresentation.countLabel(["bytes_total": .number(1e19)]), "too big for Int: skipped, no trap")
        XCTAssertEqual(ToolRowPresentation(ChatLine(role: .tool, text: "", tool: ToolLine(toolId: "t", name: "terminal", state: .done,
            result: ["output": "a", "stdout": "a", "exit_code": .number(1e30)]))).details,
                       [.code(label: "Output", language: nil, text: "a")], "one Output section; an absurd exit code is not shown")
    }

    func testDetailsShowCommandOutputAndDiff() {
        let p = ToolRowPresentation(tool("terminal", args: ["command": "git status"],
                                         result: ["output": "clean", "exit_code": 0], diff: "-a\n+b"))
        XCTAssertEqual(p.details, [.code(label: "Command", language: "bash", text: "git status"),
                                   .code(label: "Changes", language: "diff", text: "-a\n+b"),
                                   .code(label: "Output", language: nil, text: "clean"),
                                   .text(label: "Exit code", text: "0")])
        let json = ToolRowPresentation(tool("mcp_x", args: ["key": "CUST-1"], result: ["fields": ["a": 1]]))
        XCTAssertEqual(json.details.map { if case .code(let l, _, _) = $0 { return l }; return "" }, ["Arguments", "Result"])
        XCTAssertFalse(ToolRowPresentation(tool("todo")).expandable, "nothing to show, nothing to expand")
        for line in [tool("terminal", args: ["command": "ls"]), tool("x", args: ["a": 1]), tool("x", result: ["a": 1]),
                     tool("x", result: ""), tool("x", args: [:]), tool("x", diff: "d"), tool("execute_code", args: ["other": 1])] {
            let p = ToolRowPresentation(line)
            XCTAssertEqual(p.expandable, !p.details.isEmpty, "\(line.tool!)")
        }
        let huge = ToolRowPresentation(tool("terminal", result: .string(String(repeating: "x", count: 30_000))))
        guard case .code(_, _, let text)? = huge.details.first else { return XCTFail() }
        XCTAssertTrue(text.hasSuffix("(10000 more characters)"))
    }

    func testGroupSummary() {
        XCTAssertEqual(ToolCategory.summary(["terminal", "mcp_atlassian_getjiraissue"]), "Ran 1 command, used 1 tool")
        XCTAssertEqual(ToolCategory.summary(["terminal", "execute_code", "patch", "read_file", "read_file"]),
                       "Edited 1 file, read 2 files, ran 2 commands")
    }

    // MARK: items

    func testAdjacentToolsFoldIntoAGroupAndOneHeaderPerTurn() {
        let user = ChatLine(role: .user, text: "continue")
        let thought = ChatLine(role: .thought, text: "plan")
        let text = ChatLine(role: .bot, text: "Melanjutkan")
        let t1 = tool("terminal"), t2 = tool("execute_code"), t3 = tool("terminal")
        let thought2 = ChatLine(role: .thought, text: "more")
        let done = ChatLine(role: .bot, text: "Selesai")
        let user2 = ChatLine(role: .user, text: "next")
        let reply = ChatLine(role: .bot, text: "ok")
        let items = TranscriptItem.build([user, thought, text, t1, thought2, t2, t3, done, user2, reply])
        XCTAssertEqual(items, [
            .line(user, header: false),
            .line(thought, header: true),
            .line(text, header: false),
            .line(t1, header: false),
            .line(thought2, header: false),
            .tools([t2, t3], header: false),
            .line(done, header: false),
            .line(user2, header: false),
            .line(reply, header: true),
        ])
        XCTAssertEqual(items[5].id, t2.id)
    }
}

/// Expansion state outlives the row views: a single call that becomes a group keeps it open.
@MainActor
final class DisclosureStoreTests: XCTestCase {
    func testChoicesPersistAndAGroupInheritsItsFirstRow() {
        let store = DisclosureStore()
        let a = UUID(), b = UUID()
        XCTAssertFalse(store.isOpen(.row, a))
        XCTAssertTrue(store.isOpen(.thought, a, fallback: true), "no choice yet: the fallback (streaming) wins")
        store.set(.thought, a, false)
        XCTAssertFalse(store.isOpen(.thought, a, fallback: true), "the user's choice wins")
        store.set(.row, a, true)
        XCTAssertTrue(store.isOpen(.group, a), "the running call the user opened stays open as a group")
        store.set(.group, a, false)
        XCTAssertFalse(store.isOpen(.group, a))
        XCTAssertFalse(store.isOpen(.group, b))
    }
}
