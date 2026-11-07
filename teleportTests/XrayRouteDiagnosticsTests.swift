import Foundation
import XCTest

final class XrayRouteDiagnosticsTests: XCTestCase {
    func testDNSFailureIsDistinctFromIPv6AndGenericRouteFailure() throws {
        let inspector = XrayTunRouteInspector(runCommand: { _, _ in nil })
        for (addresses, message) in [
            ([String](), "DNS lookup failed"),
            (["2001:db8::1"], "IPv6 route unavailable"),
            (["192.0.2.1"], "No physical route"),
            (["2001:db8::1", "192.0.2.1"], "No physical route")
        ] {
            XCTAssertThrowsError(try inspector.protectedRoute(for: "proxy.example.test", resolvedAddresses: addresses)) {
                XCTAssertTrue($0.localizedDescription.hasPrefix(message), $0.localizedDescription)
            }
        }
    }

    func testLaterReachableAddressStillWorks() throws {
        let inspector = XrayTunRouteInspector(runCommand: { _, arguments in
            arguments.last == "192.0.2.1" ? "interface: en0\n" : nil
        })
        let route = try inspector.protectedRoute(for: "proxy.example.test", resolvedAddresses: ["2001:db8::1", "192.0.2.1"])
        XCTAssertEqual(route.address, "192.0.2.1")
        XCTAssertEqual(route.interface, "en0")
    }

    func testIPv6RouteIsNotRejectedWhenAvailable() throws {
        let inspector = XrayTunRouteInspector(runCommand: { _, arguments in
            arguments.contains("-inet6") ? "interface: en0\n" : nil
        })
        XCTAssertEqual(try inspector.protectedRoute(for: "2001:db8::1").address, "2001:db8::1")
    }
}
