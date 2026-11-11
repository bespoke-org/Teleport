import Foundation

/// What the session lifecycle coordinator needs from the model that runs it:
/// the state its decisions read and the actions they order. AppViewModel is the
/// only conformer; the protocol is the seam that keeps this type deciding and
/// leaves teardown, provider calls, and published state with the model.
protocol SessionLifecycleHost: AnyObject {
    var isTerminating: Bool { get }
    var connectionMode: ConnectionMode { get }
    var hasEstablishedConnection: Bool { get }
    var isOperationPending: Bool { get }
    var isLeakGuardEnabled: Bool { get }

    func armLeakGuardStandby()
    func tearDownSession()
    func rebuildSessionForNewUplink()
    func reconnectToSelectedConnection(afterUplinkChange: Bool)
    func connectOnLaunchIfNeeded()
}

/// Watches the machine for sleep, wake, and network path changes and decides
/// what the running session should do about them, ordering the model to carry
/// the decisions out. The lifecycle's state and choices live here; the session
/// actions themselves stay with the model.
final class SessionLifecycleCoordinator {
    /// AppViewModel's log tag, kept identical so the lifecycle's lines stay in
    /// the app's stream.
    private nonisolated static let subsystem = "app"

    /// The model whose session this coordinates, attached once both are built.
    weak var host: (any SessionLifecycleHost)?

    private let systemObserverFactory: any SystemObserverFactoring
    /// The lookup behind every uplink comparison in the session lifecycle,
    /// injectable so tests steer it without a real network.
    private let currentUplink: @Sendable () -> SystemUplinkInventory.Uplink?
    private let systemProxyService: SystemProxyService
    private let log: TeleportLog

    private var networkPathObserver: (any NetworkPathObserving)?
    private var systemWakeObserver: (any SystemWakeObserving)?

    /// When the machine last went to sleep, so a session built after that instant
    /// is known to be newer than the sleep and needs no rebuild.
    private var lastSleepAt: Date?
    /// Set between `willSleep` and `didWake`. A dark wake — Wi-Fi coming back for a
    /// maintenance window — posts neither notification, so the machine can be awake
    /// enough to rebuild a session while this is still true.
    private var isAsleep = false
    /// When the running session was established, compared against `lastSleepAt`.
    /// Left `nil` for a session built while the machine was asleep: such a session
    /// has the rest of the sleep still ahead of it, so the wake has to rebuild it.
    private var sessionEstablishedAt: Date?
    /// The uplink the running session was built on, recorded when it connects.
    private var sessionUplink: SystemUplinkInventory.Uplink?
    /// Set when a session was torn down because the uplink vanished, so the next
    /// uplink to appear reconnects instead of leaving the user disconnected.
    private var awaitsUplinkToReconnect = false

    private var deferredProxyRestoreTask: Task<Void, Never>?
    private var deferredProxyRestoreFailedAt: SuspendingClock.Instant?

    init(
        systemObserverFactory: any SystemObserverFactoring,
        uplinkProvider: @escaping @Sendable () -> SystemUplinkInventory.Uplink?,
        systemProxyService: SystemProxyService,
        log: TeleportLog
    ) {
        self.systemObserverFactory = systemObserverFactory
        self.currentUplink = uplinkProvider
        self.systemProxyService = systemProxyService
        self.log = log
    }

    func start() {
        observeNetworkPath()
        observeSystemWake()
    }

    func stop() {
        networkPathObserver?.stop()
        systemWakeObserver?.stop()
    }

    // MARK: What the model reports to the lifecycle

    /// The helper pins routes to the gateway that is current when its script
    /// runs, which is moments from now; the connected state can arrive seconds
    /// later, by which time a roaming machine may already be on another one.
    func noteSessionRequested() {
        sessionUplink = currentUplink()
    }

    /// A transition to connected, recorded before it is logged. Fills in the
    /// uplink for a session this process did not start, one still up from a
    /// previous run, and drops any pending auto-reconnect, which a connected
    /// session has no use for. Returns the uplink for that log line.
    func noteConnectedTransition() -> SystemUplinkInventory.Uplink? {
        sessionUplink = sessionUplink ?? currentUplink()
        awaitsUplinkToReconnect = false
        return sessionUplink
    }

