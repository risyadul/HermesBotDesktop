import Foundation
import HermesGatewayKit

/// M0-only raw `groups.*` / `profiles.list` calls used by `RoundTrip`. The app and the other harnesses
/// use the typed calls in HermesGatewayKit (GroupChat.swift: `createRoom`, `disbandRoom`, `RoomMember`).
extension GroupsAPI {
    public func profiles(includeSessions: Bool = false) async throws -> JSONValue {
        try await client.call("profiles.list", ["include_sessions": .bool(includeSessions)])
    }

    public struct Member: Sendable {
        public var memberId: String, profile: String, handle: String, displayName: String?
        public init(memberId: String, profile: String, handle: String, displayName: String? = nil) {
            self.memberId = memberId; self.profile = profile; self.handle = handle; self.displayName = displayName
        }
        var json: JSONValue {
            var o: [String: JSONValue] = ["member_id": .string(memberId), "profile": .string(profile),
                                          "handle": .string(handle)]
            if let displayName { o["display_name"] = .string(displayName) }
            return .object(o)
        }
    }

    /// Idempotent on (room_id, name, members): repeating returns the room with `idempotent: true`.
    public func create(roomId: String, name: String, members: [Member]) async throws -> JSONValue {
        try await client.call("groups.create", ["room_id": .string(roomId), "name": .string(name),
                                                "members": .array(members.map(\.json))])
    }

    public func disband(roomId: String) async throws -> JSONValue {
        try await client.call("groups.disband", ["room_id": .string(roomId)])
    }
}
