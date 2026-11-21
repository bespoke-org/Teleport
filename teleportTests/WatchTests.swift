import Foundation
import XCTest

final class WatchTests: XCTestCase {
    func testUpdatesBeforeWaitingReturnTheLatestValue() async throws {
        let value = Watch(false)
        let initial = value.snapshot()
        value.update { $0 = true }
        value.update { $0 = false }
        value.update { $0 = true }
        let latest = try await value.changed(after: initial.revision)
        XCTAssertTrue(latest.value)
        XCTAssertEqual(latest.revision, 3)
    }

    func testEveryObserverCanSeeTheSameUpdate() async throws {
        let value = Watch(0)
        let revision = value.snapshot().revision
        async let first = value.changed(after: revision)
        async let second = value.changed(after: revision)
        try await waitForWaiters(2, in: value)
        value.update { $0 = 42 }
        let snapshots = try await [first, second]
        XCTAssertEqual(snapshots.map(\.value), [42, 42])
    }

    func testCancellingAWaitDoesNotConsumeTheNextUpdate() async throws {
        let value = Watch(0)
        let revision = value.snapshot().revision
        let waiter = Task { try await value.changed(after: revision) }
        try await waitForWaiters(1, in: value)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("A cancelled wait must throw")
        } catch is CancellationError {}
        XCTAssertEqual(value.registeredWaiterCount, 0)
        value.update { $0 = 1 }
        let latest = try await value.changed(after: revision)
        XCTAssertEqual(latest.value, 1)
    }
    func testCancellationRacingAnUpdateResumesTheWaiterExactlyOnce() async throws {
        for _ in 0..<50 {
            let value = Watch(0)
            let waiter = Task { try await value.changed(after: 0) }
            try await waitForWaiters(1, in: value)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { waiter.cancel() }
                group.addTask { value.update { $0 = 1 } }
            }
            do { _ = try await waiter.value } catch is CancellationError {}
            XCTAssertEqual(value.registeredWaiterCount, 0)
            XCTAssertEqual(value.snapshot().value, 1)
        }
    }

    private func waitForWaiters<T>(_ count: Int, in watch: Watch<T>) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while watch.registeredWaiterCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waiters did not register")
                throw CancellationError()
            }
            await Task.yield()
        }
    }

}
