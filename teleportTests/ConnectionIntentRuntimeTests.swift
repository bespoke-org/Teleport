import Foundation
import XCTest

@MainActor
final class ConnectionIntentRuntimeTests: XCTestCase {
    func testAlternatingClicksDuringConnectApplyOnlyTheLastWish() async throws {
        let f = try await IntentFixture()
        await f.backend.startGate.hold()
        f.connect()
        await waitUntil { f.backend.calls == ["start"] }
        for _ in 0..<20 { f.disconnect(); f.connect() }
        let off = f.disconnect()
        XCTAssertEqual(f.backend.calls, ["start"])
        await f.backend.startGate.release()
        try await f.runtime.waitForDisconnect(revision: off)
        XCTAssertEqual(f.backend.calls, ["start", "stop"])
        XCTAssertEqual(f.backend.maximumConcurrentOperations, 1)
    }

    func testEquivalentConnectsDoNotRestartASession() async throws {
        let f = try await IntentFixture()
        await f.backend.startGate.hold()
        f.connect()
        await waitUntil { f.backend.calls == ["start"] }
        for _ in 0..<20 { f.connect() }
        await f.backend.startGate.release()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start"])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testAnExplicitRequestDoesNotAssumeAnExistingSessionUsesItsConfiguration() async throws {
        let f = try await IntentFixture(existingSession: true)
        await waitUntil { await f.provider.currentState().isConnected }
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["stop", "start"])
        XCTAssertEqual(f.backend.requests, [f.request])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testAdoptingTheExistingSessionKeepsItRunning() async throws {
        let f = try await IntentFixture(existingSession: true, adopt: true)
        await waitUntil { f.runtime.snapshot.appliedRequest == f.request }
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, [])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testDisconnectDuringNetworkRebuildPreventsTheNextConnect() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        await f.backend.stopGate.hold()
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        await waitUntil { f.backend.calls == ["start", "stop"] }
        let off = f.disconnect()
        await f.backend.stopGate.release()
        try await f.runtime.waitForDisconnect(revision: off)
        XCTAssertEqual(f.backend.calls, ["start", "stop"])
    }

    func testRouteReturningDuringTeardownIsNotLost() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        await f.backend.stopGate.hold()
        f.runtime.networkChanged(nil, settled: true)
        await waitUntil { f.backend.calls == ["start", "stop"] }
        f.runtime.networkChanged(IntentFixture.wifi, settled: false)
        await f.backend.stopGate.release()
        await waitUntil { f.backend.calls == ["start", "stop", "start"] }
        await waitUntil { await f.provider.currentState().isConnected }
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
        XCTAssertEqual(f.backend.maximumConcurrentOperations, 1)
    }

    func testAnUnchangedPrimaryRouteDoesNotRestartTheTunnel() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.runtime.networkChanged(IntentFixture.wifi, settled: true)
        // An extra connect is also a barrier through the runner for these inputs.
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start"])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testFailureWaitsForAnExplicitRetry() async throws {
        let f = try await IntentFixture()
        f.backend.failStart = true
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        for _ in 0..<10 { f.runtime.networkChanged(IntentFixture.wifi, settled: false) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.backend.calls, ["start"])
        f.backend.failStart = false
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start", "start"])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testLatestTargetIsReadAfterDisconnectFinishes() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        await f.backend.stopGate.hold()
        let second = try IntentFixture.request(port: 10)
        let third = try IntentFixture.request(port: 11)
        f.runtime.request(.connected(second))
        await waitUntil { f.backend.calls == ["start", "stop"] }
        f.runtime.request(.connected(third))
        await f.backend.stopGate.release()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.requests, [f.request, third])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testFailedCleanupBlocksStartingAnotherTunnelUntilRetrySucceeds() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.backend.failStop = true
        let replacement = try IntentFixture.request(port: 10)
        f.runtime.request(.connected(replacement))
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start", "stop"])
        XCTAssertEqual(f.backend.requests, [f.request])
        f.backend.failStop = false
        f.runtime.request(.connected(replacement))
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "stop", "start"])
        XCTAssertEqual(f.backend.requests, [f.request, replacement])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testNetworkChangeDuringConnectIsAppliedAfterThatConnectFinishes() async throws {
        let f = try await IntentFixture()
        await f.backend.startGate.hold()
        f.connect()
        await waitUntil { f.backend.calls == ["start"] }
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        await f.backend.startGate.release()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start"])
        XCTAssertEqual(f.backend.maximumConcurrentOperations, 1)
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testSystemProxyKeepsItsSessionWhenThePrimaryRouteChanges() async throws {
        let f = try await IntentFixture(mode: .systemProxy)
        f.runtime.request(.connected(f.request))
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        f.runtime.request(.connected(f.request))
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        XCTAssertEqual(f.backend.calls, ["start"])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testTransientRecoveryFailureRetriesOnTheClock() async throws {
        let clock = IntentClock()
        let f = try await IntentFixture(clock: clock)
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.backend.failWithNetworkError = true
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        await waitUntil { clock.sleepCount == 1 }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start"])
        f.backend.failWithNetworkError = false
        clock.advance(by: .seconds(5))
        await waitUntil {
            let state = await f.provider.currentState()
            return f.backend.requests.count == 3 && state.isConnected
        }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start", "start"])
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
    }

    func testDisconnectCancelsRecoveryRetriesAndNetworkChangesCannotReviveThem() async throws {
        let clock = IntentClock()
        let f = try await IntentFixture(clock: clock)
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.backend.failWithNetworkError = true
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        await waitUntil { clock.sleepCount == 1 }
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
        await waitUntil { clock.sleepCount == 0 }
        clock.advance(by: .seconds(5))
        f.runtime.networkChanged(IntentFixture.wifi, settled: true)
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start"], "Failed preflight already left the provider idle")
    }

    func testManualDisconnectEndsRecoveryPolicy() async throws {
        let clock = IntentClock()
        let f = try await IntentFixture(clock: clock)
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        f.runtime.networkChanged(nil, settled: true)
        await waitUntil { f.runtime.snapshot.activity == .waitingForNetwork }
        try await f.runtime.waitForDisconnect(revision: f.disconnect())
        f.runtime.networkChanged(IntentFixture.wifi, settled: true)
        f.backend.failWithNetworkError = true
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.intentRevision == f.runtime.intentRevision }
        clock.advance(by: .seconds(10))
        // A new, equivalent observation gives the executor another turn.
        f.runtime.networkChanged(IntentFixture.wifi, settled: true)
        XCTAssertEqual(clock.sleepCount, 0)
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start"])
        try await f.runtime.close()
    }

    func testNewTargetIsNotConsumedByFailureOfPreviousSession() async throws {
        let provider = ControlledIntentProvider()
        let runtime = ConnectionIntentRuntime(provider: provider, mode: .systemProxy)
        await runtime.start()
        let first = try IntentFixture.request(port: 9)
        let next = try IntentFixture.request(port: 10)
        runtime.request(.connected(first))
        await waitUntil { runtime.snapshot.isSettled && runtime.snapshot.appliedRequest == first }
        await provider.readGate.hold()
        provider.publish(.failed(.init(summary: "Previous session died", details: nil)))
        runtime.request(.connected(next))
        await provider.readGate.release()
        await waitUntil { runtime.snapshot.isSettled && runtime.snapshot.intentRevision == runtime.intentRevision }
        XCTAssertEqual(provider.requests, [first, next])
        try await runtime.close()
    }

    func testStartupDiscoveryNeverRestoresProxyForAnExistingSession() async throws {
        let provider = ControlledIntentProvider(initial: .preparing)
        let restorer = RecordingProxyRestore()
        let runtime = ConnectionIntentRuntime(provider: provider, mode: .systemProxy,
                                               proxyRestorer: DeferredProxyRestorer(service: restorer))
        let request = try IntentFixture.request(port: 9)
        await runtime.start(adopting: request)
        // Readiness is unknown, even though it is not yet 'connected'.
        await waitUntil { provider.stateReadCount > 0 }
        XCTAssertEqual(restorer.calls, 0)
        provider.publish(.connected(.init(id: UUID(), mode: .systemProxy, connectedAt: Date())))
        await waitUntil { runtime.snapshot.isSettled && runtime.snapshot.appliedRequest == request }
        XCTAssertEqual(restorer.calls, 0)
        XCTAssertEqual(provider.requests, [])
        try await runtime.close()
    }

    func testRuntimeConnectsAndPublishesWithoutAnyPresentationSubscriber() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.appliedRequest == f.request }
        XCTAssertTrue(f.runtime.snapshot.state.isConnected)
        try await f.runtime.close()
        XCTAssertEqual(f.runtime.snapshot.state, .idle)
    }

    func testPendingRestoreSerializesWithTheLatestConnectionRequest() async throws {
        let provider = ControlledIntentProvider()
        let service = RecordingProxyRestore(blocked: true)
        let runtime = ConnectionIntentRuntime(provider: provider, mode: .systemProxy,
                                               proxyRestorer: DeferredProxyRestorer(service: service))
        await runtime.start()
        await waitUntil { service.calls == 1 }
        runtime.request(.connected(try IntentFixture.request(port: 9)))
        let latest = try IntentFixture.request(port: 10)
        runtime.request(.connected(latest))
        XCTAssertEqual(provider.requests, [])
        XCTAssertEqual(runtime.snapshot.activity, .restoringProxy)
        service.finish()
        await waitUntil { runtime.snapshot.isSettled && runtime.snapshot.appliedRequest == latest }
        XCTAssertEqual(provider.requests, [latest])
        try await runtime.close()
    }

    func testReplacingProviderClearsRecoveryAndCleansUpTheOldProvider() async throws {
        let clock = IntentClock()
        let f = try await IntentFixture(clock: clock)
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.appliedRequest == f.request }
        f.backend.failWithNetworkError = true
        f.runtime.networkChanged(.init(interfaceName: "en7", routerAddress: "172.20.10.1"), settled: true)
        await waitUntil { clock.sleepCount == 1 }
        let replacement = ControlledIntentProvider()
        f.runtime.replaceProvider(replacement, mode: .systemProxy, adopting: nil)
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.providerID == f.runtime.providerID }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "start"], "Failed preflight already left the provider idle")
        await waitUntil { clock.sleepCount == 0 }
        clock.advance(by: .seconds(10))
        XCTAssertEqual(replacement.requests, [])
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.appliedRequest == f.request }
        XCTAssertEqual(replacement.requests, [f.request])
        try await f.runtime.close()
    }

    func testModeChangeCleanupFailureRemainsVisibleAndRetryable() async throws {
        let f = try await IntentFixture()
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.appliedRequest == f.request }
        f.backend.failStop = true
        let replacement = ControlledIntentProvider()
        f.runtime.replaceProvider(replacement, mode: .systemProxy, adopting: nil)
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.providerID == f.runtime.providerID }
        XCTAssertNotNil(f.runtime.snapshot.failure)
        XCTAssertEqual(replacement.requests, [])
        f.backend.failStop = false
        f.connect()
        await waitUntil { f.runtime.snapshot.isSettled && f.runtime.snapshot.appliedRequest == f.request }
        XCTAssertEqual(f.backend.calls, ["start", "stop", "stop"])
        XCTAssertEqual(replacement.requests, [f.request])
        try await f.runtime.close()
    }

    func testFailureDuringStartupIsPublishedWithoutUIFeedback() async throws {
        let error = ConnectionFailure(summary: "Startup cleanup failed", details: nil)
        let provider = ControlledIntentProvider(initial: .failed(error))
        let runtime = ConnectionIntentRuntime(provider: provider, mode: .systemProxy)
        await runtime.start()
        await waitUntil { runtime.snapshot.isSettled }
        XCTAssertEqual(runtime.snapshot.failure, error)
        try await runtime.close()
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Intent runtime did not converge")
    }
}

