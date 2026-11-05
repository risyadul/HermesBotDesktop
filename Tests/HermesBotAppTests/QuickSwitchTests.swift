import Foundation
import SwiftUI
import XCTest
@testable import HermesBotApp
@testable import HermesGatewayKit

/// D5 (⌘1…9, ⌘K quick switcher) and D10 (Search Messages): pure ranking and search, the app's search sources
/// and the jump to a found message. Headless.
@MainActor
final class QuickSwitchTests: XCTestCase {
    private func bot(_ name: String, title: String? = nil, description: String? = nil) -> Bot {
        var v: [String: JSONValue] = ["name": .string(name)]
        if let title { v["display_name"] = .string(title) }
        if let description { v["description"] = .string(description) }
        return Bot(.object(v))!
    }

    // MARK: ⌘1…9

    func testShortcutsPickRoomsAndBotsInSidebarOrder() {
        let order: [SidebarItem] = [.room("r1"), .bot("alpha"), .board("default"), .archive("k"), .bot("beta")]
        XCTAssertEqual(SidebarShortcuts.targets(order), [.room("r1"), .bot("alpha"), .bot("beta")])
        XCTAssertEqual(SidebarShortcuts.item(1, in: order), .room("r1"))
        XCTAssertEqual(SidebarShortcuts.item(3, in: order), .bot("beta"))
        XCTAssertNil(SidebarShortcuts.item(4, in: order))
        XCTAssertNil(SidebarShortcuts.item(0, in: order))
        XCTAssertNil(SidebarShortcuts.item(1, in: []), "an empty sidebar selects nothing")
        let many = (0..<12).map { SidebarItem.bot("b\($0)") }
        XCTAssertEqual(SidebarShortcuts.targets(many).count, 9)
    }

    func testSelectShortcutSelectsTheNthRow() {
        let app = AppModel()
        app.sidebarOrder = [.room("r1"), .bot("alpha")]
        app.selectShortcut(2)
        XCTAssertEqual(app.selection, .bot("alpha"))
        app.selectShortcut(5)
        XCTAssertEqual(app.selection, .bot("alpha"), "past the end: unchanged")
    }

    // MARK: fuzzy

    func testFuzzyMatchNeedsEveryCharacterInOrder() {
        XCTAssertNotNil(FuzzyMatch.score("rsch", "Research crew"))
        XCTAssertNil(FuzzyMatch.score("hcsr", "Research crew"))
        XCTAssertNil(FuzzyMatch.score("xyz", "Research crew"))
        XCTAssertEqual(FuzzyMatch.score("  ", "anything"), 0)
        XCTAssertNotNil(FuzzyMatch.score("@alpha", "alpha"), "a leading @ is ignored")
        XCTAssertNotNil(FuzzyMatch.score("ALP", "alpha"), "case-insensitive")
    }

