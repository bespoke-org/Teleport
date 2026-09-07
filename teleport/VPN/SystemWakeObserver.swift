import AppKit
import Foundation

/// Reports that the machine woke from sleep, so a running session can be
/// rebuilt.
///
/// Sleep drops the uplink's address and every TCP connection Xray had open. The
/// uplink usually comes back as the same interface and gateway, so the path
/// observer sees nothing to act on, yet the session has been observed to stop
/// carrying traffic until it is torn down and started again. Until the cause is
/// known, wake is the signal to do that.
nonisolated final class SystemWakeObserver: @unchecked Sendable {
    private let onWake: @Sendable () -> Void
    private var token: NSObjectProtocol?

    init(onWake: @escaping @Sendable () -> Void) {
        self.onWake = onWake
    }

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [onWake] _ in
            onWake()
        }
    }

    func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        token = nil
    }
}
