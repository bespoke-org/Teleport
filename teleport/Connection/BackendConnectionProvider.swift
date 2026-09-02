import Foundation

/// Serializes the asynchronous provider contract around the current synchronous
/// backend implementations. Concrete process, proxy, helper, and route details do
/// not cross this boundary.
final class BackendConnectionProvider: ConnectionProvider, @unchecked Sendable {
    private enum OperationReservation {
        case reserved
        case restorationInProgress
        case busy
    }

    private let mode: ConnectionMode
    private let backend: ConnectionBackend
    private let lifecycleQueue: DispatchQueue
    private let stateStore: ConnectionStateStore
    private let operationLock = NSLock()
    private var operationInProgress = false
    private var restoringPreviousState = false

    init(mode: ConnectionMode, backend: ConnectionBackend) {
        self.mode = mode
        self.backend = backend
        lifecycleQueue = DispatchQueue(label: "dev.x.teleport.connection-provider.\(mode.rawValue)", qos: .userInitiated)

        if backend.hasActiveRuntimeSession() {
            stateStore = ConnectionStateStore(
                initialState: .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
            )
        } else if backend.hasRestorableState() {
            stateStore = ConnectionStateStore(initialState: .preparing)
            operationInProgress = true
            restoringPreviousState = true
            lifecycleQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.backend.restorePreviousState()
                    self.stateStore.update(.idle)
                } catch {
                    self.stateStore.update(.failed(ConnectionFailure(error: error)))
                }
                self.releaseOperation(completedRestoration: true)
            }
        } else {
            stateStore = ConnectionStateStore(initialState: .idle)
        }
    }

    func currentState() async -> ConnectionState {
        stateStore.current()
    }

    func stateUpdates() -> AsyncStream<ConnectionState> {
        stateStore.stream()
    }

    func connect(_ request: ConnectionRequest) async throws {
        guard case .reserved = reserveOperation() else {
            throw ConnectionProviderError.operationInProgress
        }

        let previousState = stateStore.current()
        stateStore.update(.preparing)
        stateStore.update(.connecting)

        do {
            try await performOnLifecycleQueue {
                switch previousState {
                case .connected:
                    try self.backend.reconnect(
                        configuration: request.configuration,
                        endpoint: request.localProxy,
                        shouldDisableExistingProxy: true,
                        splitTunnelRules: request.splitTunnelPolicy.rules,
                        splitTunnelDefaultAction: request.splitTunnelPolicy.defaultAction
                    )
                default:
                    try self.backend.start(
                        configuration: request.configuration,
                        endpoint: request.localProxy,
                        splitTunnelRules: request.splitTunnelPolicy.rules,
                        splitTunnelDefaultAction: request.splitTunnelPolicy.defaultAction
                    )
                }
            }
            stateStore.update(
                .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
            )
            releaseOperation()
        } catch {
            stateStore.update(.failed(ConnectionFailure(error: error)))
            releaseOperation()
            throw error
        }
    }

    func disconnect() async throws {
        switch reserveOperation() {
        case .reserved:
            break
        case .restorationInProgress:
            try await performOnLifecycleQueue {}
            return try await disconnect()
        case .busy:
            throw ConnectionProviderError.operationInProgress
        }

        if case .idle = stateStore.current() {
            releaseOperation()
            return
        }

        stateStore.update(.disconnecting)
        do {
            try await performOnLifecycleQueue {
                try self.backend.stop(shouldDisableProxy: true)
            }
            stateStore.update(.idle)
            releaseOperation()
        } catch {
            stateStore.update(.failed(ConnectionFailure(error: error)))
            releaseOperation()
            throw error
        }
    }

    private func reserveOperation() -> OperationReservation {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !operationInProgress else {
            return restoringPreviousState ? .restorationInProgress : .busy
        }
        operationInProgress = true
        return .reserved
    }

    private func releaseOperation(completedRestoration: Bool = false) {
        operationLock.lock()
        operationInProgress = false
        if completedRestoration {
            restoringPreviousState = false
        }
        operationLock.unlock()
    }

    private func performOnLifecycleQueue(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ConnectionProviderError: LocalizedError, Equatable {
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another connection operation is already in progress."
        }
    }
}
