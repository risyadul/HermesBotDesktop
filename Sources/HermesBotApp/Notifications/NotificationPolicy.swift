import Foundation
import HermesGatewayKit

// D1 / D2: when to notify, what a notification says, and the Dock badge count. Pure and unit tested; the
// system side is UserNotificationPoster.swift, the wiring NotificationCoordinator.swift.

/// Something that may deserve a native notification.
enum AttentionEvent: Equatable {
    /// A Bot Chat reply finished (`message.complete`).
    case botReplied(bot: String, title: String, text: String)
    /// A Bot Chat request card is waiting: approval, clarifying question, or a sudo/secret prompt.
    case botRequest(bot: String, title: String, request: ServerRequest)
    /// A room member's hidden session waits on an approval (`groups.state` pending action).
    case roomApproval(roomId: String, roomName: String, member: String, approval: RoomApproval)
    /// A room discussion settled after a member addressed `@user`.
    case roomMention(roomId: String, roomName: String, discussion: String, author: String, text: String)
}

enum NotificationPolicy {
    /// `@AppStorage` key of the "Notifications" setting (default on). The Settings toggle itself is not
    /// built yet; `defaults write io.github.risyadul.hermesbot notificationsEnabled -bool false` turns them off.
    static let enabledKey = "notificationsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Only while the app is not frontmost, only when enabled. A bot hidden from the roster never notifies
    /// about its replies (Desktop: "a hidden bot never toasts"); requests and approvals still do, because the
    /// bot is blocked on the user.
    static func shouldPost(_ event: AttentionEvent, appActive: Bool, enabled: Bool, botHidden: Bool) -> Bool {
        guard enabled, !appActive else { return false }
        if case .botReplied = event, botHidden { return false }
        if case .botReplied(_, _, let text) = event, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }
}

/// What one notification shows. `id` is stable per thing, so a repeat replaces instead of stacking, and
/// the coordinator can withdraw it once it is answered elsewhere.
struct NotificationContent: Equatable {
    enum Category: String { case approval = "hba.approval" }

    let id: String
    let title: String
    let body: String
    /// Set only when Approve / Deny can be answered from the notification.
    let category: Category?
    let userInfo: [String: String]

    static let bodyLimit = 180
    static let approveAction = "hba.approve"
    static let denyAction = "hba.deny"

    static func id(_ event: AttentionEvent) -> String {
        switch event {
        case .botReplied(let bot, _, _): return "chat.reply.\(bot)"
        case .botRequest(let bot, _, let r): return requestId(bot: bot, request: r.id)
        case .roomApproval(let room, _, _, let a): return roomApprovalId(room: room, approval: a)
        case .roomMention(let room, _, let discussion, _, _): return "room.mention.\(room).\(discussion)"
        }
    }

    static func requestId(bot: String, request: String) -> String { "chat.request.\(bot).\(request)" }
    static func roomApprovalId(room: String, approval: RoomApproval) -> String {
        "room.approval.\(room).\(approval.memberId).\(approval.requestId)"
    }

    init(id: String, title: String, body: String, category: Category?, userInfo: [String: String]) {
        self.id = id; self.title = title; self.body = body; self.category = category; self.userInfo = userInfo
    }

