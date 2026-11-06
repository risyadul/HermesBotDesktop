import HermesGatewayKit
import Foundation

enum BotTimelineRow: Identifiable, Equatable {
    case message(TranscriptItem)
    case request(ServerRequest)

    var id: AnyHashable {
        switch self {
        case .message(let item): return AnyHashable(item.id)
        case .request(let request): return AnyHashable("request-\(request.id)")
        }
    }
}

/// No materialization of the frozen history when a token only changes the active suffix.
struct BotTimelineRows: RandomAccessCollection {
    let messages: BotTranscriptItems
    let requests: [ServerRequest]
    var startIndex: Int { 0 }
    var endIndex: Int { messages.count + requests.count }
    subscript(index: Int) -> BotTimelineRow {
        index < messages.count ? .message(messages[index]) : .request(requests[index - messages.count])
    }

    struct Structure: Hashable {
        let history: ObjectIdentifier
        let active: [UUID]
        let requests: [String]
    }

    func structure(history: BotTranscriptHistory) -> Structure {
        Structure(history: ObjectIdentifier(history), active: messages.tail.map(\.id), requests: requests.map(\.id))
    }
}

enum RoomTimelineRow: Identifiable, Equatable {
    case message(RoomRow)
    case action(RoomPendingAction)

    var id: AnyHashable {
        switch self {
        case .message(let row): return AnyHashable(row.id)
        case .action(let action): return AnyHashable(action.id)
        }
    }
}

struct RoomTimelineRows: RandomAccessCollection {
    let messages: [RoomRow]
    let actions: [RoomPendingAction]
    var startIndex: Int { 0 }
    var endIndex: Int { messages.count + actions.count }
    subscript(index: Int) -> RoomTimelineRow {
        index < messages.count ? .message(messages[index]) : .action(actions[index - messages.count])
    }

    struct Structure: Hashable {
        let snapshot: ObjectIdentifier
        let actions: [String]
    }
}

enum ThreadTimelineRow: Identifiable, Equatable {
    case anchor(RoomRow)
    case divider(String)
    case message(RoomRow)

    var id: AnyHashable {
        switch self {
        case .anchor(let row): return AnyHashable("anchor-\(row.id)")
        case .divider: return AnyHashable("thread-divider")
        case .message(let row): return AnyHashable(row.id)
        }
    }
}

struct ThreadTimelineRows: RandomAccessCollection {
    let anchor: RoomRow?
    let messages: [RoomRow]
    let divider: String
    var startIndex: Int { 0 }
    var endIndex: Int { messages.count + (anchor == nil ? 0 : 2) }
    subscript(index: Int) -> ThreadTimelineRow {
        if let anchor {
            if index == 0 { return .anchor(anchor) }
            if index == 1 { return .divider(divider) }
            return .message(messages[index - 2])
        }
        return .message(messages[index])
    }
}
