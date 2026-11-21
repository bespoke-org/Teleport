import Foundation

/// Process-local owner of ALL TUN session mutations. The dispatcher still owns
/// wire admission/ledger/correlation; a supervisor cancellation is not revocation.
/// `@unchecked Sendable`: effects/context use queue, snapshots use lock.
final class HelperTUNSessionExecutor: @unchecked Sendable {
    struct RunToken: Equatable, Sendable {
        let sessionID: UUID
        let generation: UUID
    }

    enum Phase: Equatable, Sendable { case idle, starting, running, stopping, cleanupFailed }

    struct Snapshot: Equatable, Sendable {
        let phase: Phase
        let token: RunToken?
        let pid: Int32?
        let tunnelInterfaceName: String?
        let outboundInterface: String?
    }

    struct Cleanup: Sendable {
        let tunnelInterfaceName: String?
        let outboundInterface: String?
        let perform: @Sendable () throws -> Void
    }

    private struct Run {
        let token: RunToken
        let cleanup: Cleanup
        var pid: Int32?
    }
    private let queue = DispatchQueue(label: "dev.x.teleport.helper.tun-session")
    private let lock = NSLock()
    // Nil only before the first operation: allow the existing restart fallback.
    private var published: Snapshot?
    private var run: Run? // queue only

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// The operation installs a watch whose callback only enqueues an exit.
    /// The cleanup closure must capture effects/resources, NOT this executor.
    func start(sessionID: UUID, cleanup: Cleanup, prepare: () throws -> Void = {},
               operation: (RunToken) throws -> Int32?) throws {
        try queue.sync {
            if run != nil { try teardown() }
            let token = RunToken(sessionID: sessionID, generation: UUID())
            let priorSnapshot = snapshot
            run = Run(token: token, cleanup: cleanup)
            publish(.starting)
            do {
                try prepare()
            } catch {
                // The route script has not run. The client's follow-up stop must
                // also leave the network alone.
                run = nil
                lock.withLock { published = priorSnapshot }
                throw error
            }
            do {
                let pid = try operation(token)
                run?.pid = pid
                publish(.running)
            } catch {
                // Preserve the original start failure; cleanup failure is also
                // visible in the snapshot and remains retryable with stop.
                try? teardown()
                throw error
            }
        }
    }

    /// No current run after restart: adopt only the existing cleanup inputs, not
    /// a fabricated durable generation. Repeated successful stop is a no-op.
    func stop(sessionID: UUID, fallback: @autoclosure () throws -> Cleanup?) throws {
        try queue.sync {
            if run == nil, snapshot == nil, let cleanup = try fallback() {
                run = Run(token: RunToken(sessionID: sessionID, generation: UUID()), cleanup: cleanup)
            }
            if run != nil { try teardown() }
        }
    }

    /// The supervisor delivers at most one callback per watch. Recheck ownership
    /// after entering the queue because a replacement may have completed meanwhile.
    func unexpectedExit(token: RunToken, pid: Int32) {
        queue.async { [weak self] in
            guard let self, let run, run.token == token, run.pid == pid,
                  snapshot?.phase == .running else { return }
            try? teardown()
        }
    }

    private func teardown() throws {
        guard let current = run else { return }
        publish(.stopping)
        do {
            try current.cleanup.perform()
            run = nil
            publish(.idle)
        } catch {
            publish(.cleanupFailed)
            throw error
        }
    }

    private func publish(_ phase: Phase) {
        let value = Snapshot(phase: phase, token: run?.token, pid: run?.pid,
                             tunnelInterfaceName: run?.cleanup.tunnelInterfaceName,
                             outboundInterface: run?.cleanup.outboundInterface)
        lock.lock()
        published = value
        lock.unlock()
    }

    /// Deterministic barrier for isolated tests, never used by status or IPC.
    func waitForPendingEvents() { queue.sync {} }
}
