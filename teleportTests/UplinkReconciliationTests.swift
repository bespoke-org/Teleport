import Foundation
import XCTest

/// The rule a running session is reconciled against when the network path changes.
/// Exercising it through a real interface going down is not something a check can
/// arrange, so the decision itself is a pure function and this covers it directly.
final class UplinkReconciliationTests: XCTestCase {
    private let wifi = SystemUplinkInventory.Uplink(interfaceName: "en0", routerAddress: "192.168.1.1")

    func testUnchangedUplinkKeepsSessionRunning() throws {
        let decision = UplinkChangeDecision.decide(sessionUplink: wifi, currentUplink: wifi)
        XCTAssert(decision == .keepRunning, "an unchanged uplink must not disturb a running session")
    }

    /// Losing the uplink is the case that bricked the machine: the tunnel keeps both
    /// default halves while its own transport can no longer reach the server, so the
    /// session has to come down rather than be left in place.
    func testMissingUplinkTearsSessionDown() throws {
        let decision = UplinkChangeDecision.decide(sessionUplink: wifi, currentUplink: nil)
        XCTAssert(decision == .tearDownAndWaitForUplink, "a vanished uplink must tear the session down")
    }

    func testChangedInterfaceReconnects() throws {
        let ethernet = SystemUplinkInventory.Uplink(interfaceName: "en5", routerAddress: "192.168.1.1")
        let decision = UplinkChangeDecision.decide(sessionUplink: wifi, currentUplink: ethernet)
        XCTAssert(decision == .reconnect, "a different primary interface must rebuild the session")
    }

    /// The same interface returning with a new lease is as broken as a different one:
    /// the proxy-server routes are pinned to the gateway that was current at start.
    func testSameInterfaceWithNewRouterReconnects() throws {
        let sameInterfaceNewLease = SystemUplinkInventory.Uplink(interfaceName: "en0", routerAddress: "10.0.0.1")
        let decision = UplinkChangeDecision.decide(sessionUplink: wifi, currentUplink: sameInterfaceNewLease)
        XCTAssert(decision == .reconnect, "a new gateway on the same interface must rebuild the session")
    }

    /// Nothing was recorded for the session, so there is nothing to contradict —
    /// tearing down on that basis would drop a working session for no reason.
    func testUnknownSessionUplinkIsNotTreatedAsAChange() throws {
        let decision = UplinkChangeDecision.decide(sessionUplink: nil, currentUplink: wifi)
        XCTAssert(decision == .keepRunning, "an unrecorded session uplink must not force a rebuild")
    }
}
