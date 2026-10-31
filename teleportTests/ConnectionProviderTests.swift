import Combine
import Foundation
import XCTest

final class ConnectionProviderTests: XCTestCase {
    @MainActor
    func testSettingsStatusRefreshDoesNotPublishUnchangedValues() throws {
        let root = try makeIsolatedRoot("settings-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, store) = try makeLaunchFixture(
            root: root, mode: .systemProxy, enabled: false,
            backend: RecordingConnectionBackend(), hasConnections: false
        )
        defer { store.deleteStoredDataForTesting() }
        model.refreshStartsAtLoginStatus()
        model.refreshHelperInstallationStatus()

        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        // General and Advanced refresh these on every appearance. Reopening
        // either page must not invalidate every observer of the app model.
        model.refreshStartsAtLoginStatus()
        model.refreshHelperInstallationStatus()
        XCTAssertEqual(updates, 0)
    }

    @MainActor
    func testConnectionPopoverShowsStartupAndApprovalFailuresWithDetails() async throws {
        let errors: [Error] = [
            PrivilegedHelperInstallerError.helperDidNotStart("Xray exited with status 1"),
            PrivilegedShellError.commandFailed("User canceled."),
        ]
        for error in errors {
            let root = try makeIsolatedRoot("connection-popover")
            defer { try? FileManager.default.removeItem(at: root) }
            let backend = RecordingConnectionBackend()
            backend.startError = error
            let (model, store) = try makeLaunchFixture(root: root, mode: .tun, enabled: false, backend: backend)
            defer { store.deleteStoredDataForTesting() }
            await waitUntil("ready") { await MainActor.run { model.canConnect } }
            model.connect()
            await waitUntil("failure displayed") {
                await MainActor.run { model.connectionError != nil && !model.isOperationPending }
            }
            XCTAssertEqual(model.connectionError, ConnectionFailure(error: error))
            XCTAssertEqual(model.lastError, model.connectionError?.summary)
            XCTAssertEqual(model.lastErrorDetails, model.connectionError?.details)

            // Importing and dismissing an unrelated error must not hide the failure.
            model.reportImportFailure("Invalid portal URL")
            model.clearError()
            XCTAssertEqual(model.connectionError, ConnectionFailure(error: error))
            let failedState = model.connectionState
            model.dismissConnectionError()
            XCTAssertNil(model.connectionError)
            XCTAssertEqual(model.connectionState, failedState)
            XCTAssertTrue(model.canConnect)

            // The same failure on a later attempt must be visible again.
            model.connect()
            await waitUntil("repeated failure displayed") {
                await MainActor.run { model.connectionError != nil && !model.isOperationPending }
            }
            backend.startError = nil
            model.connect()
            XCTAssertNil(model.connectionError, "Starting a retry clears the previous popover immediately")
            await waitUntil("retry connects") { await MainActor.run { model.isConnected && !model.isOperationPending } }
            XCTAssertNil(model.connectionError)
            model.disconnect()
            await waitUntil("cleanup") { await MainActor.run { model.connectionState == .idle && !model.isOperationPending } }
        }
    }

