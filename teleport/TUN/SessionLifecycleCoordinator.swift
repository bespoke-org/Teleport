import Foundation

/// Translates system observations into executor inputs. It owns no connection
/// operations and never calls the presentation layer.
actor SessionLifecycleCoordinator {
    private let runtime: ConnectionIntentRuntime
    private let systemObserverFactory: any SystemObserverFactoring
    private let currentUplink: @Sendable () -> SystemUplinkInventory.Uplink?
    private var networkPathObserver: (any NetworkPathObserving)?
    private var systemWakeObserver: (any SystemWakeObserving)?

    init(systemObserverFactory: any SystemObserverFactoring,
         uplinkProvider: @escaping @Sendable () -> SystemUplinkInventory.Uplink?,
         runtime: ConnectionIntentRuntime) {
        self.systemObserverFactory = systemObserverFactory
        self.currentUplink = uplinkProvider
        self.runtime = runtime
    }

    func start() {
        guard networkPathObserver == nil, systemWakeObserver == nil else { return }
        let runtime = self.runtime
        let currentUplink = self.currentUplink
        runtime.networkChanged(currentUplink(), settled: true)
        let path = systemObserverFactory.makePathObserver(
            onChange: { runtime.networkChanged(currentUplink(), settled: false) },
            onSettledChange: { runtime.networkChanged(currentUplink(), settled: true) }
        )
        networkPathObserver = path
        path.start()
        let wake = systemObserverFactory.makeWakeObserver(
            onSleep: { runtime.slept() },
            onWake: {
                runtime.networkChanged(currentUplink(), settled: true)
                runtime.woke()
            }
        )
        systemWakeObserver = wake
        wake.start()
    }

    nonisolated func stop() { Task { await stopObservers() } }

    private func stopObservers() {
        networkPathObserver?.stop()
        systemWakeObserver?.stop()
        networkPathObserver = nil
        systemWakeObserver = nil
    }

}
