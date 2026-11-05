import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// B5 (message time, turn duration texts), B6 (follow / unread), B13 (Find in chat), B15 (Markdown export).
/// Pure models, headless.
@MainActor
final class BotChatTranscriptFeaturesTests: XCTestCase {
    private let bot = Bot(["name": "fake", "display_name": "Fake"])!
    private let posix = Locale(identifier: "en_US_POSIX")
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: B5

    func testElapsedLikeDesktop() {
        XCTAssertEqual(MessageTime.elapsed(1), "1s")
        XCTAssertEqual(MessageTime.elapsed(59.4), "59s")
        XCTAssertEqual(MessageTime.elapsed(125), "2:05")
        XCTAssertEqual(MessageTime.spokenElapsed(1), "1 second")
        XCTAssertEqual(MessageTime.spokenElapsed(125), "2 minutes 5 seconds")
        XCTAssertEqual(MessageTime.spokenElapsed(120), "2 minutes")
    }

    func testShortTimeSaysTodayYesterdayOrTheDay() {
        let now = Date(timeIntervalSince1970: 1_762_430_400)  // 2025-11-06 12:00 UTC
        let today = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-86_400)
        let older = now.addingTimeInterval(-86_400 * 9)
        let clock = MessageTime.short(today, now: now, calendar: utc, locale: posix)
        XCTAssertFalse(clock.contains(","), "today shows the clock only: \(clock)")
        XCTAssertTrue(MessageTime.short(yesterday, now: now, calendar: utc, locale: posix).hasPrefix("Yesterday, "))
        XCTAssertTrue(MessageTime.short(older, now: now, calendar: utc, locale: posix).hasPrefix("Oct 28, "))
    }

    // MARK: B6

    func testFollowStopsOnlyWhenTheUserScrollsUp() {
        var f = TranscriptFollow()
        XCTAssertTrue(f.following)
        f.update(top: -500, bottom: 600, viewport: 600)
        XCTAssertTrue(f.following, "at the bottom")
        f.update(top: -500, bottom: 900, viewport: 600)
        XCTAssertTrue(f.following, "content grew below while following: still following")
        XCTAssertTrue(f.update(top: -300, bottom: 1100, viewport: 600), "the user scrolled up")
        XCTAssertFalse(f.following)
        f.update(top: -300, bottom: 1400, viewport: 600)
        XCTAssertFalse(f.following, "a reply growing while scrolled up does not pull the view down")
        f.update(top: -1100, bottom: 620, viewport: 600)
        XCTAssertTrue(f.following, "back within the slack of the end")
        f.update(top: -1000, bottom: 720, viewport: 600)
        XCTAssertFalse(f.following)
        f.resume()
        XCTAssertTrue(f.following, "Scroll to bottom follows again")
    }

    func testUnreadCountsMessagesThatArrivedWhileScrolledUp() {
        var u = UnreadCounter()
        var lines = [ChatLine(role: .user, text: "q"), ChatLine(role: .bot, text: "a")]
        u.update(lines, following: true)
        XCTAssertEqual(u.count, 0)
        lines.append(ChatLine(role: .tool, text: "ls"))
        lines.append(ChatLine(role: .thought, text: "hmm"))
        u.update(lines, following: false)
        XCTAssertEqual(u.count, 0, "tool and Thought rows are not messages")
        lines.append(ChatLine(role: .bot, text: "more"))
        lines.append(ChatLine(role: .error, text: "boom"))
        u.update(lines, following: false)
        XCTAssertEqual(u.count, 2)
        lines[4].text += " and more"
        u.update(lines, following: false)
        XCTAssertEqual(u.count, 2, "a streaming reply counts once")
        u.update(lines, following: true)
        XCTAssertEqual(u.count, 0)
        XCTAssertEqual(ScrollToBottomButton.label(0), "Scroll to bottom")
        XCTAssertEqual(ScrollToBottomButton.label(1), "1 new message")
        XCTAssertEqual(ScrollToBottomButton.label(3), "3 new messages")
    }

    // MARK: B13

    private func transcript() -> [ChatLine] {
        [ChatLine(role: .user, text: "Find the Café receipts"),
         ChatLine(role: .thought, text: "café café"),
         ChatLine(role: .tool, text: "grep cafe", tool: ToolLine(toolId: "1", name: "terminal", state: .done)),
         ChatLine(role: .bot, text: "Two **cafe** receipts: CAFE-1 and cafe-2."),
         ChatLine(role: .user, text: "[System: cafe job done]"),
         ChatLine(role: .error, text: "no more cafe")]
    }

    func testFindCountsCaseAndAccentInsensitiveMatchesInMessagesOnly() {
        var f = ChatFind()
        let lines = transcript()
        f.setQuery("cafe", lines: lines)
        XCTAssertEqual(f.matches.count, 1 + 3 + 1, "Thought, tool rows and Hermes notices are not searched")
        XCTAssertEqual(f.label, "5 of 5", "starts at the newest match")
        XCTAssertEqual(f.currentMatch, ChatFind.Match(lineId: lines[5].id, occurrence: 0))
        f.setQuery("zzz", lines: lines)
        XCTAssertEqual(f.label, "No results")
        XCTAssertNil(f.currentMatch)
        f.setQuery("", lines: lines)
        XCTAssertEqual(f.label, "")
        f.setQuery("   ", lines: lines)
        XCTAssertTrue(f.matches.isEmpty, "a blank query matches nothing")
    }

    func testFindStepsWrapAround() {
        var f = ChatFind()
        let lines = transcript()
        f.setQuery("cafe", lines: lines)
        f.step(1)
        XCTAssertEqual(f.label, "1 of 5")
        XCTAssertEqual(f.currentMatch?.lineId, lines[0].id)
        f.step(-1)
        XCTAssertEqual(f.label, "5 of 5")
        f.step(-1)
        XCTAssertEqual(f.currentMatch, ChatFind.Match(lineId: lines[3].id, occurrence: 2))
    }

    func testFindKeepsTheCurrentMatchWhenTheTranscriptGrows() {
        var f = ChatFind()
        var lines = transcript()
        f.setQuery("cafe", lines: lines)
        f.step(1)  // the first match, in the user's message
        lines.append(ChatLine(role: .bot, text: "another cafe"))
        f.refresh(lines)
        XCTAssertEqual(f.currentMatch?.lineId, lines[0].id)
        XCTAssertEqual(f.label, "1 of 6")
        f.refresh(Array(lines.dropFirst()))
        XCTAssertEqual(f.label, "1 of 5", "a vanished match falls back to a nearby one")
    }

    func testFindHighlightMarksEveryOccurrence() {
        var a = AttributedString("Cafe and café and CAFÉ")
        TextStyling.highlightFind(&a, query: "cafe")
        let marked = a.runs.filter { $0.backgroundColor != nil }.map { String(a[$0.range].characters) }
        XCTAssertEqual(marked, ["Cafe", "café", "CAFÉ"])
        var none = AttributedString("Cafe")
        TextStyling.highlightFind(&none, query: " ")
        XCTAssertTrue(none.runs.allSatisfy { $0.backgroundColor == nil })
    }

    // MARK: B15

    func testExportWritesMessagesAndToolSummariesWithoutReasoningOrSecrets() {
        let start = Date(timeIntervalSince1970: 1_762_430_400)
        var reply = ChatLine(role: .bot, text: "Done. Token was bearer abcdef123456 and ?token=s3cr3t", at: start)
        reply.turnDuration = 12
        let lines = [
            ChatLine(role: .user, text: "Run the check with Authorization: Bearer sk-live-123456789", at: start),
            ChatLine(role: .thought, text: "private reasoning"),
            ChatLine(role: .tool, text: "git status",
                     tool: ToolLine(toolId: "1", name: "terminal", state: .done, duration: 1.2)),
            ChatLine(role: .tool, text: "", tool: ToolLine(toolId: "3", name: "web_search", state: .done,
                                                           args: ["api_key": "--secret"], result: ["raw": "--secret"])),
            ChatLine(role: .tool, text: "", tool: ToolLine(toolId: "2", name: "read_file", state: .failed, summary: "not found")),
            reply,
            ChatLine(role: .user, text: "[CONTEXT SUMMARY]: long summary\nmore"),
            ChatLine(role: .error, text: "turn failed"),
            ChatLine(role: .system, text: "/model ran"),
        ]
        let md = ChatExport.markdown(bot: bot, lines: lines, exportedAt: start, locale: posix)
        XCTAssertTrue(md.hasPrefix("# Bot Chat with Fake\n"))
        XCTAssertTrue(md.contains("## You · "))
        XCTAssertTrue(md.contains("## Fake · "))
        XCTAssertTrue(md.contains("> Tool: Ran git status (1.2s)"), md)
        XCTAssertTrue(md.contains("> Tool: read_file — not found (failed)"), md)
        XCTAssertTrue(md.contains("_Replied in 12s._"))
        XCTAssertTrue(md.contains("> _Hermes note: "))
        XCTAssertTrue(md.contains("> **Error:** turn failed"))
        XCTAssertTrue(md.contains("> /model ran"))
        XCTAssertFalse(md.contains("private reasoning"), "Thought rows are not exported")
        XCTAssertFalse(md.contains("--secret"), "tool arguments are not exported")
        XCTAssertFalse(md.contains("sk-live-123456789"))
        XCTAssertFalse(md.contains("abcdef123456"))
        XCTAssertFalse(md.contains("s3cr3t"))
        XCTAssertTrue(md.contains(Redaction.mask))
        XCTAssertEqual(md.components(separatedBy: "## Fake").count - 1, 1, "one heading per turn")
    }

    func testExportFilename() {
        let date = Date(timeIntervalSince1970: 1_762_430_400)
        XCTAssertEqual(ChatExport.filename(bot: bot, date: date, calendar: utc), "fake-bot-chat-2025-11-06.md")
        let odd = Bot(["name": "x", "display_name": "Ünïcode / Bot!"])!
        XCTAssertEqual(ChatExport.filename(bot: odd, date: date, calendar: utc), "n-code-bot-bot-chat-2025-11-06.md")
        let blank = Bot(["name": "x", "display_name": "!!!"])!
        XCTAssertEqual(ChatExport.filename(bot: blank, date: date, calendar: utc), "bot-bot-chat-2025-11-06.md")
    }
}
