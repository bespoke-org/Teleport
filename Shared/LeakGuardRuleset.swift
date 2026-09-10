import Foundation

/// The pf ruleset that keeps traffic off the physical uplink while a VPN session
/// is meant to be carrying it.
///
/// A routed session is torn down and rebuilt whenever the uplink changes, and
/// between the teardown and the next tunnel the machine routes directly — for
/// seconds after a wake, and for as long as a commute when the uplink went away
/// entirely. Applications do not wait: a browser reissues its open requests the
/// moment DHCP publishes an address, and the far side records whatever address it
/// arrived from. Routing alone cannot close that window, because there is nothing
/// to route through yet; only a filter can.
///
/// Kept as a pure function of the session's facts so the rules can be read and
/// verified without a network to take down, in the manner of `UplinkChangeDecision`.
nonisolated enum LeakGuardRuleset: Sendable {
    /// Loaded under the `com.apple` anchor point that `/etc/pf.conf` already
    /// evaluates. A sub-anchor needs no edit to a system file, unlike a top-level
    /// one, and is flushed by a reboot rather than outliving the app that set it.
    static let anchorName = "com.apple/dev.x.teleport"

    enum Stage: Equatable, Sendable {
        /// No tunnel exists. Nothing but the local network, DNS and the proxy
        /// servers themselves has any legitimate reason to leave the machine.
        case standby
        /// A session owns `tunnelInterface`. Traffic leaving through the tunnel is
        /// the point of the exercise, and Xray's own transport has to reach the
        /// servers outside it.
        case session(tunnelInterface: String)
    }

    /// Destinations that never leave the local link, so blocking them would break
    /// address configuration and local discovery without protecting anything.
    private static let localIPv4Destinations = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255",
    ]

    private static let localIPv6Destinations = [
        "fe80::/10",
        "fc00::/7",
        "ff00::/8",
    ]

    /// `protectedHosts` are the numeric proxy-server addresses this session pins to
    /// the physical uplink; their transport is what carries everything else and
    /// cannot itself be blocked.
    static func rules(stage: Stage, protectedHosts: [String]) -> String {
        var lines: [String] = []
        lines.append("# Teleport leak guard — flushed by a reboot, by the app, or by its lease expiring.")
        lines.append("pass quick on lo0 all")

        if case let .session(tunnelInterface) = stage {
            lines.append("pass out quick on \(tunnelInterface) all")
            // Xray's direct outbound — split-tunnel rules whose action is `direct` —
            // leaves on the uplink from the uplink's own address, which is exactly
            // what a leaking application looks like. The one thing that separates
            // them is the user: the helper runs Xray as root, and the applications
            // this guard exists for do not.
            lines.append("pass out quick all user root")
        }

        lines.append("pass out quick inet proto udp from any to any port { 67, 68 }")
        lines.append("pass out quick inet to { \(localIPv4Destinations.joined(separator: ", ")) }")
        lines.append("pass out quick inet6 to { \(localIPv6Destinations.joined(separator: ", ")) }")
        // Name resolution is allowed to any resolver: the address of the proxy
        // server has to be resolvable before a session can be built at all, and a
        // machine that cannot resolve anything is indistinguishable from a broken
        // one. What this leaks is the names asked for, never the address they are
        // asked from — which is the disclosure the guard exists to prevent.
        lines.append("pass out quick proto { tcp, udp } from any to any port { 53, 853 }")

        for protectedHost in protectedHosts where !protectedHost.isEmpty {
            let family = protectedHost.contains(":") ? "inet6" : "inet"
            lines.append("pass out quick \(family) to \(protectedHost)")
        }

        lines.append("block drop out quick inet all")
        lines.append("block drop out quick inet6 all")
        return lines.joined(separator: "\n") + "\n"
    }
}
