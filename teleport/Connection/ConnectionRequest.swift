import Foundation

/// One connection taking part in a session, paired with the saved-connection id
/// that split-tunnel rules use to name it.
struct RoutedConnection: Sendable, Equatable {
    let id: UUID
    let configuration: ConnectionConfiguration
}

/// Immutable inputs required by either connection provider.
struct ConnectionRequest: Sendable, Equatable {
    /// The default connection: the outbound that carries everything no rule sends
    /// elsewhere, and the only one System Proxy mode uses.
    let defaultConnection: RoutedConnection
    /// Extra connections the session also dials, each its own outbound.
    let additionalConnections: [RoutedConnection]
    let localProxy: ProxyEndpoint
    let splitTunnelPolicy: SplitTunnelPolicy

    init(
        defaultConnection: RoutedConnection,
        additionalConnections: [RoutedConnection] = [],
        localProxy: ProxyEndpoint,
        splitTunnelPolicy: SplitTunnelPolicy
    ) {
        self.defaultConnection = defaultConnection
        self.additionalConnections = additionalConnections
        self.localProxy = localProxy
        self.splitTunnelPolicy = splitTunnelPolicy
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
struct SplitTunnelPolicy: Sendable, Equatable {
    let rules: [SplitTunnelRule]
    let defaultAction: SplitTunnelRuleAction
}
