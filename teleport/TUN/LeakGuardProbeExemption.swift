import Foundation

/// Defense in depth for already queued probes. Protection never opens a path
/// for a health check or resolves its endpoint through the system resolver.
nonisolated struct LeakGuardProbeExemption: ProbeUplinkExemption {
    private let leakGuard: LeakGuardService

    init(leakGuard: LeakGuardService) { self.leakGuard = leakGuard }

    func open(host: String) async -> ProbeUplinkExemptionOutcome {
        await leakGuard.isHoldingUplink ? .blockedByProtection : .notNeeded
    }

    func close(_ addresses: [String]) async {}
}
