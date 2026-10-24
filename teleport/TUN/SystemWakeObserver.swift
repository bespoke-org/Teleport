import AppKit
import Foundation

/// Reports that the machine went to sleep and woke again, so a running session
/// can be rebuilt — and so a session built in between can be recognised as one
/// that never lived through the sleep.
///
/// Sleep drops the uplink's address and every TCP connection Xray had open. The
/// uplink usually comes back as the same interface and gateway, so the path
/// observer sees nothing to act on, yet the session has been observed to stop
/// carrying traffic until it is torn down and started again. Until the cause is
/// known, wake is the signal to do that.
nonisolated final class SystemWakeObserver: @unchecked Sendable {
    private let onSleep: @Sendable () -> Void
    private let onWake: @Sendable () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onSleep: @escaping @Sendable () -> Void = {}, onWake: @escaping @Sendable () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [onSleep] _ in
            onSleep()
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [onWake] _ in
            onWake()
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}