    /// The connected state arrived. A dark wake brings the uplink back for a
    /// maintenance window, and the path observer rebuilds the session on it. That
    /// session is not newer than the sleep — the sleep has not ended — so it is
    /// recorded as having no establishment time at all, and the wake that follows
    /// rebuilds it.
    func noteSessionEstablished() {
        sessionEstablishedAt = isAsleep ? nil : Date()
    }

    func noteSessionIdle() {
        sessionEstablishedAt = nil
    }

    /// A connect, disconnect, or uninstall the user asked for: nothing should be
    /// reconnected behind their back afterwards.
    func cancelAutoReconnect() {
        awaitsUplinkToReconnect = false
    }

    /// The teardown half of a rebuild has finished: reconnect now if an uplink is
    /// there to build on, or go back to waiting for one instead of reconnecting
    /// into nothing.
    func continueRebuildAfterTeardown() {
        guard currentUplink() != nil else {
            awaitsUplinkToReconnect = true
            return
        }
        host?.reconnectToSelectedConnection(afterUplinkChange: true)
    }

    /// An uplink can have a router address before its resolver answers, and a
    /// reconnect started on it then fails on the lookup of the proxy server. The
    /// path has usually stopped changing by that time, so no further notification
    /// would start another attempt, and the leak guard armed for the reconnect
    /// would keep the machine off the network until the user stepped in.
    func retryReconnectAfterUplinkChange() {
        awaitsUplinkToReconnect = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // A connect or disconnect the user asked for in the meantime cleared
            // the flag, and this does nothing.
            self?.reconnectAsSoonAsAnUplinkAppears()
        }
    }

    // MARK: System events

    /// A tunnel pins its proxy-server routes to the gateway that was current when
    /// it started, and installs both default halves through its TUN. Neither is
    /// revisited afterwards, so an uplink that changes underneath a running session
    /// leaves the machine routing into a tunnel whose own transport can no longer
    /// get out — reachable only by tearing the session down.
    private func observeNetworkPath() {
        let observer = systemObserverFactory.makePathObserver(
            onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reconnectAsSoonAsAnUplinkAppears()
                }
            },
            onSettledChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reconcileSessionWithUplink()
                }
            }
        )
        networkPathObserver = observer
        observer.start()
    }

    /// A routed session does not survive sleep in practice: after wake its Xray
    /// reaches the server but no tunneled stream receives a byte, and only a
    /// rebuild recovers it. The uplink is usually unchanged, so the path observer
    /// would keep it running; wake itself is the trigger. System Proxy mode is
    /// left alone, as nothing pins it to the machine's sleep state.
    private func observeSystemWake() {
        let observer = systemObserverFactory.makeWakeObserver(
            onSleep: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.lastSleepAt = Date()
                    self?.isAsleep = true
                }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isAsleep = false
                    self?.rebuildSessionAfterWake()
                }
            }
        )
        systemWakeObserver = observer
        observer.start()
    }

    private func rebuildSessionAfterWake() {
        guard let host, !host.isTerminating, host.connectionMode == .tun,
              host.hasEstablishedConnection, !host.isOperationPending else { return }
        // A session built after the machine went to sleep did not live through the
        // sleep and does not need rebuilding. The path observer routinely gets
        // there first — a wake onto a different network is a path change, and its
        // notification arrives before this one — and rebuilding again would tear
        // down a working tunnel seconds old, for a second window of direct routing.
        if let lastSleepAt, let sessionEstablishedAt, sessionEstablishedAt > lastSleepAt {
            log.info(Self.subsystem, "machine woke from sleep; session is newer than the sleep, keeping it")
            return
        }
        log.warn(Self.subsystem, "machine woke from sleep; rebuilding the session over \(currentUplink()?.summary ?? "<no uplink>")")
        sessionUplink = nil
        host.rebuildSessionForNewUplink()
    }

    /// The uncoalesced half of the path observer, and the only thing it is used
    /// for: a session that is waiting to be rebuilt is rebuilt the moment there is
    /// an uplink to rebuild it on.
    ///
    /// Nothing is running, so there is no session for an intermediate path state to
    /// damage, and the quiet period would only extend the window in which the
    /// machine routes directly. A router address is still required: an interface
    /// that has come up without one cannot carry a tunnel yet, and the settled
    /// callback will come back to it.
    private func reconnectAsSoonAsAnUplinkAppears() {
        guard let host, !host.isTerminating, awaitsUplinkToReconnect, !host.isOperationPending else { return }
        guard let uplink = currentUplink(), uplink.routerAddress != nil else { return }
        awaitsUplinkToReconnect = false
        log.info(Self.subsystem, "uplink is back (\(uplink.summary)); reconnecting without waiting for the path to settle")
        host.reconnectToSelectedConnection(afterUplinkChange: true)
    }

    private func reconcileSessionWithUplink() {
        guard let host, !host.isTerminating else { return }

        let uplink = currentUplink()

        if awaitsUplinkToReconnect {
            guard uplink != nil else { return }
            awaitsUplinkToReconnect = false
            log.info(Self.subsystem, "uplink is back (\(uplink?.summary ?? "<unknown>")); reconnecting")
            host.reconnectToSelectedConnection(afterUplinkChange: true)
            return
        }

        guard host.hasEstablishedConnection || host.isOperationPending else {
            // Nothing is routing. If an earlier teardown could not put a service's
            // proxy settings back because that service was down, the path change
            // that just fired may be it coming back — the moment to finish the job,
            // rather than waiting for the next launch.
            restoreDeferredProxyStateIfNeeded()
            return
        }

        // System Proxy mode points applications at a local port, which no change of
        // uplink invalidates. Only a routed session pins itself to one.
        guard host.connectionMode == .tun, host.hasEstablishedConnection, !host.isOperationPending else { return }

        switch UplinkChangeDecision.decide(sessionUplink: sessionUplink, currentUplink: uplink) {
        case .keepRunning:
            return
        case .tearDownAndWaitForUplink:
            log.warn(Self.subsystem, "uplink \(sessionUplink?.summary ?? "<unknown>") is gone; tearing down the session, guard \(host.isLeakGuardEnabled ? "armed" : "off")")
            sessionUplink = nil
            // Armed before the teardown, and kept across it: this is the longest
            // window of the two — it lasts until an uplink comes back, which on a
            // commute is the commute.
            host.armLeakGuardStandby()
            host.tearDownSession()
            // After, not before: the teardown clears the flag so that a user who
            // disconnects on purpose is never reconnected behind their back.
            awaitsUplinkToReconnect = true
        case .reconnect:
            log.warn(Self.subsystem, "uplink changed from \(sessionUplink?.summary ?? "<unknown>") to \(uplink?.summary ?? "<unknown>"); rebuilding the session")
            sessionUplink = nil
            host.rebuildSessionForNewUplink()
        }
    }

    /// A teardown that ran while an interface was down could not put that service's
    /// proxy settings back, and kept its entry instead of discarding it. Launching
    /// with no session running is the moment to finish that.
    /// One restore at a time, and after a failure none for a while. Path changes
    /// arrive in bursts, and each restore that times out takes 5 s per networksetup
    /// call; the log once held 60 such failures in 50 minutes, with two restores
    /// overlapping and each deleting a snapshot the other had already read.
    private static let deferredProxyRestoreRetryInterval: Duration = .seconds(30)

    func restoreDeferredProxyStateIfNeeded() {
        guard deferredProxyRestoreTask == nil else { return }
        if let failedAt = deferredProxyRestoreFailedAt,
           SuspendingClock().now - failedAt < Self.deferredProxyRestoreRetryInterval {
            return
        }
        let service = systemProxyService
        let log = log
        deferredProxyRestoreTask = Task { @MainActor [weak self] in
            let failed = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try service.restoreDeferredProxyStateIfNeeded()
                    return false
                } catch {
                    log.error(Self.subsystem, "could not restore deferred proxy state: \(LogFormat.error(error))")
                    return true
                }
            }.value
            self?.deferredProxyRestoreFailedAt = failed ? SuspendingClock().now : nil
            self?.deferredProxyRestoreTask = nil
            self?.host?.connectOnLaunchIfNeeded()
        }
    }

    /// Whether a deferred proxy restore is running, which a launch connect waits
    /// out rather than racing.
    var isRestoringDeferredProxyState: Bool {
        deferredProxyRestoreTask != nil
    }

    /// Whether a restore failed recently enough that its retry interval has not
    /// passed.
    var hasRecentDeferredProxyRestoreFailure: Bool {
        deferredProxyRestoreFailedAt != nil
    }
}
