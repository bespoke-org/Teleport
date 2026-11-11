import Foundation
import XCTest

/// The retry half of the session lifecycle, exercised on the coordinator
/// directly: a scripted host records the commands it receives, and the clock
/// is moved by hand, because a five-second retry wait is not something a check
/// can afford on the machine it runs on.
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
            systemProxyService: SystemProxyService(fileManager: FileManager.default, log: log),
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
