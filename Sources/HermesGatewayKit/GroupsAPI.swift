import Foundation

/// Thin typed wrappers over the `groups.*` / `profiles.list` RPCs used by the M0 round-trip.
/// Shapes are documented in docs/groups-contract.md; results stay `JSONValue` (open schema).
public struct GroupsAPI: Sendable {
    public let client: GatewayClient
    public init(client: GatewayClient) { self.client = client }

    public func capabilities() async throws -> JSONValue {
        try await client.call("groups.capabilities")
    }

    public func profiles(includeSessions: Bool = false) async throws -> JSONValue {
        try await client.call("profiles.list", ["include_sessions": .bool(includeSessions)])
    }

    public func list(limit: Int = 50, offset: Int = 0) async throws -> JSONValue {
        try await client.call("groups.list", ["limit": .number(Double(limit)), "offset": .number(Double(offset))])
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

    /// `eventId` is the client retry key; the server stores `user:<sha256(eventId)>`.
    /// The result only proves the `message.user` append, NOT that any bot turn ran.
    public func send(roomId: String, eventId: String, text: String, threadId: String) async throws -> JSONValue {
        try await client.call("groups.send", ["room_id": .string(roomId), "event_id": .string(eventId),
                                              "payload": ["text": .string(text), "thread_id": .string(threadId)]])
    }

    public func state(roomId: String) async throws -> JSONValue {
        try await client.call("groups.state", ["room_id": .string(roomId)])
    }

    public func log(roomId: String, sinceSeq: Int, limit: Int = 100) async throws -> JSONValue {
        try await client.call("groups.log", ["room_id": .string(roomId), "since_seq": .number(Double(sinceSeq)),
                                             "limit": .number(Double(limit))])
    }

    public func stop(roomId: String, cancelId: String) async throws -> JSONValue {
        try await client.call("groups.stop", ["room_id": .string(roomId), "cancel_id": .string(cancelId)])
    }

    public func disband(roomId: String) async throws -> JSONValue {
        try await client.call("groups.disband", ["room_id": .string(roomId)])
    }
}