    init(_ event: AttentionEvent) {
        id = Self.id(event)
        switch event {
        case .botReplied(let bot, let title, let text):
            self.title = title
            body = Self.clip(text)
            category = nil
            userInfo = [NotificationRoute.targetKey: "bot:\(bot)"]
        case .botRequest(let bot, let botTitle, let r):
            var info = [NotificationRoute.targetKey: "bot:\(bot)", NotificationRoute.requestKey: r.id]
            switch r.kind {
            case .approval(let a):
                title = "\(botTitle) needs your approval"
                body = Self.clip(a.description.isEmpty ? a.command : "\(a.description): \(a.command)")
                let answerable = a.choices.contains(.once) && a.choices.contains(.deny)
                category = answerable ? .approval : nil
                if answerable { info[NotificationRoute.kindKey] = NotificationRoute.chatApproval }
            case .clarify(let c):
                title = "\(botTitle) has a question"
                body = Self.clip(c.questions.first?.question ?? "Answer it in Bot Chat.")
                category = nil
            case .value(let v):
                title = "\(botTitle) needs your input"
                body = v.kind == .sudo ? "A sudo password is needed. Answer it in Bot Chat." : "A secret value is needed. Answer it in Bot Chat."
                category = nil
            case .notShown, .unknown:
                title = "\(botTitle) needs your answer"
                body = "Answer it in Bot Chat."
                category = nil
            }
            userInfo = info
        case .roomApproval(let room, let roomName, let member, let a):
            title = "\(member) needs your approval"
            body = Self.clip("\(roomName): " + ([a.description, a.command].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")))
            let answerable = a.choices.contains("once") && a.choices.contains("deny")
            category = answerable ? .approval : nil
            var info = [NotificationRoute.targetKey: "room:\(room)", NotificationRoute.requestKey: a.requestId,
                        NotificationRoute.memberKey: a.memberId]
            if answerable { info[NotificationRoute.kindKey] = NotificationRoute.roomApproval }
            userInfo = info
        case .roomMention(let room, let roomName, _, let author, let text):
            title = "\(author) needs you in \(roomName)"
            body = Self.clip(text)
            category = nil
            userInfo = [NotificationRoute.targetKey: "room:\(room)"]
        }
    }

    /// One line, whitespace collapsed, at most `bodyLimit` characters.
    static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > bodyLimit else { return flat }
        return String(flat.prefix(bodyLimit - 1)) + "…"
    }
}

/// What a click or an action button on a notification asks for.
enum NotificationRoute: Equatable {
    case open(SidebarItem)
    case answerChat(bot: String, requestId: String, approve: Bool)
    case answerRoom(roomId: String, memberId: String, requestId: String, approve: Bool)
    /// K9: a watched kanban card's notification (KanbanCardNotice).
    case openCard(board: String, task: String)

    static let targetKey = "target"
    static let requestKey = "request"
    static let memberKey = "member"
    static let kindKey = "kind"
    static let chatApproval = "chat-approval"
    static let roomApproval = "room-approval"

    /// `action` is the notification action identifier (Approve / Deny, or the default click).
    static func parse(action: String, userInfo: [String: String]) -> NotificationRoute? {
        if let card = KanbanCardNotice.route(userInfo) { return card }
        guard let target = userInfo[targetKey].flatMap(item) else { return nil }
        let approve: Bool
        switch action {
        case NotificationContent.approveAction: approve = true
        case NotificationContent.denyAction: approve = false
        default: return .open(target)
        }
        guard let request = userInfo[requestKey], !request.isEmpty else { return .open(target) }
        switch (target, userInfo[kindKey]) {
        case (.bot(let bot), chatApproval?): return .answerChat(bot: bot, requestId: request, approve: approve)
        case (.room(let room), roomApproval?):
            return .answerRoom(roomId: room, memberId: userInfo[memberKey] ?? "", requestId: request, approve: approve)
        default: return .open(target)
        }
    }

    static func item(_ target: String) -> SidebarItem? {
        if target.hasPrefix("bot:"), target.count > 4 { return .bot(String(target.dropFirst(4))) }
        if target.hasPrefix("room:"), target.count > 5 { return .room(String(target.dropFirst(5))) }
        return nil
    }
}

/// D2: the Dock badge counts what waits on the user: Bot Chat request cards (approvals, questions,
/// sudo/secret prompts) and room approvals.
enum DockBadge {
    static func waiting(_ requests: [ServerRequest]) -> Int {
        requests.filter {
            switch $0.kind {
            case .approval, .clarify, .value: return true
            case .notShown, .unknown: return false
            }
        }.count
    }

    static func count(chatRequests: [String: Int], roomApprovals: [String: Int]) -> Int {
        chatRequests.values.reduce(0, +) + roomApprovals.values.reduce(0, +)
    }

    static func label(_ count: Int) -> String? { count > 0 ? "\(count)" : nil }
}

/// `@user` in a member's message: the bot is addressing the person (Desktop's mention grammar,
/// `group-rounds.ts`: `@([a-z0-9][a-z0-9._-]*)`, case-insensitive; trailing `.`/`-`/`_` are punctuation).
enum UserMention {
    static func mentionsUser(_ text: String) -> Bool {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            defer { i += 1 }
            guard chars[i] == "@" else { continue }
            if i > 0, isHandleChar(chars[i - 1]) { continue }  // an e-mail address, not a mention
            var j = i + 1
            var handle = ""
            while j < chars.count, isHandleChar(chars[j]) { handle.append(chars[j]); j += 1 }
            while let last = handle.last, ".-_".contains(last) { handle.removeLast() }
            if handle.lowercased() == "user" { return true }
        }
        return false
    }

    private static func isHandleChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
    }
}
