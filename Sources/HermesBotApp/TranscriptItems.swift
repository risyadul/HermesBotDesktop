import Foundation
import HermesGatewayKit
import SwiftUI

/// The Bot Chat transcript as display items (unit tested): runs of two or more adjacent tool calls fold
/// into one collapsible group, as Hermes Desktop does (`fallback.tsx:1012`, `1060-1106`), and only the
/// first bot-side item of a turn (text, Thought or tools) carries the avatar and name; the rest of the turn
/// lines up under it.
enum TranscriptItem: Identifiable, Equatable {
    case line(ChatLine, header: Bool)
    case tools([ChatLine], header: Bool)

    var id: UUID {
        switch self {
        case .line(let l, _): return l.id
        case .tools(let ls, _): return ls[0].id
        }
    }

    /// Rough height in text lines, for `EagerTail`.
    var approximateLines: Int {
        switch self {
        case .line(let l, _):
            switch l.role {
            case .thought, .tool: return 2
            default: return EagerTail.lines(l.text)
            }
        case .tools: return 2
        }
    }

    static func build(_ lines: [ChatLine]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var headerShown = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard Self.isBotSide(line.role) else {
                out.append(.line(line, header: false))
                headerShown = false
                i += 1
                continue
            }
            let header = !headerShown
            headerShown = true
            if line.role == .tool {
                var j = i
                while j < lines.count && lines[j].role == .tool { j += 1 }
                let run = Array(lines[i..<j])
                out.append(run.count >= 2 ? .tools(run, header: header) : .line(line, header: header))
                i = j
            } else {
                out.append(.line(line, header: header))
                i += 1
            }
        }
        return out
    }

    static func isBotSide(_ role: ChatLine.Role) -> Bool {
        role == .bot || role == .thought || role == .tool
    }

    /// Thought and tool rows: one-line disclosure rows that read as a list inside a turn.
    var isCompact: Bool {
        switch self {
        case .tools: return true
        case .line(let l, _): return l.role == .thought || l.role == .tool
        }
    }

    var isBotSide: Bool {
        switch self {
        case .tools: return true
        case .line(let l, _): return Self.isBotSide(l.role)
        }
    }

    /// Space above each item. Thought and tool rows of a turn stack tightly (their own row padding is the
    /// gap), as in Hermes Desktop; text next to them sits a little apart; messages keep the timeline gap.
    static func gaps(_ items: [TranscriptItem]) -> [UUID: CGFloat] {
        var out: [UUID: CGFloat] = [:]
        for (i, item) in items.enumerated() {
            guard i > 0 else { out[item.id] = 0; continue }
            let prev = items[i - 1]
            let sameTurn = item.isBotSide && prev.isBotSide
            if sameTurn && item.isCompact && prev.isCompact {
                out[item.id] = 0
            } else if sameTurn && (item.isCompact || prev.isCompact) {
                out[item.id] = DS.Space.s1
            } else {
                out[item.id] = DS.Space.timeline
            }
        }
        return out
    }
}

/// Which Thought, tool rows and tool groups the user opened or closed, keyed by transcript line id. Kept
/// outside the row views because a row's view is recreated when its item changes shape (a single tool
/// call becomes a group when a second call arrives, the turn header moves, the lazy/eager split moves),
/// which would reset view `@State`.
@MainActor
final class DisclosureStore: ObservableObject {
    enum Kind: String { case row, group, thought }
    @Published private var states: [String: Bool] = [:]

    private func key(_ kind: Kind, _ id: UUID) -> String { "\(kind.rawValue):\(id.uuidString)" }

    /// The user's choice, else `fallback`. A group with no choice of its own opens if its first call was
    /// open as a single row, so expanding a running call survives the next call folding them into a group.
    func isOpen(_ kind: Kind, _ id: UUID, fallback: Bool = false) -> Bool {
        if let v = states[key(kind, id)] { return v }
        if kind == .group, let v = states[key(.row, id)] { return v }
        return fallback
    }

    func set(_ kind: Kind, _ id: UUID, _ open: Bool) { states[key(kind, id)] = open }
}
