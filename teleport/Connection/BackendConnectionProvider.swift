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
    private let operationQueue: ConnectionOperationQueue
    private let supervisionInterval: TimeInterval
    private let supervisionLock = NSLock()
    private var supervisionTask: Task<Void, Never>?
    /// The connect currently queued or running, so a disconnect can cancel it.
    /// Cancellation only reaches the backend's pre-flight; once a connect has
    /// started changing the machine it ignores the cancellation and finishes.
    private let connectLock = NSLock()
    private var connectTask: Task<Void, Error>?

    /// `supervisionInterval` is how often a connected session is checked against
    /// the backend's runtime. Overridable so a check can drive it quickly.
    init(mode: ConnectionMode, backend: ConnectionBackend, supervisionInterval: TimeInterval = 2) {
        self.mode = mode
        self.backend = backend
        self.supervisionInterval = supervisionInterval
        // Where the backend stands can only be answered asynchronously (TUN mode
        // asks the privileged helper over XPC), so the provider starts out
        // resolving and publishes the answer as the first queued operation.
        let stateStore = ConnectionStateStore(initialState: .preparing)
        self.stateStore = stateStore
        // `self` is not yet available to the closure, so a session found already
        // running is supervised once the queue reaches it, via the box below.
        let selfBox = WeakProviderBox()
        operationQueue = ConnectionOperationQueue { [backend, stateStore, mode] in
            if await backend.hasActiveRuntimeSession() {
                stateStore.update(
                    .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
                )
                selfBox.value?.superviseRuntime()
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
        selfBox.value = self
    }

    deinit {
        stopSupervising()
    }

    func currentState() async -> ConnectionState {
        stateStore.current()
    }

    private func setConnectTask(_ task: Task<Void, Error>) {
        connectLock.lock()
        connectTask = task
        connectLock.unlock()
    }

    private func clearConnectTask(_ task: Task<Void, Error>) {
        connectLock.lock()
        if connectTask == task { connectTask = nil }
        connectLock.unlock()
    }

    private func cancelConnectTask() {
        connectLock.lock()
        connectTask?.cancel()
        connectLock.unlock()
    }

    // MARK: - Supervision

    /// Nothing told the provider when its runtime died. Xray exiting under System
    /// Proxy mode left the system pointed at dead local ports; the helper tearing
    /// a tunnel down on its own left the app saying "connected". While a session
    /// is connected the backend's runtime is checked on an interval, and a
    /// runtime that is gone becomes a failure with the backend's teardown run so
    /// proxy settings and routes are put back.
    private func superviseRuntime() {
        stopSupervising()
        let task = Task { [weak self, backend, supervisionInterval] in
            // One negative answer is not a lost runtime: the check runs over XPC
            // with a short deadline and the first one after a wake can miss it.
            // Two in a row, an interval apart, are.
            var missedChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(supervisionInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if await backend.hasActiveRuntimeSession() {
                    missedChecks = 0
                    continue
                }
                missedChecks += 1
                TeleportLog.shared.warn("app", "runtime check \(missedChecks) of 2 found no running session")
                guard missedChecks >= 2 else { continue }
                self?.handleRuntimeLoss()
                return
            }
        }
        supervisionLock.lock()
        supervisionTask = task
        supervisionLock.unlock()
    }

    private func stopSupervising() {
        supervisionLock.lock()
        supervisionTask?.cancel()
        supervisionTask = nil
        supervisionLock.unlock()
    }

    private func handleRuntimeLoss() {
        Task { [operationQueue, backend, stateStore, mode] in
            try? await operationQueue.enqueue {
                // A disconnect that was already queued behind the check wins.
                guard case .connected = stateStore.current() else { return }
                stateStore.update(.failed(ConnectionFailure(
                    summary: "Xray stopped unexpectedly",
                    details: mode == .tun
                        ? "The tunnel's routes were removed so the machine routes directly. Reconnect to start it again."
                        : "System proxy settings were restored so the machine routes directly. Reconnect to start it again."
                )))
                try? await backend.stop()
            }
        }
    }

    func stateUpdates() -> AsyncStream<ConnectionState> {
        stateStore.stream()
    }

    func connect(_ request: ConnectionRequest) async throws {
        stopSupervising()
        let task = await operationQueue.register { [weak self, backend, stateStore, mode] in
            let previousState = stateStore.current()
            stateStore.update(.preparing)
            stateStore.update(.connecting)

            // A backend may say it is waiting on the user, and that it is back to
            // connecting; it may not declare the session connected or failed, which
            // only this operation does below.
            let reportPhase: @Sendable (ConnectionState) -> Void = { phase in
                guard phase == .awaitingUserApproval || phase == .connecting else { return }
                stateStore.update(phase)
            }
            do {
                if case .connected = previousState {
                    try await backend.reconnect(request, reportPhase: reportPhase)
                } else {
                    try await backend.start(request, reportPhase: reportPhase)
                }
                stateStore.update(
                    .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
                )
                self?.superviseRuntime()
            } catch is CancellationError {
                // The backend put back whatever it had touched, so there is nothing
                // to report as failed; the disconnect queued behind this sees idle
                // and returns.
                stateStore.update(.idle)
                throw CancellationError()
            } catch {
                stateStore.update(.failed(ConnectionFailure(error: error)))
                throw error
            }
        }
        setConnectTask(task)
        defer { clearConnectTask(task) }
        try await task.value
    }

    func disconnect() async throws {
        stopSupervising()
        cancelConnectTask()
        try await operationQueue.enqueue { [backend, stateStore] in
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

}

/// Not generic: Swift 6.3.3 (Xcode 26.6) crashes in EarlyPerfInliner on the
/// deinit of a generic version of this class in Release builds.
private final class WeakProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: BackendConnectionProvider?
    var value: BackendConnectionProvider? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Actor-backed serial chain. Registering each operation and advancing `tail`
/// happens atomically in actor isolation before this method suspends. The work is
/// intentionally unstructured so caller cancellation cannot abandon half-applied
/// proxy or tunnel state.
private actor ConnectionOperationQueue {
    private var tail: Task<Void, Never>

    init(initialOperation: @escaping @Sendable () async -> Void) {
        tail = Task { await initialOperation() }
    }

    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await register(operation).value
    }

    /// The registered task itself, for a caller that needs to cancel it later.
    func register<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Task<T, Error> {
        let previous = tail
        let work = Task<T, Error> {
            await previous.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return work
    }
}
