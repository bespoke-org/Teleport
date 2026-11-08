import Foundation

nonisolated struct LeakGuardEndpoint: Codable, Equatable, Sendable {
    var address: String
    var transport: String
    /// Numeric ports or inclusive ranges, already checked at the helper boundary.
    var ports: String
}

nonisolated struct LeakGuardPolicy: Codable, Equatable, Sendable {
    var endpoints: [LeakGuardEndpoint] = []
    var allowsDirect = false
    var allowsLAN = false
}

/// Stateless passes avoid leaving an exception alive in PF's state table after
/// the policy is narrowed. Existing states are flushed once when protection is
/// first acquired, before any tunnel routes change.
nonisolated enum LeakGuardRuleset: Sendable {
    static let anchorName = "com.apple/dev.x.teleport"
    static let bootstrapAddress = "1.1.1.1"
    enum Stage: Equatable, Sendable {
        case standby
        case session(tunnelInterface: String)
    }

    static func rules(stage: Stage, protectedHosts: [String] = [], policy: LeakGuardPolicy = .init(), runtimeGroupID: UInt32 = 499) -> String {
        var lines = [
            "# Teleport protection remains until explicitly released.",
            "pass quick on lo0 all flags any no state",
            // Incoming packets must not create states that bypass outbound rules.
            "pass in quick all flags any no state",
            "pass out quick inet proto udp from any port 68 to any port 67 no state",
            "pass out quick inet6 proto udp from any port 546 to ff02::1:2 port 547 no state",
            "pass out quick inet6 proto icmp6 from any to { fe80::/10, ff02::/16 } icmp6-type { 133, 134, 135, 136 } no state",
            // Only Teleport's isolated helper group may bootstrap an endpoint.
            "pass out quick inet proto tcp from any to \(bootstrapAddress) port 443 group \(runtimeGroupID) flags any no state"
        ]
        if case let .session(tunnelInterface) = stage {
            lines.append("pass out quick on \(tunnelInterface) all flags any no state")
            for endpoint in policy.endpoints {
                let family = endpoint.address.contains(":") ? "inet6" : "inet"
                let ports = endpoint.ports.replacingOccurrences(of: "-", with: ":")
                lines.append("pass out quick \(family) proto \(endpoint.transport) from any to \(endpoint.address) port { \(ports) } group \(runtimeGroupID) flags any no state")
            }
        }
        // LAN permission must not reopen ordinary DNS to the network's router.
        lines.append("block drop out quick proto { tcp, udp } to any port { 53, 853 }")
        if policy.allowsLAN {
            lines += [
                "pass out quick inet to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/24 } flags any no state",
                "pass out quick inet6 to { fe80::/10, fc00::/7, ff02::/16 } flags any no state"
            ]
        }
        if case .session = stage, policy.allowsDirect {
            // Only Xray's isolated group may implement explicit direct routing.
            lines.append("pass out quick proto { tcp, udp } all group \(runtimeGroupID) flags any no state")
        }
        lines += ["block drop out quick inet all", "block drop out quick inet6 all"]
        return lines.joined(separator: "\n") + "\n"
    }
}
