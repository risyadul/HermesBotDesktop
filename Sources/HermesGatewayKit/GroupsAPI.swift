import Foundation

/// Thin raw wrappers over the `groups.*` RPCs (results stay `JSONValue`, open schema); the typed M2
/// calls in GroupChat.swift build on them. Shapes are documented in docs/groups-contract.md.
/// The M0-only calls (`profiles`, `create`, `disband`, `Member`) live in SpikeHarness/GroupsAPI+Spike.swift.
public struct GroupsAPI: Sendable {
    public let client: GatewayClient
    public init(client: GatewayClient) { self.client = client }

    public func capabilities() async throws -> JSONValue {
        try await client.call("groups.capabilities")
    }

    public func list(limit: Int = 50, offset: Int = 0) async throws -> JSONValue {
        try await client.call("groups.list", ["limit": .number(Double(limit)), "offset": .number(Double(offset))])
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
}
