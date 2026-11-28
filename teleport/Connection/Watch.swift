import Foundation

/// A current value with change notification, not a queue of commands. Reading a
/// revision and registering a wait for its successor share the same lock, so an
/// update between the read and the wait cannot be lost.
nonisolated final class Watch<Value: Sendable>: @unchecked Sendable {
    struct Snapshot: Sendable {
        let value: Value
        let revision: UInt64
    }

    private let lock = NSLock()
    private var value: Value
    private var revision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(_ value: Value) { self.value = value }

    #if DEBUG
    /// Lets concurrency tests establish that a waiter is suspended before they
    /// race cancellation with an update. Not exposed in release builds.
    var registeredWaiterCount: Int { lock.withLock { waiters.count } }
    #endif

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(value: value, revision: revision) }
    }

    @discardableResult
    func update(_ change: (inout Value) -> Void) -> Snapshot {
        let (snapshot, resumed) = lock.withLock {
            change(&value)
            revision += 1
            let snapshot = Snapshot(value: value, revision: revision)
            let resumed = Array(waiters.values)
            waiters.removeAll()
            return (snapshot, resumed)
        }
        resumed.forEach { $0.resume() }
        return snapshot
    }

    func changed(after observedRevision: UInt64) async throws -> Snapshot {
        guard let change = await nextChange(after: observedRevision) else { throw CancellationError() }
        return change
    }

    func nextChange(after observedRevision: UInt64) async -> Snapshot? {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled || revision != observedRevision {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
        return Task.isCancelled ? nil : snapshot()
    }
}
