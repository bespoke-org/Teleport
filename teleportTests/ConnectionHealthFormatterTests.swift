import Foundation
import XCTest

final class ConnectionHealthFormatterTests: XCTestCase {
    func testPersistedWireGuardFailureUsesSameLabelAsTLS() throws {
        let legacy = Data("""
        {
          "state": "unreachable",
          "failureSummary": "The peer did not answer the WireGuard handshake"
        }
        """.utf8)
        let wireGuard = try JSONDecoder().decode(ConnectionHealthCheck.self, from: legacy)
        let tls = check(.unreachable, reason: "TLS handshake failed")

        XCTAssertEqual(ConnectionHealthFormatter.label(for: wireGuard), "Handshake failed")
        XCTAssertEqual(ConnectionHealthFormatter.label(for: tls), "Handshake failed")
        XCTAssertEqual(wireGuard.failureSummary, "The peer did not answer the WireGuard handshake")
    }

    func testLatencyLabelsAreConsistentAcrossMeasurementKinds() {
        for kind: ConnectionHealthLatencyKind? in [.proxyRequest, .wireGuardHandshake, .tcpConnect, nil] {
            var result = check(.reachable)
            result.latencyMilliseconds = 111
            result.latencyKind = kind
            XCTAssertEqual(ConnectionHealthFormatter.label(for: result, locale: Locale(identifier: "en_US")), "111 ms")
        }
    }

    func testFailedLocalCheckDoesNotClaimHandshakeFailure() {
        let result = check(.unknown, reason: "Teleport could not send a WireGuard handshake to this peer")
        XCTAssertEqual(ConnectionHealthFormatter.label(for: result), "Check failed")
        XCTAssertEqual(ConnectionHealthFormatter.label(for: .unknown), "Not checked")
        var previouslyChecked = ConnectionHealthCheck.unknown
        previouslyChecked.checkedAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ConnectionHealthFormatter.label(for: previouslyChecked), "Unknown")
    }

    func testRuntimeDiagnosticsCannotBecomeMenuLabels() {
        let diagnostic = "Runtime failed: " + String(repeating: "detailed diagnostic ", count: 100)
        let result = check(.unreachable, reason: diagnostic)
        XCTAssertEqual(ConnectionHealthFormatter.label(for: result), "Unavailable")
        XCTAssertEqual(result.failureSummary, diagnostic)
        XCTAssertEqual(ConnectionHealthFormatter.label(for: check(.unreachable, reason: "\n Timed out \n")), "Timed out")
    }

    func testActiveAndSuccessfulChecksIgnoreStaleFailureDetails() {
        for (state, expected): (ConnectionHealthState, String) in [
            (.queued, "Queued…"), (.checking, "Checking…"), (.reachable, "Available")
        ] {
            XCTAssertEqual(ConnectionHealthFormatter.label(for: check(state, reason: "TLS handshake failed")), expected)
        }
    }

    private func check(_ state: ConnectionHealthState, reason: String? = nil) -> ConnectionHealthCheck {
        ConnectionHealthCheck(state: state, checkedAt: nil, latencyMilliseconds: nil,
                              latencyKind: nil, failureSummary: reason)
    }
}