    func testFuzzyRanksPrefixAndWordStartsAboveScatteredMatches() {
        let prefix = FuzzyMatch.score("ops", "Ops room")!
        let wordStart = FuzzyMatch.score("ops", "Daily ops")!
        let scattered = FuzzyMatch.score("ops", "Overlapping specs")!
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, scattered)
    }

    func testCandidatesAndResults() {
        let rooms = [RoomFixtures.room("hba-1", name: "Launch plan")]
        let bots = [bot("alpha", title: "Alpha"), bot("ghost", title: "Ghost"), bot("beta", title: "Beta", description: "writes docs")]
        let boards = [KanbanSidebarRow(slug: "default", name: "Default board", running: 0, blocked: 0, total: 0)]
        let all = QuickSwitch.candidates(rooms: rooms, bots: bots, hidden: { $0 == "ghost" }, boards: boards)
        XCTAssertEqual(all.map(\.item), [.room("hba-1"), .bot("alpha"), .bot("beta"), .bot("ghost"), .board("default")],
                       "sidebar order; hidden bots last")
        XCTAssertEqual(all[3].subtitle, "@ghost · hidden")
        XCTAssertEqual(QuickSwitch.results("", all).count, all.count, "no query: everything")
        XCTAssertEqual(QuickSwitch.results("lnch", all).first?.item, .room("hba-1"))
        XCTAssertEqual(QuickSwitch.results("docs", all).first?.item, .bot("beta"), "description is searched too")
        XCTAssertEqual(QuickSwitch.results("@alpha", all).first?.item, .bot("alpha"), "the bot's own title beats a room member")
        XCTAssertEqual(QuickSwitch.results("default", all).first?.item, .board("default"))
        XCTAssertTrue(QuickSwitch.results("zzzz", all).isEmpty)
        XCTAssertEqual(QuickSwitch.results("a", all, limit: 2).count, 2)
    }

    // MARK: message search

    private let sources: [MessageSearch.Source] = [
        MessageSearch.Source(item: .room("r1"), title: "Launch", messages: [
            .init(anchor: .roomSeq(1), author: "You", text: "Plan the release notes"),
            .init(anchor: .roomSeq(2), author: "Alpha", text: "Release notes drafted, see the café doc"),
        ]),
        MessageSearch.Source(item: .bot("beta"), title: "Beta", messages: [
            .init(anchor: .chatLine(UUID()), author: "Beta", text: "No notes here"),
        ]),
    ]

    func testSearchMatchesEveryTermNewestFirst() {
        let hits = MessageSearch.search("release NOTES", in: sources)
        XCTAssertEqual(hits.map(\.anchor), [.roomSeq(2), .roomSeq(1)], "newest first within a room")
        XCTAssertEqual(hits.first?.sourceTitle, "Launch")
        XCTAssertEqual(hits.first?.author, "Alpha")
        XCTAssertEqual(MessageSearch.search("notes", in: sources).count, 3)
        XCTAssertEqual(MessageSearch.search("cafe", in: sources).map(\.anchor), [.roomSeq(2)], "diacritic-insensitive")
        XCTAssertTrue(MessageSearch.search("n", in: sources).isEmpty, "a one-character query searches nothing")
        XCTAssertEqual(MessageSearch.search("notes", in: sources, perSource: 1).count, 2)
        XCTAssertEqual(MessageSearch.search("notes", in: sources, limit: 1).count, 1)
    }

    func testSnippetShowsContextAroundTheMatch() {
        let text = String(repeating: "a ", count: 100) + "needle\n\nin   the " + String(repeating: "b ", count: 100)
        let s = MessageSearch.snippet(text, around: "NEEDLE", radius: 10)
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
        XCTAssertTrue(s.contains("needle in the"), "whitespace collapsed: \(s)")
        XCTAssertEqual(MessageSearch.snippet("short needle", around: "needle"), "short needle")
        XCTAssertEqual(MessageSearch.snippet("abc", around: "zzz"), "abc")
    }

    func testHighlightBoldsEveryTerm() {
        let a = CommandPaletteView.highlighted("Release notes, more notes", terms: ["notes"])
        let bold = a.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(a[$0.range].characters) }
        XCTAssertEqual(bold, ["notes", "notes"])
    }

    func testChatSourceKeepsOnlyUserAndBotMessages() {
        let lines = [ChatLine(role: .user, text: "hello"), ChatLine(role: .tool, text: "ls"), ChatLine(role: .bot, text: "hi there"),
                     ChatLine(role: .system, text: "/help"), ChatLine(role: .bot, text: "")]
        let s = MessageSearch.source(bot: bot("alpha", title: "Alpha"), lines: lines)
        XCTAssertEqual(s.item, .bot("alpha"))
        XCTAssertEqual(s.messages.map(\.author), ["You", "Alpha"])
        XCTAssertEqual(s.messages.map(\.anchor), [.chatLine(lines[0].id), .chatLine(lines[2].id)])
    }

    func testRoomSourceDropsAttachmentListsAndStatusRows() {
        let room = RoomFixtures.room("hba-1")
        let withFiles = RoomAttachments.compose(text: "see attached", paths: ["/tmp/a.txt"])
        let events = [RoomFixtures.user(5, withFiles), RoomFixtures.member(6, "alpha", "done"), RoomFixtures.settled(7)]
        let s = MessageSearch.source(room: room, events: events)
        XCTAssertEqual(s.messages.map(\.anchor), [.roomSeq(5), .roomSeq(6)], "a log tail (not from seq 1) still reads")
        XCTAssertEqual(s.messages.first?.text, "see attached")
        XCTAssertEqual(s.messages.last?.author, "Alpha")
    }

    func testAppSearchesOpenRoomsAndTheBackgroundTailOfOthers() {
        let app = AppModel()
        let room = RoomFixtures.room("hba-1", name: "Launch")
        app.rooms = [room]
        app.roomDigests.absorb(roomId: room.roomId, room: room, events: [RoomFixtures.member(3, "alpha", "ship it friday")],
                               driver: nil, onScreen: false, cursor: 3)
        let hits = MessageSearch.search("friday", in: app.searchSources)
        XCTAssertEqual(hits.map(\.item), [.room("hba-1")])
        app.open(hits[0])
        XCTAssertEqual(app.selection, .room("hba-1"))
        XCTAssertEqual(app.jumps.take(for: .room("hba-1")), .roomSeq(3))
        XCTAssertNil(app.jumps.take(for: .room("hba-1")), "taken once")
        app.roomDigests.forget(room.roomId)
    }

    func testJumpIsOnlyForItsOwnPane() {
        let jumps = MessageJumpCenter()
        jumps.request(.bot("alpha"), .roomSeq(1))
        XCTAssertNil(jumps.take(for: .bot("beta")))
        XCTAssertEqual(jumps.take(for: .bot("alpha")), .roomSeq(1))
    }

    func testPaletteRefusesWhileAnotherSheetIsUp() {
        let app = AppModel()
        app.showCreateRoom = true
        app.openPalette(.switcher)
        XCTAssertNil(app.palette)
        app.showCreateRoom = false
        app.openPalette(.messages)
        XCTAssertEqual(app.palette, .messages)
    }
}
