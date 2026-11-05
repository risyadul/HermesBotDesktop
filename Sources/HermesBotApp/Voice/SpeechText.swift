import Foundation
import HermesGatewayKit

/// B17: what Read Aloud says for a Bot Chat reply. The markdown is flattened to its words (links read as
/// their text, inline code as written), fenced code blocks and `MEDIA:` attachments are left out, and only
/// reply text is read: Thought rows, tool rows, errors and notes never are.
enum SpeechText {
    /// The spoken form of one reply's markdown; empty when nothing is left (a reply that is only code).
    static func speakable(_ markdown: String) -> String {
        let parts = MediaTags.split(markdown)
        let blocks = MarkdownBlock.parse(parts.media.isEmpty ? markdown : parts.text)
        return blocks.compactMap(spoken).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func spoken(_ block: MarkdownBlock) -> String? {
        switch block {
        case .code, .rule: return nil
        case .list(_, _, let items):
            return items.map { $0.compactMap(spoken).joined(separator: "\n") }.joined(separator: "\n")
        case .quote(let blocks): return blocks.compactMap(spoken).joined(separator: "\n")
        default: return block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The reply texts of the turn that holds `id` (the bot text lines between two user lines), in order.
    /// Empty when `id` is not a bot text line.
    static func turn(containing id: UUID, in lines: [ChatLine]) -> [ChatLine] {
        guard let i = lines.firstIndex(where: { $0.id == id }), lines[i].role == .bot else { return [] }
        let start = lines[..<i].lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        let end = lines[(i + 1)...].firstIndex(where: { $0.role == .user }) ?? lines.endIndex
        return lines[start..<end].filter { $0.role == .bot && !$0.streaming }
    }

    /// The finished last turn's reply texts, for "Read replies aloud automatically". Empty while the turn
    /// streams, when it ended in an error (stopped, failed), or when it has no reply text.
    static func lastTurn(_ lines: [ChatLine]) -> [ChatLine] {
        let start = lines.lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        let turn = lines[start...]
        guard !turn.contains(where: { $0.role == .error || $0.streaming }) else { return [] }
        return turn.filter { $0.role == .bot }
    }

    /// The spoken text of several reply lines, one paragraph each.
    static func spoken(_ lines: [ChatLine]) -> String {
        lines.map { speakable($0.text) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
