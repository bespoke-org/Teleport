import Foundation
import XCTest

/// The retry and deferred-restore halves of the session lifecycle, exercised
/// on the coordinator directly: a scripted host records the commands it
/// receives, the clock is moved by hand, and the restore service is a gate the
/// test opens, because neither a five-second retry wait nor a hung
/// networksetup call is something a check can afford on the machine it runs on.
@MainActor
final class SessionLifecycleCoordinatorTests: XCTestCase {
    /// A reconnect that failed on the uplink's resolver comes back after the
    /// retry delay, not before it.
    func testAFailedReconnectRetriesOnceTheDelayHasPassed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.attach()
        await fixture.coordinator.retryReconnectAfterUplinkChange()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.host.commands, [])
        fixture.clock.advance(by: .seconds(5))
        await waitUntil { fixture.host.commands == ["reconnectToSelectedConnection(true)"] }
    }

    /// A connect or disconnect the user asked for while the retry was waiting
    /// clears it: nothing reconnects behind their back.
    func testAUserActionCancelsAPendingRetry() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.attach()
        await fixture.coordinator.retryReconnectAfterUplinkChange()
        fixture.coordinator.cancelAutoReconnect()
        try await Task.sleep(for: .milliseconds(100))
        fixture.clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.host.commands, [])
    }

    /// A deferred proxy restore that is still running holds the launch
    /// connect: the host hears about it only once the restore has finished.
    func testARunningRestoreHoldsTheLaunchConnectUntilItFinishes() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.attach()
        await fixture.coordinator.restoreDeferredProxyStateIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.host.commands, [])
        let isRestoring = await fixture.coordinator.isRestoringDeferredProxyState
        XCTAssertTrue(isRestoring)
        fixture.restoreService.finish()
        await waitUntil { fixture.host.commands == ["connectOnLaunchIfNeeded"] }
        let stillRestoring = await fixture.coordinator.isRestoringDeferredProxyState
        XCTAssertFalse(stillRestoring)
    }

    /// A failed restore backs off: another attempt inside the retry interval
    /// is refused, and one after it runs.
    func testAFailedRestoreBacksOffForTheRetryInterval() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.attach()
        await fixture.coordinator.restoreDeferredProxyStateIfNeeded()
        await waitUntil { fixture.restoreService.attemptCount == 1 }
        fixture.restoreService.fail(URLError(.cannotConnectToHost))
        await waitUntil { fixture.host.commands == ["connectOnLaunchIfNeeded"] }
        let hasRecentFailure = await fixture.coordinator.hasRecentDeferredProxyRestoreFailure
        XCTAssertTrue(hasRecentFailure)

        await fixture.coordinator.restoreDeferredProxyStateIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.restoreService.attemptCount, 1)

        fixture.clock.advance(by: .seconds(31))
        await fixture.coordinator.restoreDeferredProxyStateIfNeeded()
        await waitUntil { fixture.restoreService.attemptCount == 2 }
        fixture.restoreService.finish()
        await waitUntil { fixture.host.commands.count == 2 }
        let failureCleared = await fixture.coordinator.hasRecentDeferredProxyRestoreFailure
        XCTAssertFalse(failureCleared)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
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
    let host: ScriptedHost
    let clock = ControlledClock()
    let restoreService = ControlledRestoreService()
    let coordinator: SessionLifecycleCoordinator

    init(
        hostState: SessionLifecycleHostState = .init(
            isTerminating: false, connectionMode: .tun,
            hasEstablishedConnection: true, isOperationPending: false, isLeakGuardEnabled: false
        ),
        uplink: SystemUplinkInventory.Uplink? = .init(interfaceName: "en0", routerAddress: "192.168.1.1")
    ) {
        host = ScriptedHost(state: hostState)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        coordinator = SessionLifecycleCoordinator(
            systemObserverFactory: UnusedObservers(),
            uplinkProvider: { uplink },
            systemProxyService: restoreService,
            log: log,
            clock: clock
        )
    }

    func attach() async {
        await coordinator.attach(host: host)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The host side of the coordinator's seam, scripted: snapshots come back from
/// a stored state, and every command is recorded for the test to read.
@MainActor
private final class ScriptedHost: SessionLifecycleHost {
    private var storedState: SessionLifecycleHostState
    private(set) var commands: [String] = []

    init(state: SessionLifecycleHostState) {
        storedState = state
    }

    func setState(_ state: SessionLifecycleHostState) {
        storedState = state
    }

    func sessionLifecycleState() -> SessionLifecycleHostState {
        storedState
    }

    func armLeakGuardStandby() { commands.append("armLeakGuardStandby") }
    func tearDownSession() { commands.append("tearDownSession") }
    func rebuildSessionForNewUplink() { commands.append("rebuildSessionForNewUplink") }

    func reconnectToSelectedConnection(afterUplinkChange: Bool) {
        commands.append("reconnectToSelectedConnection(\(afterUplinkChange))")
    }

    func connectOnLaunchIfNeeded() { commands.append("connectOnLaunchIfNeeded") }
}

/// The coordinator under test never starts its observers, so the factory only
/// has to typecheck.
private struct UnusedObservers: SystemObserverFactoring {
    func makeWakeObserver(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) -> any SystemWakeObserving {
        IdleWakeObserver()
    }

    func makePathObserver(onChange: @escaping @Sendable () -> Void, onSettledChange: @escaping @Sendable () -> Void) -> any NetworkPathObserving {
        IdlePathObserver()
    }
}

private final class IdleWakeObserver: SystemWakeObserving {
    func start() {}
    func stop() {}
}

private final class IdlePathObserver: NetworkPathObserving {
    func start() {}
    func stop() {}
}

/// A clock whose time the test advances by hand: a sleep suspends until the
/// clock is moved past its deadline, so a five-second retry is one advance
/// call instead of a five-second wait. Cancellation is not modelled; nothing
/// in the coordinator cancels these sleeps.
private final class ControlledClock: LifecycleClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: SuspendingClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: SuspendingClock.Instant
    private var sleepers: [Sleeper] = []

    init(startingAt start: SuspendingClock.Instant = SuspendingClock().now) {
        current = start
    }

    var now: SuspendingClock.Instant {
        lock.withLock { current }
    }

    func advance(by duration: Duration) {
        let resumed: [CheckedContinuation<Void, Error>]
        lock.lock()
        current += duration
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        resumed = due.map(\.continuation)
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { cont in
            let deadline: SuspendingClock.Instant
            let resumeImmediately: Bool
            lock.lock()
            deadline = current + duration
            resumeImmediately = deadline <= current
            if !resumeImmediately {
                sleepers.append(Sleeper(deadline: deadline, continuation: cont))
            }
            lock.unlock()
            if resumeImmediately {
                cont.resume()
            }
        }
    }
}

/// The restore service half of the seam, gated: the call parks the detached
/// thread it arrives on until the test opens the gate, the way a stuck
/// networksetup call would, and every attempt is counted for the test to read.
private final class ControlledRestoreService: DeferredProxyRestoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var attempts = 0
    private var pendingError: Error?

    var attemptCount: Int { lock.withLock { attempts } }

    func finish() {
        lock.withLock { pendingError = nil }
        gate.signal()
    }

    func fail(_ error: Error) {
        lock.withLock { pendingError = error }
        gate.signal()
    }

    func restoreDeferredProxyStateIfNeeded() throws {
        lock.withLock { attempts += 1 }
        gate.wait()
        let error = lock.withLock { pendingError }
        if let error { throw error }
    }
}
