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
    private let verifyConnection: (@Sendable (ConnectionRequest) async throws -> Void)?
    private let supervisionLock = NSLock()
    private var supervisionTask: Task<Void, Never>?
    /// The connect currently queued or running, so a disconnect can cancel it.
    /// Cancellation only reaches the backend's pre-flight; once a connect has
    /// started changing the machine it ignores the cancellation and finishes.
    private let connectLock = NSLock()
    private var connectAttempts: [UUID: ConnectionAttempt] = [:]

    /// `supervisionInterval` is how often a connected session is checked against
    /// the backend's runtime. Overridable so a check can drive it quickly.
    init(mode: ConnectionMode, backend: ConnectionBackend, supervisionInterval: TimeInterval = 2,
         verifyConnection: (@Sendable (ConnectionRequest) async throws -> Void)? = nil) {
        self.mode = mode
        self.backend = backend
        self.supervisionInterval = supervisionInterval
        self.verifyConnection = verifyConnection
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

    private func cancelConnectAttempts() {
        let attempts = connectLock.withLock { Array(connectAttempts.values) }
        attempts.forEach { $0.cancel() }
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
                let failure = ConnectionFailure(
                    summary: "Xray stopped unexpectedly",
                    details: mode == .tun
                        ? "The tunnel's routes were removed so the machine routes directly. Reconnect to start it again."
                        : "System proxy settings were restored so the machine routes directly. Reconnect to start it again."
                )
                do {
                    try await backend.stop()
                    stateStore.update(.failed(failure))
                    stateStore.update(.idle)
                } catch {
                    stateStore.update(.failed(ConnectionFailure(
                        summary: failure.summary,
                        details: "Teleport could not finish disconnecting: \(error.localizedDescription)"
                    )))
                }
            }
        }
    }

    func stateUpdates() -> AsyncStream<ConnectionState> {
        stateStore.stream()
    }

    func connect(_ request: ConnectionRequest) async throws {
        stopSupervising()
        // Register cancellation ownership before the queue's first suspension.
        let id = UUID()
        let attempt = ConnectionAttempt()
        connectLock.withLock { connectAttempts[id] = attempt }
        defer { _ = connectLock.withLock { connectAttempts.removeValue(forKey: id) } }
        try await withTaskCancellationHandler {
            let task = await operationQueue.register { [weak self, backend, stateStore, mode, verifyConnection] in
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
                var startedSession = false
                do {
                    // Even an already-cancelled attempt must reconcile an owned
                    // recovery snapshot through the failure cleanup below.
                    try attempt.checkCancellation()
                    if case .connected = previousState {
                        try await backend.reconnect(request, reportPhase: reportPhase)
                    } else {
                        try await backend.start(request, reportPhase: reportPhase)
                    }
                    startedSession = true
                    try await verifyConnection?(request)
                    stateStore.update(
                        .connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
                    )
                    self?.superviseRuntime()
                } catch {
                    // Start/reconnect own rollback. A completed rollback is a
                    // disconnected session with an error to display, not a session
                    // requiring an extra Disconnect click before another attempt.
                    // Do not stop blindly here: a preflight may have rejected another
                    // VPN before this attempt changed anything on the machine.
                    var failure = ConnectionFailure(error: error)
                    var cleanupError: Error?
                    if startedSession {
                        // This attempt owns a started session. A failed or cancelled
                        // traffic check must tear it down before allowing a retry.
                        do { try await backend.stop() }
                        catch { cleanupError = error }
                    }
                    var disconnected = !(await backend.hasActiveRuntimeSession()) && cleanupError == nil
                    if disconnected, await backend.hasRestorableState() {
                        do {
                            try await backend.restorePreviousState()
                        } catch {
                            disconnected = false
                            cleanupError = error
                        }
                    }
                    if let cleanupError {
                        failure = ConnectionFailure(summary: failure.summary, details: [
                            failure.details,
                            "Teleport could not finish disconnecting: \(cleanupError.localizedDescription)"
                        ].compactMap { $0 }.joined(separator: "\n"))
                    }
                    // Subscribers retain the diagnostic when idle clears the session.
                    if !(error is CancellationError) || !disconnected {
                        stateStore.update(.failed(failure))
                    }
                    if disconnected { stateStore.update(.idle) }
                    throw error
                }
            }
            attempt.setTask(task)
            try await task.value
        } onCancel: {
            attempt.cancel()
        }
    }

    func disconnect() async throws {
        stopSupervising()
        cancelConnectAttempts()
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

/// Cancellation can precede the queue returning its registered task handle.
nonisolated private final class ConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<Void, Error>?

    func setTask(_ task: Task<Void, Error>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            return task
        }
        pending?.cancel()
    }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        try Task.checkCancellation()
    }
}

/// Not generic: Swift 6.3.3 (Xcode 26.6) crashes in EarlyPerfInliner on the
/// deinit of a generic version of this class in Release builds.
nonisolated private final class WeakProviderBox: @unchecked Sendable {
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