    @MainActor
    func testDisconnectFailurePopoverDoesNotDisableDisconnectRetry() async throws {
        let root = try makeIsolatedRoot("disconnect-popover")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        let (model, store) = try makeLaunchFixture(root: root, mode: .tun, enabled: false, backend: backend)
        defer { store.deleteStoredDataForTesting() }
        await waitUntil("ready") { await MainActor.run { model.canConnect } }
        model.connect()
        await waitUntil("connected") { await MainActor.run { model.isConnected && !model.isOperationPending } }
        backend.stopError = TestError.stopFailed
        model.disconnect()
        await waitUntil("disconnect failure displayed") {
            await MainActor.run { model.connectionError != nil && !model.isOperationPending }
        }
        XCTAssertEqual(model.connectionError?.summary, TestError.stopFailed.localizedDescription)
        XCTAssertTrue(model.canDisconnect)
        let failedState = model.connectionState
        model.dismissConnectionError()
        XCTAssertEqual(model.connectionState, failedState)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.canDisconnect)
        backend.stopError = nil
        model.disconnect()
        XCTAssertNil(model.connectionError)
        await waitUntil("disconnect retry finishes") {
            await MainActor.run { model.connectionState == .idle && !model.isOperationPending }
        }
        XCTAssertNil(model.connectionError)
    }

    @MainActor
    func testImportErrorsAndCancelledConnectionsDoNotShowConnectionPopover() async throws {
        let root = try makeIsolatedRoot("cancelled-popover")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        backend.startError = CancellationError()
        let (model, store) = try makeLaunchFixture(root: root, mode: .tun, enabled: false, backend: backend)
        defer { store.deleteStoredDataForTesting() }
        await waitUntil("ready") { await MainActor.run { model.canConnect } }
        model.reportImportFailure("Invalid portal URL")
        XCTAssertNil(model.connectionError)
        XCTAssertNotNil(model.lastError)
        model.connect()
        await waitUntil("cancelled connect finishes") { await MainActor.run { !model.isOperationPending } }
        XCTAssertNil(model.connectionError)
        XCTAssertEqual(model.connectionState, .idle)
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

    private func makeIsolatedRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-connection-provider-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    func testConnectOnLaunchWaitsForRecoveryAndConnectsOnlyOnce() async throws {
        for mode in [ConnectionMode.systemProxy, .tun] {
            let root = try makeIsolatedRoot("auto-connect")
            defer { try? FileManager.default.removeItem(at: root) }
            let backend = RecordingConnectionBackend()
            backend.hasRestorableStateValue = true
            await backend.restoreGate.enableBlocking()
            let (model, store) = try makeLaunchFixture(root: root, mode: mode, enabled: true, backend: backend)
            defer { store.deleteStoredDataForTesting() }

            await backend.restoreGate.waitUntilEntered()
            XCTAssertTrue(backend.requestedConnectionIDs().isEmpty, "Must wait for startup recovery")
            await backend.restoreGate.open()
            await waitUntil("launch connects") {
                await MainActor.run { model.isConnected && !model.isOperationPending }
            }
            XCTAssertEqual(model.connectionMode, mode)
            XCTAssertEqual(backend.requestedConnectionIDs(), [try XCTUnwrap(model.selectedConnectionID)])
            XCTAssertEqual(backend.recordedCalls(), ["restore", "start"])

            model.disconnect()
            await waitUntil("manual disconnect finishes") {
                await MainActor.run { model.connectionState == .idle && !model.isOperationPending }
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(backend.requestedConnectionIDs().count, 1, "Disconnect must not trigger another launch connection")
        }
    }

    @MainActor
    func testEnablingConnectOnLaunchDoesNotConnectImmediately() async throws {
        let root = try makeIsolatedRoot("auto-connect-disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        let (model, store) = try makeLaunchFixture(root: root, mode: .systemProxy, enabled: false, backend: backend)
        defer { store.deleteStoredDataForTesting() }
        await waitUntil("startup is ready") { await MainActor.run { model.canConnect } }
        XCTAssertTrue(backend.requestedConnectionIDs().isEmpty)
        model.setConnectsOnLaunch(true)
        await waitUntil("launch preference is saved") { store.load().connectsOnLaunch }
        XCTAssertTrue(backend.requestedConnectionIDs().isEmpty)
    }

    @MainActor
    func testConnectOnLaunchKeepsExistingSession() async throws {
        let root = try makeIsolatedRoot("auto-connect-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        backend.setRuntimeActive(true)
        let (model, store) = try makeLaunchFixture(root: root, mode: .tun, enabled: true, backend: backend)
        defer { store.deleteStoredDataForTesting() }
        await waitUntil("existing session is recognized") { await MainActor.run { model.isConnected } }
        XCTAssertTrue(backend.requestedConnectionIDs().isEmpty)
        model.disconnect()
        await waitUntil("existing session disconnects") {
            await MainActor.run { model.connectionState == .idle && !model.isOperationPending }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(backend.requestedConnectionIDs().isEmpty)
    }

    @MainActor
    func testConnectOnLaunchWithoutSavedConnectionDoesNothing() async throws {
        let root = try makeIsolatedRoot("auto-connect-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        let (model, store) = try makeLaunchFixture(root: root, mode: .systemProxy, enabled: true, backend: backend, hasConnections: false)
        defer { store.deleteStoredDataForTesting() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.connectionState, .idle)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(backend.requestedConnectionIDs().isEmpty)
    }

    @MainActor
    private func makeLaunchFixture(
        root: URL, mode: ConnectionMode, enabled: Bool,
        backend: RecordingConnectionBackend, hasConnections: Bool = true
    ) throws -> (AppViewModel, ConfigurationStore) {
        let fileManager = TempFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "verify.log")
        let store = ConfigurationStore(
            fileManager: fileManager, keychainService: "dev.x.teleport.verify-launch-\(UUID().uuidString)",
            keychainAccount: "app-snapshot", log: log
        )
        let connections: [SavedConnection] = try (hasConnections ? [9, 10] : []).map { port in
            let configuration = try ConnectionLinkParser().parse(
                "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:\(port)?security=none&type=tcp#Launch"
            )
            return SavedConnection(id: UUID(), configuration: configuration, savedAt: Date())
        }
        try store.save(AppSnapshot(
            savedConnections: connections, selectedConnectionID: connections.last?.id,
            proxyEndpoint: .default, connectionMode: mode, connectsOnLaunch: enabled
        ))
        let provider = BackendConnectionProvider(mode: mode, backend: backend, supervisionInterval: 60)
        let model = AppViewModel(
            parser: ConnectionLinkParser(), store: store,
            connectionProviderFactory: ConnectionProviderFactory(systemProxyProvider: { provider }, tunProvider: { provider }),
            leakGuard: LeakGuardService(isEnabled: false, log: log),
            subscriptionClient: SubscriptionClient(), healthProbeService: ConnectionHealthProbeService(),
            systemProxyService: SystemProxyService(fileManager: fileManager, log: log), log: log
        )
        return (model, store)
    }

    func testStoredNameSurvivesLoading() async throws {
        let root = try makeIsolatedRoot("name")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: "dev.x.teleport.verify-connection-provider",
            keychainAccount: "app-snapshot-name",
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        defer { store.deleteStoredDataForTesting() }

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
            // proxy snapshot, nor leave a launch popover in the real log.
            systemProxyService: SystemProxyService(
                fileManager: TempFileManager(root: root),
                log: TeleportLog(directoryURL: root, fileName: "verify.log")
            ),
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )

        let loaded = viewModel.savedConnections.first { $0.id == connectionID }
        XCTAssert(loaded?.customName == "Work", "expected a stored name to survive loading")
        XCTAssert(loaded?.displayName == "Work")
        // The link itself is still the one that was stored.
        XCTAssert(loaded?.configuration.rawLink == configuration.rawLink)
    }

    @MainActor
    func testSwitchingSelectedServerInSystemProxyMode() async throws {
        try await checkSwitchingSelectedServer(mode: .systemProxy)
    }

    @MainActor
    func testSwitchingSelectedServerInTUNMode() async throws {
        try await checkSwitchingSelectedServer(mode: .tun)
    }

    @MainActor
    private func checkSwitchingSelectedServer(mode: ConnectionMode) async throws {
        let root = try makeIsolatedRoot("switch-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = TeleportLog(directoryURL: root, fileName: "verify.log")
        let fileManager = TempFileManager(root: root)
        let store = ConfigurationStore(
            fileManager: fileManager,
            keychainService: "dev.x.teleport.verify-connection-provider",
            keychainAccount: "app-snapshot-switch-\(mode.rawValue)",
            log: log
        )
        defer { store.deleteStoredDataForTesting() }
        let connections = try (1...3).map { index in
            SavedConnection(
                id: UUID(),
                configuration: try ConnectionLinkParser().parse(
                    "vless://123e4567-e89b-12d3-a456-426614174000@server\(index).example:443?security=tls&type=tcp#Server\(index)"
                ),
                savedAt: Date(),
                healthCheck: ConnectionHealthCheck(
                    state: .reachable, checkedAt: Date(), latencyMilliseconds: 10,
                    latencyKind: .proxyRequest, failureSummary: nil
                )
            )
        }
        try store.save(AppSnapshot(
            savedConnections: connections,
            selectedConnectionID: connections[0].id,
            proxyEndpoint: .default,
            connectionMode: mode,
            isLeakGuardEnabled: false
        ))
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: mode, backend: backend, supervisionInterval: 60)
        let viewModel = AppViewModel(
            parser: ConnectionLinkParser(), store: store,
            connectionProviderFactory: ConnectionProviderFactory(
                systemProxyProvider: { provider }, tunProvider: { provider }
            ),
            leakGuard: LeakGuardService(isEnabled: false, log: log),
            subscriptionClient: SubscriptionClient(),
            healthProbeService: ConnectionHealthProbeService(),
            systemProxyService: SystemProxyService(fileManager: fileManager, log: log),
            log: log
        )
        await waitUntil("selection is ready") { await MainActor.run { viewModel.canConnect } }
        let first = connections[0].id
        let second = connections[1].id
        let third = connections[2].id

        // A superseded pre-flight must finish by cancellation, without ever
        // connecting. The replacement is the latest click, not every click.
        for latest in [third, first] {
            viewModel.selectConnection(id: first)
            backend.cancellableConnectionID = first
            viewModel.connect()
            await waitUntil("the cancellable pre-flight starts") {
                backend.requestedConnectionIDs() == [first]
            }
            viewModel.selectConnection(id: second)
            viewModel.selectConnection(id: latest)
            await waitUntil("the latest choice replaces the cancelled pre-flight") {
                await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
            }
            XCTAssert(backend.requestedConnectionIDs() == [first, latest])
            XCTAssert(backend.recordedCalls() == ["start", "cancel", "start"])
            XCTAssert(viewModel.selectedConnectionID == latest && viewModel.lastError == nil)
            viewModel.disconnect()
            await waitUntil("the cancellation test disconnects") {
                await MainActor.run { viewModel.connectionState == .idle && !viewModel.isOperationPending }
            }
            backend.clearRecordedCalls()
        }
        viewModel.selectConnection(id: first)

        // Picks during the very first connect are accepted immediately, but only
        // the latest one reaches the backend after that connect settles.
        await backend.startGate.enableBlocking()
        viewModel.connect()
        XCTAssert(viewModel.canChangeSelection, "servers must remain selectable while connecting in \(mode)")
        await backend.startGate.waitUntilEntered()
        viewModel.selectConnection(id: second)
        viewModel.selectConnection(id: third)
        XCTAssert(viewModel.selectedConnectionID == third && viewModel.lastError == nil)
        XCTAssert(backend.requestedConnectionIDs() == [first])
        XCTAssert(!viewModel.updateConnection(id: first, from: connections[1].configuration.rawLink))
        viewModel.removeConnection(id: first)
        XCTAssert(viewModel.savedConnections.contains { $0.id == first }, "the in-flight server must remain protected")
        viewModel.selectConnection(id: third)
        await backend.startGate.open()
        await waitUntil("latest initial selection connects") {
            await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
        }
        XCTAssert(backend.requestedConnectionIDs() == [first, third])
        XCTAssert(viewModel.canChangeSelection)
        viewModel.selectConnection(id: third)
        XCTAssert(!viewModel.isOperationPending, "selecting the current server must not reconnect")

        await backend.reconnectGate.enableBlocking()
        viewModel.selectConnection(id: second)
        XCTAssert(viewModel.isOperationPending && viewModel.canChangeSelection)
        // Coalesce rapid clicks even before the provider publishes its state.
        viewModel.selectConnection(id: first)
        viewModel.selectConnection(id: third)
        viewModel.selectConnection(id: first)
        XCTAssert(viewModel.selectedConnectionID == first)
        await backend.reconnectGate.waitUntilEntered()
        await waitUntil("the picker shows connection progress") {
            await MainActor.run { viewModel.connectionPhase == .starting }
        }
        XCTAssert(viewModel.canChangeSelection && viewModel.lastError == nil)
        XCTAssert(backend.requestedConnectionIDs() == [first, third, second])
        await backend.reconnectGate.open()
        await waitUntil("the latest replacement server connects") {
            await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
        }
        XCTAssert(backend.requestedConnectionIDs() == [first, third, second, first])
        XCTAssert(viewModel.lastError == nil)

        // Choosing the in-flight target again withdraws the pending switch.
        await backend.reconnectGate.enableBlocking()
        viewModel.selectConnection(id: second)
        viewModel.selectConnection(id: third)
        viewModel.selectConnection(id: second)
        await backend.reconnectGate.waitUntilEntered()
        await backend.reconnectGate.open()
        await waitUntil("the original target connects without another switch") {
            await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
        }
        XCTAssert(backend.requestedConnectionIDs() == [first, third, second, first, second])

        // A failure must not discard a newer selection.
        backend.failingConnectionID = third
        await backend.reconnectGate.enableBlocking()
        viewModel.selectConnection(id: third)
        await backend.reconnectGate.waitUntilEntered()
        viewModel.selectConnection(id: first)
        await backend.reconnectGate.open()
        await waitUntil("a newer selection recovers from the previous failure") {
            await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
        }
        XCTAssert(viewModel.selectedConnectionID == first && viewModel.lastError == nil)
        XCTAssert(Array(backend.requestedConnectionIDs().suffix(2)) == [third, first])

        // With no pending choice, failure still settles and permits a manual retry.
        viewModel.selectConnection(id: third)
        await waitUntil("a failed switch settles") {
            await MainActor.run { viewModel.connectionPhase == .failed && !viewModel.isOperationPending }
        }
        XCTAssert(viewModel.selectedConnectionID == third)
        XCTAssert(viewModel.canChangeSelection && viewModel.canConnect && viewModel.lastError != nil)
        backend.failingConnectionID = nil
        viewModel.selectConnection(id: first)
        XCTAssert(!viewModel.isOperationPending, "selection after failure must not start a hidden connection")
        viewModel.connect()
        await waitUntil("retry connects") {
            await MainActor.run { viewModel.isConnected && !viewModel.isOperationPending }
        }

        // Disconnect wins over any pending selection.
        await backend.reconnectGate.enableBlocking()
        viewModel.selectConnection(id: second)
        await backend.reconnectGate.waitUntilEntered()
        viewModel.selectConnection(id: third)
        let requestsBeforeDisconnect = backend.requestedConnectionIDs()
        viewModel.disconnect()
        XCTAssert(!viewModel.canChangeSelection)
        await backend.reconnectGate.open()
        await waitUntil("disconnect completes without starting the pending server") {
            await MainActor.run { viewModel.connectionState == .idle && !viewModel.isOperationPending }
        }
        XCTAssert(backend.requestedConnectionIDs() == requestsBeforeDisconnect)
        XCTAssert(backend.recordedCalls().last == "stop")
        XCTAssert(viewModel.selectedConnectionID == third && viewModel.canConnect)

        await backend.startGate.enableBlocking()
        viewModel.connect()
        await backend.startGate.waitUntilEntered()
        viewModel.selectConnection(id: first)
        let requestsBeforeQuit = backend.requestedConnectionIDs()
        let terminated = Flag()
        viewModel.handleAppTermination { terminated.set() }
        await backend.startGate.open()
        await waitUntil("quit completes without connecting the pending choice") { terminated.isSet }
        XCTAssert(backend.requestedConnectionIDs() == requestsBeforeQuit)
    }

    func testFactorySelectsProviderByMode() {
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

        XCTAssert(factory.makeProvider(for: .systemProxy) is SystemProxyConnectionProvider)
        XCTAssert(factory.makeProvider(for: .tun) is RootXrayConnectionProvider)
    }

    func testConnectionStateStorePublishesInitialAndUpdatedStates() async {
        let store = ConnectionStateStore(initialState: .idle)
        let stream = store.stream()
        let reader = collectStates(from: stream, count: 3)

        store.update(.preparing)
        store.update(.connecting)
        let states = await reader.value
        XCTAssert(stateLabels(states) == ["idle", "preparing", "connecting"], "unexpected state stream order: \(states)")
        XCTAssert(store.current() == .connecting)
    }

    func testProviderConnectReconnectAndDisconnect() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .tun, backend: backend)
        let request = try makeRequest()
        await awaitInitialState(provider)

        let connectReader = collectStates(from: provider.stateUpdates(), count: 4)
        try await provider.connect(request)
        let connectStates = await connectReader.value
        XCTAssert(stateLabels(connectStates) == ["idle", "preparing", "connecting", "connected"])
        XCTAssert(backend.recordedCalls() == ["start"])

        let reconnectReader = collectStates(from: provider.stateUpdates(), count: 4)
        try await provider.connect(request)
        let reconnectStates = await reconnectReader.value
        XCTAssert(stateLabels(reconnectStates) == ["connected", "preparing", "connecting", "connected"])
        XCTAssert(backend.recordedCalls() == ["start", "reconnect"])

        let disconnectReader = collectStates(from: provider.stateUpdates(), count: 3)
        try await provider.disconnect()
        let disconnectStates = await disconnectReader.value
        XCTAssert(stateLabels(disconnectStates) == ["connected", "disconnecting", "idle"])
        XCTAssert(backend.recordedCalls() == ["start", "reconnect", "stop"])
    }

    /// Xray dying under a connected session used to leave the system pointed at a
    /// dead local port with the app still saying "connected". The provider now
    /// watches the runtime and, when it is gone, fails the session and runs the
    /// backend's teardown so settings are put back.
    func testLostRuntimeFailsTheSessionAndRestoresSettings() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend, supervisionInterval: 0.05)
        await awaitInitialState(provider)

        backend.setRuntimeActive(true)
        try await provider.connect(try makeRequest())
        let connectedState = await provider.currentState()
        XCTAssert(stateLabels([connectedState]) == ["connected"])

        // Still alive: the supervisor must not touch a healthy session.
        try await Task.sleep(nanoseconds: 200_000_000)
        let stillConnectedState = await provider.currentState()
        XCTAssert(stateLabels([stillConnectedState]) == ["connected"])
        XCTAssert(backend.recordedCalls() == ["start"])

        // One missed check is not a lost runtime: the check runs over XPC and the
        // first one after a wake can miss its deadline with Xray alive.
        let previousInactiveChecks = backend.inactiveRuntimeChecks()
        backend.missNextRuntimeCheck()
        await waitUntil("the supervisor checks the runtime") { backend.inactiveRuntimeChecks() > previousInactiveChecks }
        XCTAssertEqual(backend.inactiveRuntimeChecks(), previousInactiveChecks + 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterOneMissState = await provider.currentState()
        XCTAssert(stateLabels([afterOneMissState]) == ["connected"], "one missed check failed the session")
        XCTAssert(backend.recordedCalls() == ["start"])

        let failureReader = collectStates(from: provider.stateUpdates(), count: 2)
        backend.setRuntimeActive(false)
        let states = await failureReader.value
        XCTAssert(stateLabels(states) == ["connected", "failed"], "expected a lost runtime to fail the session, got \(stateLabels(states))")

        // The teardown that restores proxy settings or routes follows the failure.
        await waitUntil("the backend teardown runs after a lost runtime") { backend.recordedCalls() == ["start", "stop"] }

        // Only once: the supervisor stops with the session it was watching.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssert(backend.recordedCalls() == ["start", "stop"])
    }

    func testProviderPublishesStartAndStopFailures() async throws {
        let startBackend = RecordingConnectionBackend()
        startBackend.startError = TestError.startFailed
        let startProvider = BackendConnectionProvider(mode: .systemProxy, backend: startBackend)
        await awaitInitialState(startProvider)
        let startReader = collectStates(from: startProvider.stateUpdates(), count: 4)

        do {
            try await startProvider.connect(try makeRequest())
            XCTFail("expected injected start failure")
        } catch TestError.startFailed {
            // Expected.
        }

        let startStates = await startReader.value
        XCTAssert(stateLabels(startStates) == ["idle", "preparing", "connecting", "failed"])
        guard case .failed(let failure) = startStates.last else {
            XCTFail("expected failed terminal state")
            return
        }
        XCTAssert(failure.summary == TestError.startFailed.localizedDescription)

        let stopBackend = RecordingConnectionBackend()
        let stopProvider = BackendConnectionProvider(mode: .tun, backend: stopBackend)
        await awaitInitialState(stopProvider)
        try await stopProvider.connect(try makeRequest())
        stopBackend.stopError = TestError.stopFailed
        let stopReader = collectStates(from: stopProvider.stateUpdates(), count: 3)

        do {
            try await stopProvider.disconnect()
            XCTFail("expected injected stop failure")
        } catch TestError.stopFailed {
            // Expected.
        }

        let stopStates = await stopReader.value
        XCTAssert(stateLabels(stopStates) == ["connected", "disconnecting", "failed"])
        guard case .failed(let failure) = stopStates.last else {
            XCTFail("expected failed terminal state")
            return
        }
        XCTAssert(failure.summary == TestError.stopFailed.localizedDescription)
    }

    func testProxyConflictNotificationStopsSessionAndBlocksAutomaticReconnect() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend, supervisionInterval: 60)
        await awaitInitialState(provider)
        backend.setRuntimeActive(true)
        try await provider.connect(try makeRequest())
        let failure = ConnectionFailure(summary: "Proxy changed", details: "External settings preserved", requiresExplicitReconnect: true)
        backend.setSessionFailure(failure)
        await waitUntil("conflict is reported") { await provider.currentState() == .failed(failure) }
        await waitUntil("conflict tears down") { backend.recordedCalls().contains("stop") }
        // A late queued disconnect cannot erase the provider's reconnect fence.
        try await provider.disconnect()
        backend.setSessionFailure(nil)
        var automatic = try makeRequest()
        automatic.isAutomaticReconnect = true
        do {
            try await provider.connect(automatic)
            XCTFail("automatic reconnect must not reclaim settings")
        } catch { XCTAssertEqual(error as? ConnectionFailure, failure) }
        XCTAssertEqual(backend.recordedCalls().filter { $0 == "start" }.count, 1)
        try await provider.connect(try makeRequest())
        XCTAssertEqual(backend.recordedCalls().filter { $0 == "start" }.count, 2)
        try await provider.disconnect()
    }

    func testProxyConflictPollingFallbackAndCleanupFailure() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .tun, backend: backend, supervisionInterval: 0.02)
        await awaitInitialState(provider)
        backend.setRuntimeActive(true)
        try await provider.connect(try makeRequest())
        backend.stopError = TestError.stopFailed
        backend.setSessionFailure(
            ConnectionFailure(summary: "Network location changed", details: "Reconnect explicitly", requiresExplicitReconnect: true), notify: false)
        await waitUntil("cleanup failure reported") {
            guard case .failed(let failure) = await provider.currentState() else { return false }
            return failure.requiresExplicitReconnect && (failure.details?.contains("Injected stop failure") == true)
        }
        backend.stopError = nil
        try await provider.disconnect()
    }

    func testConflictDuringStartNeverPublishesConnected() async throws {
        let backend = RecordingConnectionBackend()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend, supervisionInterval: 60)
        await awaitInitialState(provider)
        let failure = ConnectionFailure(summary: "Proxy changed during start", details: nil, requiresExplicitReconnect: true)
        backend.setSessionFailure(failure)
        do {
            try await provider.connect(try makeRequest())
            XCTFail("must reject a start with conflicting proxy settings")
        } catch { XCTAssertEqual(error as? ConnectionFailure, failure) }
        let state = await provider.currentState()
        XCTAssertEqual(state, .failed(failure))
        XCTAssertEqual(backend.recordedCalls(), ["start", "stop"])
    }

    @MainActor
    func testConflictRemainsVisibleAndExplicitConnectCanRetry() async throws {
        let root = try makeIsolatedRoot("proxy-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingConnectionBackend()
        let (model, store) = try makeLaunchFixture(root: root, mode: .tun, enabled: false, backend: backend)
        defer { store.deleteStoredDataForTesting() }
        await waitUntil("ready") { await MainActor.run { model.canConnect } }
        backend.setRuntimeActive(true)
        model.connect()
        await waitUntil("connected") { await MainActor.run { model.isConnected && !model.isOperationPending } }
        let failure = ConnectionFailure(summary: "Proxy changed", details: "External change kept", requiresExplicitReconnect: true)
        backend.setSessionFailure(failure)
        await waitUntil("visible conflict") { await MainActor.run { model.connectionError == failure } }
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.canConnect)
        backend.setSessionFailure(nil)
        model.connect()
        await waitUntil("explicit retry connects") { await MainActor.run { model.isConnected && !model.isOperationPending } }
        XCTAssertNil(model.connectionError)
        model.disconnect()
        await waitUntil("stopped") { await MainActor.run { model.connectionState == .idle } }
    }

    func testProviderSerializesConcurrentConnects() async throws {
        let backend = RecordingConnectionBackend()
        await backend.startGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .tun, backend: backend)
        let request = try makeRequest()

        let first = Task { try await provider.connect(request) }
        await backend.startGate.waitUntilEntered()

        let second = Task { try await provider.connect(request) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssert(
            backend.recordedCalls() == ["start"],
            "second connect reached the backend before the first finished: \(backend.recordedCalls())"
        )

        await backend.startGate.open()
        try await first.value
        try await second.value
        // The first connect left the provider connected, so the queued second one
        // takes the reconnect branch — proving it observed the finished first op.
        XCTAssert(
            backend.recordedCalls() == ["start", "reconnect"],
            "unexpected call order: \(backend.recordedCalls())"
        )
    }

    func testDisconnectRunsAfterActiveConnect() async throws {
        let backend = RecordingConnectionBackend()
        await backend.startGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)

        let connectTask = Task { try await provider.connect(try makeRequest()) }
        await backend.startGate.waitUntilEntered()

        let disconnectTask = Task { try await provider.disconnect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssert(
            backend.recordedCalls() == ["start"],
            "disconnect ran before the active connect finished: \(backend.recordedCalls())"
        )

        await backend.startGate.open()
        try await connectTask.value
        try await disconnectTask.value
        XCTAssert(
            backend.recordedCalls() == ["start", "stop"],
            "unexpected call order: \(backend.recordedCalls())"
        )
    }

    /// A connect still in its pre-flight has changed nothing, so a disconnect
    /// cancels it instead of waiting behind it; the connect ends idle, not failed,
    /// and the queued disconnect finds nothing to stop.
    func testDisconnectCancelsUncommittedConnect() async throws {
        let backend = RecordingConnectionBackend()
        backend.startObservesCancellation = true
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        await awaitInitialState(provider)

        let connectTask = Task { try await provider.connect(try makeRequest()) }
        await waitUntil("the connect reaches the backend") { !backend.recordedCalls().isEmpty }
        XCTAssert(backend.recordedCalls() == ["start"], "connect did not start")

        try await provider.disconnect()
        do {
            try await connectTask.value
            XCTFail("cancelled connect returned without an error")
        } catch is CancellationError {
        } catch {
            XCTFail("cancelled connect threw \(error) instead of CancellationError")
        }
        let finalState = await provider.currentState()
        XCTAssert(finalState == .idle, "cancelled connect did not end idle: \(finalState)")
        XCTAssert(
            backend.recordedCalls() == ["start"],
            "disconnect stopped a backend that never started: \(backend.recordedCalls())"
        )
    }

    func testDisconnectWaitsForStartupRestoration() async throws {
        let backend = RecordingConnectionBackend()
        backend.hasRestorableStateValue = true
        await backend.restoreGate.enableBlocking()
        let provider = BackendConnectionProvider(mode: .systemProxy, backend: backend)
        await backend.restoreGate.waitUntilEntered()

        let disconnectTask = Task { try await provider.disconnect() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssert(
            backend.recordedCalls() == ["restore"],
            "disconnect ran before startup restoration completed: \(backend.recordedCalls())"
        )

        await backend.restoreGate.open()
        try await disconnectTask.value
        // Restoration ends in .idle, so the queued disconnect is a no-op.
        XCTAssert(
            backend.recordedCalls() == ["restore"],
            "unexpected restoration cleanup calls: \(backend.recordedCalls())"
        )
    }

    func testTerminationCompletesOnlyAfterProviderDisconnect() async throws {
        let root = try makeIsolatedRoot("termination")
        defer { try? FileManager.default.removeItem(at: root) }
        let (viewModel, backend, store) = try await makeTerminationFixture(root: root)
        defer { store.deleteStoredDataForTesting() }

        await backend.stopGate.enableBlocking()
        let completed = Flag()
        viewModel.handleAppTermination { completed.set() }
        await backend.stopGate.waitUntilEntered()
        XCTAssert(!completed.isSet, "termination completed before the provider disconnected")

        await backend.stopGate.open()
        await waitUntil("termination completes after disconnect") { completed.isSet }
        XCTAssert(
            backend.recordedCalls() == ["start", "stop"],
            "unexpected termination calls: \(backend.recordedCalls())"
        )
    }

    /// A connected view model over an isolated store, for the termination checks.
    private func makeTerminationFixture(
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
            // proxy snapshot, nor leave a launch popover in the real log.
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
    func testTerminationGivesUpOnAStuckTeardown() async throws {
        let root = try makeIsolatedRoot("termination-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let (viewModel, backend, store) = try await makeTerminationFixture(root: root)
        defer { store.deleteStoredDataForTesting() }
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
    private func waitUntil(
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
        XCTFail("timed out waiting until \(expectation)")
    }

    /// The provider resolves its starting state as the first queued operation, so a
    /// test that subscribes to the stream must let that finish before asserting.
    private func awaitInitialState(_ provider: BackendConnectionProvider) async {
        await waitUntil("the provider resolves its initial state") {
            await provider.currentState() != .preparing
        }
    }

    private func makeRequest() throws -> ConnectionRequest {
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Provider"
        )
        return ConnectionRequest(
            defaultConnection: RoutedConnection(id: UUID(), configuration: configuration),
            localProxy: .default,
            splitTunnelPolicy: SplitTunnelPolicy(rules: [], defaultAction: .proxy)
        )
    }

    private func collectStates(from stream: AsyncStream<ConnectionState>, count: Int) -> Task<[ConnectionState], Never> {
        Task {
            var states: [ConnectionState] = []
            for await state in stream {
                states.append(state)
                if states.count == count { break }
            }
            return states
        }
    }

    private func stateLabels(_ states: [ConnectionState]) -> [String] {
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

    func testConnectionPresentationMapping() {
        XCTAssert(
            ConnectionPresentation(state: .idle, hasConfiguration: false)
                == ConnectionPresentation(connectionPhase: .unconfigured, proxyPhase: .disabled)
        )
        XCTAssert(
            ConnectionPresentation(state: .idle, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopped, proxyPhase: .disabled)
        )
        XCTAssert(
            ConnectionPresentation(state: .preparing, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        XCTAssert(
            ConnectionPresentation(state: .awaitingUserApproval, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        XCTAssert(
            ConnectionPresentation(state: .connecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .starting, proxyPhase: .enabling)
        )
        XCTAssert(
            ConnectionPresentation(
                state: .connected(.init(id: UUID(), mode: .tun, connectedAt: Date())),
                hasConfiguration: true
            ) == ConnectionPresentation(connectionPhase: .running, proxyPhase: .enabled)
        )
        XCTAssert(
            ConnectionPresentation(state: .disconnecting, hasConfiguration: true)
                == ConnectionPresentation(connectionPhase: .stopping, proxyPhase: .disabling)
        )
        let failedPresentation = ConnectionPresentation(
            state: .failed(.init(summary: "failed", details: nil)),
            hasConfiguration: true
        )
        XCTAssert(failedPresentation == ConnectionPresentation(connectionPhase: .failed, proxyPhase: .failed))
        XCTAssert(failedPresentation.canChangeSelection, "failed state must preserve selection changes")
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
            entered = false
            opened = false
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
            XCTAssert(entered, "backend call did not start in time")
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
        private var connectionIDs: [UUID] = []
        var startError: Error?
        var failingConnectionID: UUID?
        var cancellableConnectionID: UUID?
        var stopError: Error?
        var hasRestorableStateValue = false
        var hasActiveRuntimeSessionValue = false
        private var inactiveChecks = 0
        private var missOneRuntimeCheck = false
        private var failure: ConnectionFailure?
        private var changeContinuation: AsyncStream<Void>.Continuation?
        /// Stands in for a pre-flight that polls for cancellation.
        var startObservesCancellation = false
        let startGate = Gate()
        let reconnectGate = Gate()
        let restoreGate = Gate()
        let stopGate = Gate()

        func hasRestorableState() -> Bool { hasRestorableStateValue }
        func sessionFailure() async -> ConnectionFailure? { readFailure() }
        private func readFailure() -> ConnectionFailure? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
        func sessionChanges() -> AsyncStream<Void> {
            lock.lock()
            defer { lock.unlock() }
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            changeContinuation = continuation
            return stream
        }
        func setSessionFailure(_ failure: ConnectionFailure?, notify: Bool = true) {
            lock.lock()
            self.failure = failure
            if notify { changeContinuation?.yield(()) }
            lock.unlock()
        }
        func hasActiveRuntimeSession() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if missOneRuntimeCheck {
                missOneRuntimeCheck = false
                inactiveChecks += 1
                return false
            }
            if !hasActiveRuntimeSessionValue { inactiveChecks += 1 }
            return hasActiveRuntimeSessionValue
        }

        func missNextRuntimeCheck() {
            lock.lock()
            missOneRuntimeCheck = true
            lock.unlock()
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
            recordConnectionID(request.defaultConnection.id)
            if request.defaultConnection.id == cancellableConnectionID {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                cancellableConnectionID = nil
                record("cancel")
                throw CancellationError()
            }
            if startObservesCancellation {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                throw CancellationError()
            }
            await startGate.enter()
            if let startError { throw startError }
            if request.defaultConnection.id == failingConnectionID { throw TestError.startFailed }
        }

        func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
            record("reconnect")
            recordConnectionID(request.defaultConnection.id)
            await reconnectGate.enter()
            if let startError { throw startError }
            if request.defaultConnection.id == failingConnectionID { throw TestError.startFailed }
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

        func requestedConnectionIDs() -> [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return connectionIDs
        }

        func clearRecordedCalls() {
            lock.lock()
            calls.removeAll()
            connectionIDs.removeAll()
            lock.unlock()
        }

        private func recordConnectionID(_ id: UUID) {
            lock.lock()
            connectionIDs.append(id)
            lock.unlock()
        }

        private func record(_ call: String) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }
    }
}
