import Foundation

/// One connection taking part in a session, paired with the saved-connection id
/// that split-tunnel rules use to name it.
nonisolated struct RoutedConnection: Sendable, Equatable {
    let id: UUID
    let configuration: ConnectionConfiguration
}

/// Immutable inputs required by either connection provider.
nonisolated struct ConnectionRequest: Sendable, Equatable {
    /// The default connection: the outbound that carries everything no rule sends
    /// elsewhere, and the only one System Proxy mode uses.
    let defaultConnection: RoutedConnection
    /// Extra connections the session also dials, each its own outbound.
    let additionalConnections: [RoutedConnection]
    let localProxy: ProxyEndpoint
    let splitTunnelPolicy: SplitTunnelPolicy
    /// Whether this session refuses to start unless traffic can be kept off the
    /// physical uplink. Ignored by System Proxy mode, which pins nothing to an
    /// uplink and so has no window to guard.
    let usesLeakGuard: Bool
    /// Network/wake retries cannot retake settings relinquished after a conflict.
    var isAutomaticReconnect = false

    init(
        defaultConnection: RoutedConnection,
        additionalConnections: [RoutedConnection] = [],
        localProxy: ProxyEndpoint,
        splitTunnelPolicy: SplitTunnelPolicy,
        usesLeakGuard: Bool = true
    ) {
        self.defaultConnection = defaultConnection
        self.additionalConnections = additionalConnections
        self.localProxy = localProxy
        self.splitTunnelPolicy = splitTunnelPolicy
        self.usesLeakGuard = usesLeakGuard
    }

    /// The default connection first: outbound order decides which one keeps the
    /// `proxy` tag that the catch-all rule and the local inbounds point at.
    var connections: [RoutedConnection] {
        [defaultConnection] + additionalConnections
    }

    var configuration: ConnectionConfiguration {
        defaultConnection.configuration
    }
}

/// Provider-neutral split-tunnel configuration for one connection attempt.
nonisolated struct SplitTunnelPolicy: Sendable, Equatable {
    let rules: [SplitTunnelRule]
    let defaultAction: SplitTunnelRuleAction
}