private final class IntentFixture {
    static let wifi = SystemUplinkInventory.Uplink(interfaceName: "en0", routerAddress: "192.168.1.1")
    let backend: IntentBackend
    let runtime: ConnectionIntentRuntime
    let provider: BackendConnectionProvider
    let request: ConnectionRequest

    init(clock: any LifecycleClock = SuspendingLifecycleClock(), existingSession: Bool = false,
         adopt: Bool = false, mode: ConnectionMode = .tun) async throws {
        backend = IntentBackend(active: existingSession)
        request = try Self.request(port: 9)
        provider = BackendConnectionProvider(mode: mode, backend: backend, supervisionInterval: 3600)
        runtime = ConnectionIntentRuntime(provider: provider, mode: mode, clock: clock)
        runtime.networkChanged(Self.wifi, settled: true)
        await runtime.start(adopting: adopt ? request : nil)
    }

    static func request(port: Int) throws -> ConnectionRequest {
        let config = try ConnectionLinkParser().parse("vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:\(port)?security=none&type=tcp#Test")
        return ConnectionRequest(defaultConnection: .init(id: UUID(), configuration: config), localProxy: .default,
                                 splitTunnelPolicy: .init(rules: [], defaultAction: .proxy), usesLeakGuard: false)
    }

    @discardableResult func connect() -> UInt64 { runtime.request(.connected(request)) }
    @discardableResult func disconnect() -> UInt64 { runtime.request(.disconnected) }
}

