import Foundation

@main
struct VerifyConnectionProvider {
    static func main() async throws {
        testConnectionPresentationMapping()
        await testConnectionStateStorePublishesInitialAndUpdatedStates()
        try await testProviderConnectReconnectAndDisconnect()
        try await testProviderPublishesStartAndStopFailures()
        try await testProviderRejectsConcurrentOperation()
        try await testProviderRejectsDisconnectDuringConnect()
        try await testDisconnectWaitsForStartupRestoration()
        testFactorySelectsProviderByMode()
        print("verify_connection_provider: all checks passed")
    }

    private static func testFactorySelectsProviderByMode() {
        let systemProxyProvider = SystemProxyConnectionProvider(
            coordinator: BackendConnectionProvider(mode: .systemProxy, backend: RecordingConnectionBackend())
        )
        let vpnProvider = RootXrayConnectionProvider(
            coordinator: BackendConnectionProvider(mode: .vpn, backend: RecordingConnectionBackend())
        )
        let factory = ConnectionProviderFactory(
            systemProxyProvider: { systemProxyProvider },
            vpnProvider: { vpnProvider }
        )

        precondition(factory.makeProvider(for: .systemProxy) is SystemProxyConnectionProvider)
        precondition(factory.makeProvider(for: .vpn) is RootXrayConnectionProvider)
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
        let provider = BackendConnectionProvider(mode: .vpn, backend: backend)
        let request = try makeRequest()

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

    private static func testProviderPublishesStartAndStopFailures() async throws {
        let startBackend = RecordingConnectionBackend()
        startBackend.startError = TestError.startFailed
        let startProvider = BackendConnectionProvider(mode: .systemProxy, backend: startBackend)
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
        let stopProvider = BackendConnectionProvider(mode: .vpn, backend: stopBackend)
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

    private static func testProviderRejectsConcurrentOperation() async throws {
        let backend = RecordingConnectionBackend()
        backend.blockStart = true
        let provider = BackendConnectionProvider(mode: .vpn, backend: backend)
        let request = try makeRequest()
        let firstConnect = Task { try await provider.connect(request) }

        precondition(backend.startEntered.wait(timeout: .now() + 2) == .success, "first connect did not enter backend")
        do {
            try await provider.connect(request)
            preconditionFailure("expected concurrent connect rejection")
        } catch ConnectionProviderError.operationInProgress {
            // Expected.
        }

        backend.allowStart.signal()
        try await firstConnect.value
        precondition(backend.recordedCalls() == ["start"])
    }

    private static func testProviderRejectsDisconnectDuringConnect() async throws {
        let backend = RecordingConnectionBackend()
        backend.blockStart = true
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        let connectTask = Task { try await provider.connect(try makeRequest()) }

        precondition(backend.startEntered.wait(timeout: .now() + 2) == .success, "connect did not enter backend")
        do {
            try await provider.disconnect()
            preconditionFailure("expected disconnect rejection while connect is active")
        } catch ConnectionProviderError.operationInProgress {
            // Expected.
        }

        backend.allowStart.signal()
        try await connectTask.value
    }

    private static func testDisconnectWaitsForStartupRestoration() async throws {
        let backend = RecordingConnectionBackend()
        backend.hasRestorableStateValue = true
        backend.blockRestore = true
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        precondition(backend.restoreEntered.wait(timeout: .now() + 2) == .success, "startup restoration did not begin")

        let disconnectCompleted = DispatchSemaphore(value: 0)
        let disconnectTask = Task {
            defer { disconnectCompleted.signal() }
            try await provider.disconnect()
        }
        precondition(
            disconnectCompleted.wait(timeout: .now() + 0.1) == .timedOut,
            "disconnect returned before startup restoration completed"
        )

        backend.allowRestore.signal()
        try await disconnectTask.value
        precondition(backend.recordedCalls() == ["restore"], "unexpected restoration cleanup calls: \(backend.recordedCalls())")
    }

    private static func makeRequest() throws -> ConnectionRequest {
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Provider"
        )
        return ConnectionRequest(
            configuration: configuration,
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
                state: .connected(.init(id: UUID(), mode: .vpn, connectedAt: Date())),
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

    private final class RecordingConnectionBackend: ConnectionBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var startError: Error?
        var stopError: Error?
        var hasRestorableStateValue = false
        var blockStart = false
        var blockRestore = false
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let restoreEntered = DispatchSemaphore(value: 0)
        let allowRestore = DispatchSemaphore(value: 0)

        func hasRestorableState() -> Bool { hasRestorableStateValue }
        func hasActiveRuntimeSession() -> Bool { false }

        func restorePreviousState() throws {
            record("restore")
            if blockRestore {
                restoreEntered.signal()
                allowRestore.wait()
            }
        }

        func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
            record("start")
            if blockStart {
                startEntered.signal()
                allowStart.wait()
            }
            if let startError { throw startError }
        }

        func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
            record("reconnect")
            if let startError { throw startError }
        }

        func stop(shouldDisableProxy: Bool) throws {
            record("stop")
            if let stopError { throw stopError }
        }

        func teardown() {
            record("teardown")
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
