import XCTest
@testable import HermesBotApp

/// Live UI test 2026-11-06: Hermes' own control messages ("[IMPORTANT: Background process … exited …]",
/// "[System: …]", "[CONTEXT SUMMARY]…") showed in Bot Chat as the user's bubbles. They are now a muted,
/// collapsible notice; anything a person wrote stays a bubble.
final class SystemNoticeTests: XCTestCase {
    private static let background = """
    [IMPORTANT: Background process proc_8c0e2be2158d exited (exit code 1).
    Command: /Users/me/.hermes/bin/python3 bot_mode_dm.py --run-delivery
    Output:
    {"error": "Delivery failed", "reason": "target_busy"}
    ]
    """

    func testHermesControlFramesBecomeNotices() throws {
        let bg = try XCTUnwrap(SystemNotice.parse(Self.background))
        XCTAssertEqual(bg.title, "Background process proc_8c0e2be2158d exited (exit code 1).")
        XCTAssertEqual(bg.text, Self.background, "the whole message is kept for the opened notice")

        let cases: [(String, String)] = [
            ("[System: The session was resumed after a restart.]", "The session was resumed after a restart."),
            ("[CONTEXT SUMMARY]: Earlier the user asked for a release build.", "Context summary"),
            ("[CONTEXT COMPACTION] Earlier turns were summarised.\nDetails…", "Context compaction"),
            ("[PRIOR CONTEXT — summary of earlier turns]\n…", "PRIOR CONTEXT — summary of earlier turns"),
            ("[Runtime note: model switched]", "model switched"),
            ("[System note: tool output trimmed]", "tool output trimmed"),
            ("[SYSTEM]\nsomething", "System"),
            ("[IMPORTANT: 2 background processes exited]", "2 background processes exited"),
            ("[Planning state preserved across compaction]", "Planning state preserved across compaction"),
            ("[ASYNC DELEGATION] child finished", "Async delegation"),
            ("[Your active task list was preserved]", "Your active task list was preserved"),
            ("  \n[System: leading blank lines]", "leading blank lines"),
        ]
        for (text, title) in cases {
            XCTAssertEqual(SystemNotice.parse(text)?.title, title, text)
        }
    }

    func testRealUserTextIsNeverFolded() {
        let userTexts = [
            "Please check the [System: x] frame in the logs",  // not at the start
            "IMPORTANT: ship it today",  // no bracket
            "[important: lower case is a person typing]",
            "[system: lower case]",
            "[Note] hello",
            "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once]\nstop and use main\n[/OUT-OF-BAND USER MESSAGE]",
            "[IMPORTANT: The user has invoked the \"release\" skill, indicating they want…]\n\nship 0.2.0",
            "[IMPORTANT: The \"review\" skill is auto-loaded. …]\nlook at PR 12",
            "",
            "[",
        ]
        for text in userTexts {
            XCTAssertNil(SystemNotice.parse(text), text)
        }
    }

    func testOpenersMirrorHermesControlFrameList() {
        // hermes-agent agent/prompt_builder.py CONTROL_FRAME_OPENERS (837acdc91d7), minus the steer marker
        // (it carries the user's words), plus "Your active task list" (context_compressor).
        XCTAssertEqual(Set(SystemNotice.openers), [
            "CONTEXT COMPACTION", "CONTEXT SUMMARY]", "PRIOR CONTEXT", "Runtime note:", "System note:", "System:",
            "SYSTEM]", "IMPORTANT:", "Planning state preserved", "ASYNC DELEGATION", "Your active task list",
        ])
    }

    func testLongTitlesAreCapped() {
        let notice = SystemNotice.parse("[System: " + String(repeating: "word ", count: 60) + "]")
        XCTAssertEqual(notice?.title.count, SystemNotice.titleLimit + 1)
        XCTAssertEqual(notice?.title.last, "…")
    }
}
