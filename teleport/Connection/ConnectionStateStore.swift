import Foundation

/// Thread-safe state storage and fan-out used by providers whose blocking backend
/// work runs on a private serial DispatchQueue.
nonisolated final class ConnectionStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectionState
    private var reconnectFailure: ConnectionFailure?
    private var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(initialState: ConnectionState) {
        state = initialState
    }

    func current() -> ConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ state: ConnectionState) {
        lock.lock()
        self.state = state
        if case .failed(let failure) = state, failure.requiresExplicitReconnect { reconnectFailure = failure }
        let currentContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in currentContinuations {
            continuation.yield(state)
        }
    }

    func validateReconnect(isAutomatic: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if isAutomatic, let reconnectFailure { throw reconnectFailure }
        if !isAutomatic { reconnectFailure = nil }
    }

    func stream() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }

            // Registration and the initial yield share one critical section so an
            // update cannot be delivered before the stream's initial value.
            lock.lock()
            continuations[id] = continuation
            continuation.yield(state)
            lock.unlock()
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