nonisolated private final class IntentClock: LifecycleClock, @unchecked Sendable {
    private let time = Watch(SuspendingClock().now)
    private let lock = NSLock()
    private var sleepers = 0
    var now: SuspendingClock.Instant { time.snapshot().value }
    var sleepCount: Int { lock.withLock { sleepers } }
    func advance(by duration: Duration) { time.update { $0 += duration } }
    func sleep(for duration: Duration) async throws {
        var instant = time.snapshot()
        let deadline = instant.value + duration
        lock.withLock { sleepers += 1 }
        defer { lock.withLock { sleepers -= 1 } }
        while instant.value < deadline { instant = try await time.changed(after: instant.revision) }
    }
}

private actor IntentGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() { held = true }
    func release() { held = false; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func enter() async {
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
}

private final class IntentBackend: ConnectionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedRequests: [ConnectionRequest] = []
    private var running = 0
    private var maxRunning = 0
    private var active = false
    private var failure = false
    private var stopFailure = false
    private var networkFailure = false
    let startGate = IntentGate()
    let stopGate = IntentGate()
    init(active: Bool = false) { self.active = active }
    var calls: [String] { lock.withLock { recordedCalls } }
    var requests: [ConnectionRequest] { lock.withLock { recordedRequests } }
    var maximumConcurrentOperations: Int { lock.withLock { maxRunning } }
    var failStart: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var failStop: Bool {
        get { lock.withLock { stopFailure } }
        set { lock.withLock { stopFailure = newValue } }
    }
    var failWithNetworkError: Bool {
        get { lock.withLock { networkFailure } }
        set { lock.withLock { networkFailure = newValue } }
    }
    func hasRestorableState() -> Bool { false }
    func hasActiveRuntimeSession() -> Bool { lock.withLock { active } }
    func restorePreviousState() async throws {}
    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        begin("start")
        defer { end() }
        lock.withLock { recordedRequests.append(request) }
        await startGate.enter()
        if failStart { throw URLError(.userAuthenticationRequired) }
        if failWithNetworkError { throw XrayTunConnectionError.proxyAddressResolutionFailed("test.invalid") }
        lock.withLock { active = true }
    }
    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        XCTFail("The intent runtime must reread inputs between stop and start")
    }
    func stop() async throws {
        begin("stop")
        defer { end() }
        await stopGate.enter()
        if failStop { throw URLError(.cannotWriteToFile) }
        lock.withLock { active = false }
    }
    private func begin(_ operation: String) {
        lock.withLock { recordedCalls.append(operation); running += 1; maxRunning = max(maxRunning, running) }
    }
    private func end() { lock.withLock { running -= 1 } }
}

