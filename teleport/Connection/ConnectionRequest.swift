import Foundation

/// Immutable inputs required by either connection provider.
struct ConnectionRequest: Sendable, Equatable {
    let configuration: ConnectionConfiguration
    let localProxy: ProxyEndpoint
    let splitTunnelPolicy: SplitTunnelPolicy
}

/// Provider-neutral split-tunnel configuration for one connection attempt.
struct SplitTunnelPolicy: Sendable, Equatable {
    let rules: [SplitTunnelRule]
    let defaultAction: SplitTunnelRuleAction
}
