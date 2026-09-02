import Foundation

/// Asynchronous connection boundary consumed by upper application layers.
protocol ConnectionProvider: Sendable {
    func currentState() async -> ConnectionState
    func stateUpdates() -> AsyncStream<ConnectionState>
    func connect(_ request: ConnectionRequest) async throws
    func disconnect() async throws
}
