import Foundation

/// Opens the server a health probe is about to question on the physical uplink,
/// for as long as that probe runs.
///
/// A probe leaves through the uplink by design: carried by a running tunnel it
/// would measure the tunnel rather than the server. While the guard is armed,
/// everything on that uplink is dropped except the session's own servers — so a
/// server outside the session is reported unreachable without a single packet
/// having been sent to it. What is opened here is the same kind of path the
/// session's own servers already hold, for the seconds a check takes.
///
/// Every address the name resolves to is opened rather than the first: the
/// probe's Xray resolves the name itself and may well choose a different one. Only
/// the first few, though — the helper bounds how many hosts it will route, and a
/// burst of concurrent checks has to fit inside that bound alongside the session's
/// own servers.
nonisolated struct LeakGuardProbeExemption: ProbeUplinkExemption {
    private let leakGuard: LeakGuardService
    private let routeInspector: XrayTunRouteInspector

    init(leakGuard: LeakGuardService, routeInspector: XrayTunRouteInspector = XrayTunRouteInspector()) {
        self.leakGuard = leakGuard
        self.routeInspector = routeInspector
    }

    func open(host: String) async -> ProbeUplinkExemptionOutcome {
        guard await leakGuard.isHoldingUplink else { return .notNeeded }
        // Resolution itself is never blocked: the guard passes port 53 precisely so
        // that a server's address can be learned while it is armed.
        let addresses = Array(
            routeInspector.resolvedAddresses(for: host).prefix(ProbeHostExemptions.maximumAddressesPerProbe)
        )
        guard !addresses.isEmpty else { return .couldNotResolve }
        await leakGuard.retainProbeHosts(addresses)
        return .opened(addresses)
    }

    func close(_ addresses: [String]) async {
        await leakGuard.releaseProbeHosts(addresses)
    }
}
