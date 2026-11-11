import Foundation
import XCTest

/// The wake and uplink halves of the session lifecycle, exercised through a real
/// AppViewModel whose observers and uplink lookup are injected. Neither a closed
/// laptop lid nor an interface going down is something a check can arrange on the
/// machine it runs on; the observers fire those events here instead, and the
/// uplink is a box the test swaps.
@MainActor
final class AppViewModelWakeUplinkTests: XCTestCase {
    func testWakeRebuildsAnEstablishedSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.wake.simulateSleep()
        try await Task.sleep(for: .milliseconds(50))
        fixture.wake.simulateWake()
        await waitUntil { fixture.provider.disconnectCount == 1 }
        await waitUntil { fixture.provider.connectCount == 1 && fixture.model.isConnected }
    }

    /// The path observer routinely handles a wake before the wake notification
    /// arrives, and rebuilding that fresh session would tear down a working tunnel
    /// for a second window of direct routing.
    func testWakeKeepsASessionNewerThanTheSleep() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.wake.simulateSleep()
        try await Task.sleep(for: .milliseconds(50))
        fixture.wake.simulateWake()
        await waitUntil { fixture.provider.connectCount == 1 && fixture.model.isConnected }
        fixture.wake.simulateWake()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.provider.disconnectCount, 1)
        XCTAssertEqual(fixture.provider.connectCount, 1)
        XCTAssertTrue(fixture.model.isConnected)
    }

    func testUplinkLossTearsTheSessionDownAndItsReturnReconnects() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.uplink.value = nil
        fixture.path.simulateSettledChange()
        await waitUntil { fixture.provider.disconnectCount == 1 && !fixture.model.isOperationPending }
        XCTAssertFalse(fixture.model.isConnected)
        XCTAssertEqual(fixture.provider.connectCount, 0)
        fixture.uplink.value = SystemUplinkInventory.Uplink(interfaceName: "en1", routerAddress: "192.168.2.1")
        fixture.path.simulateChange()
        await waitUntil { fixture.provider.connectCount == 1 && fixture.model.isConnected }
        XCTAssertEqual(fixture.provider.disconnectCount, 1)
    }

    /// A user who disconnected on purpose is asking to be off the tunnel; the
    /// uplink coming back must not put them back on it.
    func testUplinkReturnAfterAUserDisconnectDoesNotReconnect() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.uplink.value = nil
        fixture.path.simulateSettledChange()
        await waitUntil { fixture.provider.disconnectCount == 1 && !fixture.model.isOperationPending }
        fixture.model.disconnect()
        await waitUntil { fixture.provider.disconnectCount == 2 && !fixture.model.isOperationPending }
        fixture.uplink.value = SystemUplinkInventory.Uplink(interfaceName: "en1", routerAddress: "192.168.2.1")
        fixture.path.simulateChange()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertFalse(fixture.model.isConnected)
    }

    /// The wake and uplink halves of a rebuild ordered on a settled path change:
    /// the tunnel comes down once and goes back up on the new network.
    func testUplinkChangeRebuildsTheSessionOverTheNewNetwork() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.uplink.value = SystemUplinkInventory.Uplink(interfaceName: "en1", routerAddress: "192.168.2.1")
        fixture.path.simulateSettledChange()
        await waitUntil {
            fixture.provider.disconnectCount == 1
                && fixture.provider.connectCount == 1
                && fixture.model.isConnected
        }
    }

    /// A wake rebuild can finish its teardown with the uplink still gone: the
    /// reconnect waits for one instead of connecting into nothing.
    func testWakeRebuildWithoutAnUplinkWaitsForOneToReturn() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.wake.simulateSleep()
        try await Task.sleep(for: .milliseconds(50))
        fixture.uplink.value = nil
        fixture.wake.simulateWake()
        await waitUntil { fixture.provider.disconnectCount == 1 && !fixture.model.isOperationPending }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertFalse(fixture.model.isConnected)
        fixture.uplink.value = SystemUplinkInventory.Uplink(interfaceName: "en1", routerAddress: "192.168.2.1")
        fixture.path.simulateChange()
        await waitUntil { fixture.provider.connectCount == 1 && fixture.model.isConnected }
    }

    /// A user action that lands between the teardown half of a rebuild
    /// finishing and the reconnect being ordered owns the machine: its pending
    /// operation stops the reconnect, the way the other reconnect paths are
    /// stopped.
    func testUserDisconnectInTheRebuildWindowIsNotReconnectedOver() async throws {
        let fixture = try await makeFixture()
        defer { fixture.provider.releaseAllDisconnects() }
        defer { fixture.cleanUp() }
        fixture.provider.holdDisconnects()
        fixture.uplink.value = SystemUplinkInventory.Uplink(interfaceName: "en1", routerAddress: "192.168.2.1")
        fixture.path.simulateSettledChange()
        await waitUntil { fixture.provider.disconnectCount == 1 }
        fixture.model.disconnect()
        await waitUntil { fixture.provider.disconnectCount == 2 }
        // The rebuild's teardown finishes while the user's is still parked, and
        // the reconnect it would order finds that operation pending.
        fixture.provider.releaseOneDisconnect()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.provider.connectCount, 0)
        fixture.provider.releaseOneDisconnect()
        await waitUntil { !fixture.model.isOperationPending }
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertFalse(fixture.model.isConnected)
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        await waitUntil { fixture.model.isConnected }
        return fixture
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the session lifecycle")
    }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = WakeUplinkTestProvider()
    let wake = FakeWakeObserver()
    let path = FakePathObserver()
    let uplink = UplinkBox(SystemUplinkInventory.Uplink(interfaceName: "en0", routerAddress: "192.168.1.1"))
    let model: AppViewModel
    let store: ConfigurationStore

    init() throws {
        let manager = WakeUplinkTestFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.wake-uplink-test-\(UUID())",
                                   keychainAccount: "snapshot", log: log)
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test"
        )
        let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), healthCheck: .init(
            state: .reachable, checkedAt: Date(), latencyMilliseconds: 1, latencyKind: .tcpConnect, failureSummary: nil
        ))
        try store.save(AppSnapshot(savedConnections: [connection], selectedConnectionID: connection.id,
                                   proxyEndpoint: .default, connectionMode: .tun, isLeakGuardEnabled: false))
        let provider = self.provider
        let uplink = self.uplink
        model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                             connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                             leakGuard: LeakGuardService(isEnabled: false, log: log),
                             subscriptionClient: SubscriptionClient(), healthProbeService: ConnectionHealthProbeService(),
                             systemProxyService: SystemProxyService(fileManager: manager, log: log),
                             systemObserverFactory: InjectedObservers(wake: wake, path: path),
                             uplinkProvider: { uplink.value },
                             geodataUpdateCoordinator: nil, log: log)
    }

    func cleanUp() {
        model.handleAppTermination {}
        store.deleteStoredDataForTesting()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The uplink the injected lookup reports, swap-able from the test while the
/// model holds the closure that reads it.
private final class UplinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: SystemUplinkInventory.Uplink?
    init(_ value: SystemUplinkInventory.Uplink?) {
        storedValue = value
    }
    var value: SystemUplinkInventory.Uplink? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class WakeUplinkTestFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

/// Hands the model the fake observers, which record the callbacks the model
/// installs so the test can fire them as the machine would.
private struct InjectedObservers: SystemObserverFactoring {
    let wake: FakeWakeObserver
    let path: FakePathObserver

    func makeWakeObserver(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) -> any SystemWakeObserving {
        wake.setCallbacks(onSleep: onSleep, onWake: onWake)
        return wake
    }

    func makePathObserver(onChange: @escaping @Sendable () -> Void, onSettledChange: @escaping @Sendable () -> Void) -> any NetworkPathObserving {
        path.setCallbacks(onChange: onChange, onSettledChange: onSettledChange)
        return path
    }
}

private final class FakeWakeObserver: SystemWakeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?

    func setCallbacks(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onSleep = onSleep
            self.onWake = onWake
        }
    }

    func simulateSleep() { lock.withLock { onSleep }?() }
    func simulateWake() { lock.withLock { onWake }?() }
    func start() {}
    func stop() {}
}

