import Foundation

/// Serializes every connection operation for one mode and publishes the resulting
/// state. Operations run in submission order: each link of the chain awaits the
/// previous one, so a disconnect issued during a connect runs after it instead of
/// being rejected. Concrete process, proxy, helper, and route details do not cross
/// this boundary.
nonisolated final class BackendConnectionProvider: ConnectionProvider, @unchecked Sendable {
    private let mode: ConnectionMode
    private let backend: ConnectionBackend
    private let stateStore: ConnectionStateStore
    private let chainLock = NSLock()
    private var tail: Task<Void, Never>?

    init(mode: ConnectionMode, backend: ConnectionBackend) {
        self.mode = mode
        self.backend = backend
        // Where the backend stands can only be answered asynchronously (VPN mode
        // asks the privileged helper over XPC), so the provider starts out
        // resolving and publishes the answer as the first queued operation.
        stateStore = ConnectionStateStore(initialState: .preparing)
        enqueueDetached { [backend, stateStore, mode] in
            if await backend.hasActiveRuntimeSession() {
                stateStore.update(
                    .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
                )
                return
            }
            guard await backend.hasRestorableState() else {
                stateStore.update(.idle)
                return
            }
            do {
                try await backend.restorePreviousState()
                stateStore.update(.idle)
            } catch {
                stateStore.update(.failed(ConnectionFailure(error: error)))
            }
        }
    }

    func currentState() async -> ConnectionState {
        stateStore.current()
    }

    func stateUpdates() -> AsyncStream<ConnectionState> {
        stateStore.stream()
    }

    func connect(_ request: ConnectionRequest) async throws {
        try await enqueue { [backend, stateStore, mode] in
            let previousState = stateStore.current()
            stateStore.update(.preparing)
            stateStore.update(.connecting)

            do {
                if case .connected = previousState {
                    try await backend.reconnect(request)
                } else {
                    try await backend.start(request)
                }
                stateStore.update(
                    .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
                )
            } catch {
                stateStore.update(.failed(ConnectionFailure(error: error)))
                throw error
            }
        }
    }

    func disconnect() async throws {
        try await enqueue { [backend, stateStore] in
            if case .idle = stateStore.current() {
                return
            }

            stateStore.update(.disconnecting)
            do {
                try await backend.stop()
                stateStore.update(.idle)
            } catch {
                stateStore.update(.failed(ConnectionFailure(error: error)))
                throw error
            }
        }
    }

    /// Appends `operation` to the serial chain and awaits its own outcome. The
    /// chain is unstructured on purpose: cancelling the caller must not abandon a
    /// half-applied proxy or tunnel mutation.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        chainLock.lock()
        let previous = tail
        let work = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        chainLock.unlock()

        return try await work.value
    }

    private func enqueueDetached(_ operation: @escaping @Sendable () async -> Void) {
        chainLock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        chainLock.unlock()
    }
}
