import Foundation

nonisolated protocol LifecycleClock: Sendable {
    var now: SuspendingClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

nonisolated struct SuspendingLifecycleClock: LifecycleClock {
    var now: SuspendingClock.Instant { SuspendingClock().now }
    func sleep(for duration: Duration) async throws {
        try await SuspendingClock().sleep(for: duration)
    }
}

nonisolated protocol DeferredProxyRestoring: Sendable {
    func restoreDeferredProxyStateIfNeeded() throws
}

/// Called only by the connection executor after the provider has resolved to
/// idle. Concurrent callers share the same result; failures back off for 30 s.
actor DeferredProxyRestorer {
    private let service: any DeferredProxyRestoring
    private let clock: any LifecycleClock
    private let log: TeleportLog
    private var running: Task<Bool, Never>?
    private var failedAt: SuspendingClock.Instant?

    init(service: any DeferredProxyRestoring, clock: any LifecycleClock = SuspendingLifecycleClock(),
         log: TeleportLog = .shared) {
        self.service = service
        self.clock = clock
        self.log = log
    }

    func restore() async -> Bool {
        if let running { return await running.value }
        if let failedAt, clock.now - failedAt < .seconds(30) { return false }
        let service = self.service
        let log = self.log
        let task = Task.detached(priority: .utility) {
            do {
                try service.restoreDeferredProxyStateIfNeeded()
                return true
            } catch {
                log.error("app", "could not restore deferred proxy state: \(LogFormat.error(error))")
                return false
            }
        }
        running = task
        let succeeded = await task.value
        failedAt = succeeded ? nil : clock.now
        running = nil
        return succeeded
    }
}

nonisolated protocol ConnectionGuarding: Sendable {
    func armStandby() async
    func disarm() async
}

extension LeakGuardService: ConnectionGuarding {}