private final class FakePathObserver: NetworkPathObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?
    private var onSettledChange: (@Sendable () -> Void)?

    func setCallbacks(onChange: @escaping @Sendable () -> Void, onSettledChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onChange = onChange
            self.onSettledChange = onSettledChange
        }
    }

    func simulateChange() { lock.withLock { onChange }?() }
    func simulateSettledChange() { lock.withLock { onSettledChange }?() }
    func start() {}
    func stop() {}
}

/// Parks provider disconnects so a test can interleave a user action into the
/// middle of a teardown. Waiters are released one at a time, in arrival order;
/// while open the gate lets every disconnect through.
private final class DisconnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() {
        lock.withLock { held = true }
    }

    func releaseOne() {
        let next: CheckedContinuation<Void, Never>?
        lock.lock()
        next = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        next?.resume()
    }

    func releaseAll() {
        let all: [CheckedContinuation<Void, Never>]
        lock.lock()
        held = false
        all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let resumeNow: Bool
            lock.lock()
            resumeNow = !held && waiters.isEmpty
            if !resumeNow {
                waiters.append(cont)
            }
            lock.unlock()
            if resumeNow {
                cont.resume()
            }
        }
    }
}

/// Unlike the geodata fake, this one never finishes its state stream: the wake
/// and uplink paths tear a session down in order to build the next one on the
/// same provider, and the states of that rebuild have to keep arriving.
private final class WakeUplinkTestProvider: ConnectionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var connects = 0
    private var disconnects = 0
    private let state = ConnectionState.connected(.init(id: UUID(), mode: .tun, connectedAt: Date()))
    private let updates = AsyncStream<ConnectionState>.makeStream()
    private let disconnectGate = DisconnectGate()
    var connectCount: Int { lock.withLock { connects } }
    var disconnectCount: Int { lock.withLock { disconnects } }

    func holdDisconnects() { disconnectGate.hold() }
    func releaseOneDisconnect() { disconnectGate.releaseOne() }
    func releaseAllDisconnects() { disconnectGate.releaseAll() }

    func currentState() async -> ConnectionState { state }
    func stateUpdates() -> AsyncStream<ConnectionState> { updates.continuation.yield(state); return updates.stream }
    func connect(_ request: ConnectionRequest) async throws {
        lock.withLock { connects += 1 }
        updates.continuation.yield(state)
    }
    func disconnect() async throws {
        lock.withLock { disconnects += 1 }
        await disconnectGate.wait()
        updates.continuation.yield(.idle)
    }
}
