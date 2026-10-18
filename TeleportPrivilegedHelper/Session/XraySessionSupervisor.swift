import Darwin
import Foundation

/// Watches the Xray process a session started and runs a teardown if it exits
/// before a stop was asked for.
///
/// The start script returns once the tunnel is up and nothing looked at Xray
/// again. A crash left both default halves routed into a TUN that no longer
/// existed, and stayed that way until an explicit stop or start arrived — from a
/// user who by then had no network to notice it with. The helper is the only
/// process that can remove those routes, so the helper watches.
///
/// `@unchecked Sendable`: every access to the watched state goes through `lock`.
final class XraySessionSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.x.teleport.helper.supervisor", qos: .utility)
    private var source: DispatchSourceProcess?
    private var watchedPID: pid_t?
    /// Set the moment a stop is requested, before the stop script runs, so an
    /// exit event that races with it does not start a second teardown.
    private var isStopRequested = false

    /// Starts watching `pid`. `onUnexpectedExit` runs on a private queue if the
    /// process exits while a stop was not requested; it is given the pid so it can
    /// confirm the session file still names it.
    func watch(pid: pid_t, onUnexpectedExit: @escaping @Sendable (pid_t) -> Void) {
        cancel()

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.consumeWatch(of: pid) else { return }
            onUnexpectedExit(pid)
        }

        lock.lock()
        self.source = source
        watchedPID = pid
        isStopRequested = false
        lock.unlock()

        source.resume()

        // A process that exited between the pid being read and the source being
        // armed produces no event. `kill(pid, 0)` on a reaped pid fails with ESRCH;
        // on a zombie it succeeds, but the exit event for a zombie is still
        // delivered, so only the reaped case needs catching here.
        if kill(pid, 0) != 0, errno == ESRCH {
            queue.async { [weak self] in
                guard let self, self.consumeWatch(of: pid) else { return }
                onUnexpectedExit(pid)
            }
        }
    }

    /// One teardown per watched process. The exit source and the already-reaped
    /// fallback can both report the same pid; whichever arrives first takes the
    /// watch, and the other finds nothing to act on.
    private func consumeWatch(of pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard watchedPID == pid, !isStopRequested else { return false }
        watchedPID = nil
        return true
    }

    /// The pid still under watch, which is a process whose exit event has not
    /// arrived. Nil once it exited, a stop was requested, or nothing was started.
    var watchedProcessID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return watchedPID
    }

    /// Stops watching. Called before a requested stop runs its script, so the exit
    /// that script causes is not mistaken for a crash.
    func cancel() {
        lock.lock()
        isStopRequested = true
        let source = self.source
        self.source = nil
        watchedPID = nil
        lock.unlock()
        source?.cancel()
    }
}
