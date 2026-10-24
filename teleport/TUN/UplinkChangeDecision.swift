import Foundation

/// What a running session should do when the uplink underneath it changes.
///
/// Kept as a pure function of the two uplinks so the rule can be verified without
/// taking a real network down, which is the only other way to exercise it.
nonisolated enum UplinkChangeDecision: Equatable, Sendable {
    /// The session still stands on what it was built on.
    case keepRunning
    /// The uplink is gone. Tear down so the machine is left routing directly
    /// instead of into a tunnel whose transport can no longer reach its server,
    /// and reconnect once an uplink comes back.
    case tearDownAndWaitForUplink
    /// A different uplink, or the same one with a new gateway. The pinned routes
    /// name a gateway that no longer exists, so the session has to be rebuilt.
    case reconnect

    static func decide(
        sessionUplink: SystemUplinkInventory.Uplink?,
        currentUplink: SystemUplinkInventory.Uplink?
    ) -> UplinkChangeDecision {
        guard let currentUplink else { return .tearDownAndWaitForUplink }
        // Nothing was recorded for the session, so there is nothing to contradict.
        guard let sessionUplink else { return .keepRunning }
        return sessionUplink == currentUplink ? .keepRunning : .reconnect
    }
}
