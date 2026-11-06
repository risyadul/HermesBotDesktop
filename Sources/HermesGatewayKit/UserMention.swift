import Foundation

/// The one `@handle` grammar of the app, shared by the room digest (`RoomDigest.addressesUser`, the sidebar's
/// "needs you"), the notification watcher (`RoomAttention`) and the transcript's mention highlighting
/// (`TextStyling.highlightMentions`), so a message that badges a room is the message that shows `@user` in
/// the attention colour and the one that notifies.
///
/// A mention is `@` followed by a handle (`[A-Za-z0-9][A-Za-z0-9._:-]*`, the room identifier charset), with
/// trailing `.`, `-`, `_` and `:` treated as punctuation (`@user.` and `@user:` end a sentence or address the
/// user; Desktop `group-rounds.ts` trims the same way). An `@` straight after a letter, digit or one of
/// `._%+-@` is part of an e-mail address or another token, not a mention (`me@user`).
///
/// `@user` (any case) is the human. A room member whose own handle is `user` makes `@user` that bot instead.
public enum UserMention {
    public struct Mention: Equatable, Sendable {
        /// The handle without `@`, as written (trailing punctuation dropped).
        public let handle: String
        /// From `@` to the end of the handle.
        public let range: Range<String.Index>

        public var isUser: Bool { UserMention.isUser(handle) }
    }

    public static func isUser(_ handle: String) -> Bool { handle.lowercased() == "user" }

    /// Every `@handle` in `text`, in order.
    public static func mentions(in text: String) -> [Mention] {
        var out: [Mention] = []
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            let afterToken = i > text.startIndex && continuesToken(text[text.index(before: i)])
            guard text[i] == "@", !afterToken, next < text.endIndex, isHandleStart(text[next]) else { i = next; continue }
            var j = next, end = next
            while j < text.endIndex, isHandleChar(text[j]) {
                if isHandleStart(text[j]) { end = text.index(after: j) }
                j = text.index(after: j)
            }
            out.append(Mention(handle: String(text[next..<end]), range: i..<end))
            i = j
        }
        return out
    }

    /// The text addresses the human: an `@user` mention, unless a member of the room is handled `user`.
    public static func mentionsUser(_ text: String, memberHandles: [String] = []) -> Bool {
        guard text.contains("@"), !memberHandles.contains(where: isUser) else { return false }
        return mentions(in: text).contains(where: \.isUser)
    }

    private static func isHandleStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    private static func isHandleChar(_ c: Character) -> Bool { isHandleStart(c) || "._:-".contains(c) }

    /// A character before `@` that makes it part of another token (an e-mail local part, `@@`).
    private static func continuesToken(_ c: Character) -> Bool { c.isLetter || c.isNumber || "._%+-@".contains(c) }
}
