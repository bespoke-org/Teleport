import Foundation

/// Asynchronous connection boundary consumed by upper application layers.
nonisolated protocol ConnectionProvider: Sendable {
    func currentState() async -> ConnectionState
    func stateUpdates() -> AsyncStream<ConnectionState>
    /// Cancellation stops pre-flight or rolls back a partial start. A backend
    /// past its commit point may finish successfully before returning instead.
    func connect(_ request: ConnectionRequest) async throws
    func disconnect() async throws
}
