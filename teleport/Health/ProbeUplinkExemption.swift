import Foundation

/// What opening a path for a probe achieved.
nonisolated enum ProbeUplinkExemptionOutcome: Sendable {
    /// Nothing is filtering the uplink, so the probe needs no path opened and has
    /// nothing to close afterwards.
    case notNeeded
    /// These addresses stay open until they are closed again.
    case opened([String])
    /// The uplink is filtered and the server's name resolves to nothing, so there
    /// is no address to open. The probe cannot ask, and must not report silence as
    /// an answer.
    case couldNotResolve
}

/// Lets a health probe reach the server it is questioning while the leak guard is
/// filtering the physical uplink.
///
/// Injected rather than reached for, so `ConnectionHealthProbeService` stays a
/// description of how to probe a server and knows nothing about the privileged
/// side that makes the probe possible.
nonisolated protocol ProbeUplinkExemption: Sendable {
    func open(host: String) async -> ProbeUplinkExemptionOutcome
    func close(_ addresses: [String]) async
}
