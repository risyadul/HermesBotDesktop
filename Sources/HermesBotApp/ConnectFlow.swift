import Foundation

/// Connect-then-load with no half-open leftovers. `AppModel.connect` opens the backend connection and
/// then loads the bot list over it; when that load fails, the connection it just opened is released
/// before the error surfaces. A failed attempt therefore leaves nothing behind, and Try Again (which
/// calls `connect` again) starts over from discovery instead of being refused by a stale connection.
///
/// Releasing goes through `Backend.shutdown`: it closes this app's socket and stops the backend only
/// when this app spawned it. An attached backend (Hermes Desktop, another `hermes serve`) keeps running.
@MainActor
enum ConnectFlow {
    static func open<Connection>(
        connect: @MainActor () async throws -> Connection,
        load: @MainActor (Connection) async throws -> Void,
        release: @MainActor (Connection) async -> Void
    ) async throws -> Connection {
        let connection = try await connect()
        do {
            try await load(connection)
        } catch {
            await release(connection)
            throw error
        }
        return connection
    }
}
