import Foundation
import Network

/// Reports that the machine's network path changed, so a running session can be
/// reconciled against the uplink it was built on.
///
/// The path is only the trigger: what the caller compares is
/// `SystemUplinkInventory`, because a running TUN is itself an interface and a
/// path that merely gained or lost one says nothing about which uplink is
/// primary. Changes arrive in bursts while an interface settles — a Wi-Fi
/// reassociation emits several within a second — so they are coalesced into one
/// `onSettledChange` after the path has been quiet, rather than tearing a session
/// down once per intermediate state.
///
/// `onChange` fires on every event instead, without waiting. Coalescing exists to
/// protect a *running* session from intermediate states; a caller with nothing
/// running has no session to protect and every reason to hurry, because until it
/// acts the machine is routing directly. Waiting out the quiet period after an
/// address is published costs seconds that a browser does not wait for.
nonisolated final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.x.teleport.network-path", qos: .utility)
    private let quietPeriod: TimeInterval
    private let onChange: @Sendable () -> Void
    private let onSettledChange: @Sendable () -> Void
    private var pendingWorkItem: DispatchWorkItem?
    private var isRunning = false

    init(
        quietPeriod: TimeInterval = 2,
        onChange: @escaping @Sendable () -> Void = {},
        onSettledChange: @escaping @Sendable () -> Void
    ) {
        self.quietPeriod = quietPeriod
        self.onChange = onChange
        self.onSettledChange = onSettledChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.monitor.pathUpdateHandler = { [weak self] _ in
                self?.scheduleCallback()
            }
            self.monitor.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil
            self.monitor.cancel()
        }
    }

    private func scheduleCallback() {
        onChange()
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.onSettledChange()
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: workItem)
    }
}
