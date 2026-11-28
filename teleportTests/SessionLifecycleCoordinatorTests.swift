import Foundation
import XCTest

@MainActor
final class SessionLifecycleCoordinatorTests: XCTestCase {
    func testRestoreWaitsForTheSystemOperationToFinish() async throws {
        let service = ControlledRestoreService()
        let restorer = DeferredProxyRestorer(service: service)
        let finished = Watch(false)
        let first = Task {
            let result = await restorer.restore()
            finished.update { $0 = true }
            return result
        }
        await waitUntil { service.attemptCount == 1 }
        XCTAssertFalse(finished.snapshot().value)
        service.finish()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(service.attemptCount, 1)
    }

    func testAFailedRestoreBacksOffForTheRetryInterval() async throws {
        let service = ControlledRestoreService()
        let clock = ControlledClock()
        let restorer = DeferredProxyRestorer(service: service, clock: clock)
        let first = Task { await restorer.restore() }
        await waitUntil { service.attemptCount == 1 }
        service.fail(URLError(.cannotConnectToHost))
        let result = await first.value
        XCTAssertFalse(result)
        let backedOff = await restorer.restore()
        XCTAssertFalse(backedOff)
        XCTAssertEqual(service.attemptCount, 1)
        clock.advance(by: .seconds(31))
        let retry = Task { await restorer.restore() }
        await waitUntil { service.attemptCount == 2 }
        service.finish()
        let retried = await retry.value
        XCTAssertTrue(retried)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for proxy restoration")
    }
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
