import Foundation

struct TestConnectionProvider {
    static func main() async throws {
        testConnectionPresentationMapping()
        await testConnectionStateStorePublishesInitialAndUpdatedStates()
        try await testProviderConnectReconnectAndDisconnect()
        try await testProviderPublishesStartAndStopFailures()
        try await testProviderSerializesConcurrentConnects()
        try await testDisconnectRunsAfterActiveConnect()
        try await testDisconnectCancelsUncommittedConnect()
        try await testDisconnectWaitsForStartupRestoration()
        try await testTerminationCompletesOnlyAfterProviderDisconnect()
        try await testTerminationGivesUpOnAStuckTeardown()
        try await testLostRuntimeFailsTheSessionAndRestoresSettings()
        testFactorySelectsProviderByMode()
        try await testStoredNameSurvivesLoading()
        print("test_connection_provider: all checks passed")
    }

    /// Loading re-parses each stored link to pick up parser fixes, but everything
    /// else the connection carries belongs to the stored connection. A rebuild that
    /// forgets a field drops it on every launch — which is what happened to names.
    /// Redirects Application Support to a throwaway root, so a test run neither
    /// reads nor prunes the retained snapshots of the real installation.
    private final class TempFileManager: FileManager {
        let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }

        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            if directory == .applicationSupportDirectory {
                return [root]
            }
            return super.urls(for: directory, in: domainMask)
        }
    }

    private static func makeIsolatedRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-connection-provider-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func testStoredNameSurvivesLoading() async throws {
        let root = try makeIsolatedRoot("name")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: "dev.x.teleport.verify-connection-provider",
            keychainAccount: "app-snapshot-name",
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        defer { store.deleteKeychainItemForTesting() }

        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Imported"
        )
        let connectionID = UUID()
        try store.save(
            AppSnapshot(
                savedConnections: [
                    SavedConnection(
                        id: connectionID,
                        configuration: configuration,
                        savedAt: Date(timeIntervalSince1970: 100),
                        source: ConnectionSourceMetadata(subscriptionSourceID: UUID(), subscriptionEntryID: "entry"),
                        customName: "Work"
                    )
                ],
                subscriptionSources: [],
                selectedConnectionID: connectionID,
                proxyEndpoint: .default
            )
        )

        let provider = SystemProxyConnectionProvider(
            coordinator: BackendConnectionProvider(mode: .systemProxy, backend: RecordingConnectionBackend())
        )
        let viewModel = AppViewModel(
            parser: ConnectionLinkParser(),
            store: store,
            connectionProviderFactory: ConnectionProviderFactory(
                systemProxyProvider: { provider },
                tunProvider: { provider }
            ),
            subscriptionClient: SubscriptionClient(),
            healthProbeService: ConnectionHealthProbeService(),
            // Isolated, like the store: a check must not read or write the real
            // proxy snapshot, nor leave a launch banner in the real log.
            systemProxyService: SystemProxyService(
                fileManager: TempFileManager(root: root),
                log: TeleportLog(directoryURL: root, fileName: "verify.log")
            ),
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )

        let loaded = viewModel.savedConnections.first { $0.id == connectionID }
        precondition(loaded?.customName == "Work", "expected a stored name to survive loading")
        precondition(loaded?.displayName == "Work")
        // The link itself is still the one that was stored.
        precondition(loaded?.configuration.rawLink == configuration.rawLink)
    }

    private static func testFactorySelectsProviderByMode() {
        let systemProxyProvider = SystemProxyConnectionProvider(
            coordinator: BackendConnectionProvider(mode: .systemProxy, backend: RecordingConnectionBackend())
        )
        let tunProvider = RootXrayConnectionProvider(
            coordinator: BackendConnectionProvider(mode: .tun, backend: RecordingConnectionBackend())
        )
        let factory = ConnectionProviderFactory(
            systemProxyProvider: { systemProxyProvider },
            tunProvider: { tunProvider }
        )

        precondition(factory.makeProvider(for: .systemProxy) is SystemProxyConnectionProvider)
        precondition(factory.makeProvider(for: .tun) is RootXrayConnectionProvider)
    }

    private static func testConnectionStateStorePublishesInitialAndUpdatedStates() async {
        let store = ConnectionStateStore(initialState: .idle)
        let stream = store.stream()
        let reader = collectStates(from: stream, count: 3)

        store.update(.preparing)
        store.update(.connecting)
        let states = await reader.value
        precondition(stateLabels(states) == ["idle", "preparing", "connecting"], "unexpected state stream order: \(states)")
        precondition(store.current() == .connecting)
    }

    private static func testProviderConnectReconnectAndDisconnect() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .tun, backend: backend)
        let request = try makeRequest()
        await awaitInitialState(provider)

        let connectReader = collectStates(from: provider.stateUpdates(), count: 4)
        try await provider.connect(request)
        let connectStates = await connectReader.value
        precondition(stateLabels(connectStates) == ["idle", "preparing", "connecting", "connected"])
        precondition(backend.recordedCalls() == ["start"])

        let reconnectReader = collectStates(from: provider.stateUpdates(), count: 4)
        try await provider.connect(request)
        let reconnectStates = await reconnectReader.value
        precondition(stateLabels(reconnectStates) == ["connected", "preparing", "connecting", "connected"])
        precondition(backend.recordedCalls() == ["start", "reconnect"])

        let disconnectReader = collectStates(from: provider.stateUpdates(), count: 3)
        try await provider.disconnect()
        let disconnectStates = await disconnectReader.value
        precondition(stateLabels(disconnectStates) == ["connected", "disconnecting", "idle"])
        precondition(backend.recordedCalls() == ["start", "reconnect", "stop"])
    }

    /// Xray dying under a connected session used to leave the system pointed at a
    /// dead local port with the app still saying "connected". The provider now
    /// watches the runtime and, when it is gone, fails the session and runs the
    /// backend's teardown so settings are put back.
    private static func testLostRuntimeFailsTheSessionAndRestoresSettings() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend, supervisionInterval: 0.05)
        await awaitInitialState(provider)

        backend.setRuntimeActive(true)
        try await provider.connect(try makeRequest())
        let connectedState = await provider.currentState()
        precondition(stateLabels([connectedState]) == ["connected"])

        // Still alive: the supervisor must not touch a healthy session.
        try await Task.sleep(nanoseconds: 200_000_000)
        let stillConnectedState = await provider.currentState()
        precondition(stateLabels([stillConnectedState]) == ["connected"])
        precondition(backend.recordedCalls() == ["start"])

        // One missed check is not a lost runtime: the check runs over XPC and the
        // first one after a wake can miss its deadline with Xray alive.
        backend.setRuntimeActive(false)
        await waitUntil("the supervisor checks the runtime") { backend.inactiveRuntimeChecks() >= 1 }
        backend.setRuntimeActive(true)
        precondition(backend.inactiveRuntimeChecks() == 1, "the runtime was checked \(backend.inactiveRuntimeChecks()) times while inactive")
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterOneMissState = await provider.currentState()
        precondition(stateLabels([afterOneMissState]) == ["connected"], "one missed check failed the session")
        precondition(backend.recordedCalls() == ["start"])

        let failureReader = collectStates(from: provider.stateUpdates(), count: 2)
        backend.setRuntimeActive(false)
        let states = await failureReader.value
        precondition(stateLabels(states) == ["connected", "failed"], "expected a lost runtime to fail the session, got \(stateLabels(states))")

        // The teardown that restores proxy settings or routes follows the failure.
        await waitUntil("the backend teardown runs after a lost runtime") { backend.recordedCalls() == ["start", "stop"] }

        // Only once: the supervisor stops with the session it was watching.
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(backend.recordedCalls() == ["start", "stop"])
    }

    private static func testProviderPublishesStartAndStopFailures() async throws {
        let startBackend = RecordingConnectionBackend()
        startBackend.startError = TestError.startFailed
        let startProvider = BackendConnectionProvider(mode: .systemProxy, backend: startBackend)
        await awaitInitialState(startProvider)
        let startReader = collectStates(from: startProvider.stateUpdates(), count: 4)

        do {
            try await startProvider.connect(try makeRequest())
            preconditionFailure("expected injected start failure")
        } catch TestError.startFailed {
            // Expected.
        }

        let startStates = await startReader.value
        precondition(stateLabels(startStates) == ["idle", "preparing", "connecting", "failed"])
        guard case let .failed(failure) = startStates.last else {
            preconditionFailure("expected failed terminal state")
        }
        precondition(failure.summary == TestError.startFailed.localizedDescription)

        let stopBackend = RecordingConnectionBackend()
        let stopProvider = BackendConnectionProvider(mode: .tun, backend: stopBackend)
        await awaitInitialState(stopProvider)
        try await stopProvider.connect(try makeRequest())
        stopBackend.stopError = TestError.stopFailed
        let stopReader = collectStates(from: stopProvider.stateUpdates(), count: 3)

        do {
            try await stopProvider.disconnect()
            preconditionFailure("expected injected stop failure")
        } catch TestError.stopFailed {
            // Expected.
        }

        let stopStates = await stopReader.value
        precondition(stateLabels(stopStates) == ["connected", "disconnecting", "failed"])
        guard case let .failed(failure) = stopStates.last else {
            preconditionFailure("expected failed terminal state")
        }
        precondition(failure.summary == TestError.stopFailed.localizedDescription)
    }

    private static func testProviderSerializesConcurrentConnects() async throws {
        let backend = RecordingConnectionBackend()
        await backend.startGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .tun, backend: backend)
        let request = try makeRequest()

        let first = Task { try await provider.connect(request) }
        await backend.startGate.waitUntilEntered()

        let second = Task { try await provider.connect(request) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(
            backend.recordedCalls() == ["start"],
            "second connect reached the backend before the first finished: \(backend.recordedCalls())"
        )

        await backend.startGate.open()
        try await first.value
        try await second.value
        // The first connect left the provider connected, so the queued second one
        // takes the reconnect branch — proving it observed the finished first op.
        precondition(
            backend.recordedCalls() == ["start", "reconnect"],
            "unexpected call order: \(backend.recordedCalls())"
        )
    }

    private static func testDisconnectRunsAfterActiveConnect() async throws {
        let backend = RecordingConnectionBackend()
        await backend.startGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)

        let connectTask = Task { try await provider.connect(try makeRequest()) }
        await backend.startGate.waitUntilEntered()

        let disconnectTask = Task { try await provider.disconnect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(
            backend.recordedCalls() == ["start"],
            "disconnect ran before the active connect finished: \(backend.recordedCalls())"
        )

        await backend.startGate.open()
        try await connectTask.value
        try await disconnectTask.value
        precondition(
            backend.recordedCalls() == ["start", "stop"],
            "unexpected call order: \(backend.recordedCalls())"
        )
    }

    /// A connect still in its pre-flight has changed nothing, so a disconnect
    /// cancels it instead of waiting behind it; the connect ends idle, not failed,
    /// and the queued disconnect finds nothing to stop.
    private static func testDisconnectCancelsUncommittedConnect() async throws {
        let backend = RecordingConnectionBackend()
        backend.startObservesCancellation = true
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        await awaitInitialState(provider)

        let connectTask = Task { try await provider.connect(try makeRequest()) }
        await waitUntil("the connect reaches the backend") { !backend.recordedCalls().isEmpty }
        precondition(backend.recordedCalls() == ["start"], "connect did not start")

        try await provider.disconnect()
        do {
            try await connectTask.value
            preconditionFailure("cancelled connect returned without an error")
        } catch is CancellationError {
        } catch {
            preconditionFailure("cancelled connect threw \(error) instead of CancellationError")
        }
        let finalState = await provider.currentState()
        precondition(finalState == .idle, "cancelled connect did not end idle: \(finalState)")
        precondition(
            backend.recordedCalls() == ["start"],
            "disconnect stopped a backend that never started: \(backend.recordedCalls())"
        )
    }

    private static func testDisconnectWaitsForStartupRestoration() async throws {
        let backend = RecordingConnectionBackend()
        backend.hasRestorableStateValue = true
        await backend.restoreGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        await backend.restoreGate.waitUntilEntered()

        let disconnectTask = Task { try await provider.disconnect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(
            backend.recordedCalls() == ["restore"],
            "disconnect ran before startup restoration completed: \(backend.recordedCalls())"
        )

        await backend.restoreGate.open()
        try await disconnectTask.value
        // Restoration ends in .idle, so the queued disconnect is a no-op.
        precondition(
            backend.recordedCalls() == ["restore"],
            "unexpected restoration cleanup calls: \(backend.recordedCalls())"
        )
    }

    private static func testTerminationCompletesOnlyAfterProviderDisconnect() async throws {
        let root = try makeIsolatedRoot("termination")
        defer { try? FileManager.default.removeItem(at: root) }
        let (viewModel, backend, store) = try await makeTerminationFixture(root: root)
        defer { store.deleteKeychainItemForTesting() }

        await backend.stopGate.enableBlocking()
        let completed = Flag()
        viewModel.handleAppTermination { completed.set() }
        await backend.stopGate.waitUntilEntered()
        precondition(!completed.isSet, "termination completed before the provider disconnected")

        await backend.stopGate.open()
        await waitUntil("termination completes after disconnect") { completed.isSet }
        precondition(
            backend.recordedCalls() == ["start", "stop"],
            "unexpected termination calls: \(backend.recordedCalls())"
        )
    }

    /// A connected view model over an isolated store, for the termination checks.
    private static func makeTerminationFixture(
        root: URL
    ) async throws -> (AppViewModel, RecordingConnectionBackend, ConfigurationStore) {
        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: "dev.x.teleport.verify-connection-provider",
            keychainAccount: "app-snapshot",
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        // Pre-seeding the isolated item stops AppViewModel's init from seeding the
        // bundled subscriptions and immediately fetching them over the network.
        try store.save(
            AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default
            )
        )

        let backend = RecordingConnectionBackend()
        let coordinator = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        let provider = SystemProxyConnectionProvider(coordinator: coordinator)
        let viewModel = AppViewModel(
            parser: ConnectionLinkParser(),
            store: store,
            connectionProviderFactory: ConnectionProviderFactory(
                systemProxyProvider: { provider },
                tunProvider: { provider }
            ),
            subscriptionClient: SubscriptionClient(),
            healthProbeService: ConnectionHealthProbeService(),
            // Isolated, like the store: a check must not read or write the real
            // proxy snapshot, nor leave a launch banner in the real log.
            systemProxyService: SystemProxyService(
                fileManager: TempFileManager(root: root),
                log: TeleportLog(directoryURL: root, fileName: "verify.log")
            ),
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        await awaitInitialState(coordinator)
        try await coordinator.connect(try makeRequest())
        return (viewModel, backend, store)
    }

    /// A teardown that never returns must not keep the app from quitting: the
    /// helper's lease and the next launch finish the cleanup.
    private static func testTerminationGivesUpOnAStuckTeardown() async throws {
        let root = try makeIsolatedRoot("termination-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let (viewModel, backend, store) = try await makeTerminationFixture(root: root)
        defer { store.deleteKeychainItemForTesting() }
        await backend.stopGate.enableBlocking()
        let completed = Flag()
        viewModel.handleAppTermination(teardownLimit: .milliseconds(200)) { completed.set() }
        await backend.stopGate.waitUntilEntered()
        await waitUntil("termination gives up on the stuck teardown") { completed.isSet }
        await backend.stopGate.open()
    }

    /// Polls `condition` until it holds, and fails the run if it does not within
    /// `timeout`. The code under test signals nothing a check could await, so the
    /// checks poll; this keeps the polling and its limit in one place.
    private static func waitUntil(
        _ expectation: String,
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("timed out waiting until \(expectation)")
    }

    /// The provider resolves its starting state as the first queued operation, so a
    /// test that subscribes to the stream must let that finish before asserting.
    private static func awaitInitialState(_ provider: BackendConnectionProvider) async {
        await waitUntil("the provider resolves its initial state") {
            await provider.currentState() != .preparing
        }
    }

    private static func makeRequest() throws -> ConnectionRequest {
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Provider"
        )
        return ConnectionRequest(
            defaultConnection: RoutedConnection(id: UUID(), configuration: configuration),
            localProxy: .default,
            splitTunnelPolicy: SplitTunnelPolicy(rules: [], defaultAction: .proxy)
        )
    }

    private static func collectStates(from stream: AsyncStream<ConnectionState>, count: Int) -> Task<[ConnectionState], Never> {
        Task {
            var states: [ConnectionState] = []
            for await state in stream {
                states.append(state)
                if states.count == count { break }
            }
            return states
        }
    }

    private static func stateLabels(_ states: [ConnectionState]) -> [String] {
        states.map { state in
            switch state {
            case .idle: return "idle"
            case .preparing: return "preparing"
            case .awaitingUserApproval: return "awaitingUserApproval"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .disconnecting: return "disconnecting"
            case .failed: return "failed"
            }
        }
    }

    private static func testConnectionPresentationMapping() {
        precondition(
            ConnectionPresentation(state: .idle, hasConfiguration: false)
                == ConnectionPresentation(connectionPhase: .unconfigured, proxyPhase: .disabled)
        )
        precondition(
            ConnectionPresentation(state: .idle, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopped, proxyPhase: .disabled)
        )
        precondition(
            ConnectionPresentation(state: .preparing, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(state: .awaitingUserApproval, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(state: .connecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        precondition(
            ConnectionPresentation(
                state: .connected(.init(id: UUID(), mode: .tun, connectedAt: Date())),
                hasConfiguration: true
            ) == ConnectionPresentation(connectionPhase: .running, proxyPhase: .enabled)
        )
        precondition(
            ConnectionPresentation(state: .disconnecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopping, proxyPhase: .disabling)
        )
        let failedPresentation = ConnectionPresentation(
            state: .failed(.init(summary: "failed", details: nil)),
            hasConfiguration: true
        )
        precondition(failedPresentation == ConnectionPresentation(connectionPhase: .failed, proxyPhase: .failed))
        precondition(failedPresentation.canChangeSelection, "failed state must preserve selection changes")
    }

    private enum TestError: LocalizedError {
        case startFailed
        case stopFailed

        var errorDescription: String? {
            switch self {
            case .startFailed: return "Injected start failure"
            case .stopFailed: return "Injected stop failure"
            }
        }
    }

    /// Async gate used instead of a DispatchSemaphore: blocking a cooperative
    /// thread inside an async backend call would stall the concurrency pool.
    private actor Gate {
        private var entered = false
        private var opened = false
        private var shouldBlock = false

        func enableBlocking() {
            shouldBlock = true
        }

        func enter() async {
            guard shouldBlock else { return }
            entered = true
            while !opened {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        func open() {
            opened = true
        }

        func waitUntilEntered(timeout: TimeInterval = 2) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !entered && Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            precondition(entered, "backend call did not start in time")
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class RecordingConnectionBackend: ConnectionBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var startError: Error?
        var stopError: Error?
        var hasRestorableStateValue = false
        var hasActiveRuntimeSessionValue = false
        private var inactiveChecks = 0
        /// Stands in for a pre-flight that polls for cancellation.
        var startObservesCancellation = false
        let startGate = Gate()
        let restoreGate = Gate()
        let stopGate = Gate()

        func hasRestorableState() -> Bool { hasRestorableStateValue }
        func hasActiveRuntimeSession() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if !hasActiveRuntimeSessionValue { inactiveChecks += 1 }
            return hasActiveRuntimeSessionValue
        }

        /// How many checks have found the runtime inactive.
        func inactiveRuntimeChecks() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return inactiveChecks
        }

        func setRuntimeActive(_ active: Bool) {
            lock.lock()
            hasActiveRuntimeSessionValue = active
            lock.unlock()
        }

        func restorePreviousState() async throws {
            record("restore")
            await restoreGate.enter()
        }

        func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
            record("start")
            if startObservesCancellation {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                throw CancellationError()
            }
            await startGate.enter()
            if let startError { throw startError }
        }

        func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
            record("reconnect")
            if let startError { throw startError }
        }

        func stop() async throws {
            record("stop")
            await stopGate.enter()
            if let stopError { throw stopError }
        }

        func recordedCalls() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        private func record(_ call: String) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }
    }
}
