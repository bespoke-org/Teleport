import Foundation

/// Builds the system observers the session lifecycle listens to. The app runs
/// the real factory below; tests replace it to fire sleep, wake, and path
/// events deterministically instead of waiting for the machine to produce them.
nonisolated protocol SystemObserverFactoring: Sendable {
    func makeWakeObserver(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) -> any SystemWakeObserving
    func makePathObserver(onChange: @escaping @Sendable () -> Void, onSettledChange: @escaping @Sendable () -> Void) -> any NetworkPathObserving
}

/// The real observers: NSWorkspace notifications for sleep and wake, an
/// NWPathMonitor for path changes.
nonisolated struct SystemObserverFactory: SystemObserverFactoring {
    func makeWakeObserver(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) -> any SystemWakeObserving {
        SystemWakeObserver(onSleep: onSleep, onWake: onWake)
    }

    func makePathObserver(onChange: @escaping @Sendable () -> Void, onSettledChange: @escaping @Sendable () -> Void) -> any NetworkPathObserving {
        NetworkPathObserver(onChange: onChange, onSettledChange: onSettledChange)
    }
}