nonisolated private final class ControlledIntentProvider: ConnectionProvider, @unchecked Sendable {
    private let state: ConnectionStateStore
    private let lock = NSLock()
    private var recorded: [ConnectionRequest] = []
    private var reads = 0
    let readGate = IntentGate()
    var requests: [ConnectionRequest] { lock.withLock { recorded } }
    var stateReadCount: Int { lock.withLock { reads } }
    init(initial: ConnectionState = .idle) { state = ConnectionStateStore(initialState: initial) }
    func currentState() async -> ConnectionState {
        await readGate.enter()
        lock.withLock { reads += 1 }
        return state.current()
    }
    func stateUpdates() -> AsyncStream<ConnectionState> { state.stream() }
    func publish(_ value: ConnectionState) { state.update(value) }
    func connect(_ request: ConnectionRequest) async throws {
        lock.withLock { recorded.append(request) }
        state.update(.connected(.init(id: UUID(), mode: .systemProxy, connectedAt: Date())))
    }
    func disconnect() async throws { state.update(.idle) }
}

nonisolated private final class RecordingProxyRestore: DeferredProxyRestoring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let blocked: Bool
    private let gate = DispatchSemaphore(value: 0)
    init(blocked: Bool = false) { self.blocked = blocked }
    func finish() { gate.signal() }
    var calls: Int { lock.withLock { count } }
    func restoreDeferredProxyStateIfNeeded() throws {
        lock.withLock { count += 1 }
        if blocked { gate.wait() }
    }
}
