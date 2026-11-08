import Foundation
import XCTest

/// Parse-only checks: never load rules, flush states or modify the host network.
final class LeakGuardTests: XCTestCase {
    private let policy = LeakGuardPolicy(endpoints: [
        .init(address: "203.0.113.7", transport: "tcp", ports: "443"),
        .init(address: "2001:db8::1", transport: "udp", ports: "4000-4010,51820")
    ])

    func testStandbyOnlyBootstrapsThroughIsolatedGroup() {
        let rules = LeakGuardRuleset.rules(stage: .standby, runtimeGroupID: 555)
        XCTAssert(rules.contains("to 1.1.1.1 port 443 group 555"))
        XCTAssertFalse(rules.contains("user root"))
        XCTAssertFalse(rules.contains(" on utun"))
        XCTAssertFalse(rules.contains("192.168.0.0/16"))
        XCTAssert(rules.contains("from any port 68 to any port 67"))
        XCTAssert(rules.contains("icmp6-type { 133, 134, 135, 136 }"))
        XCTAssert(rules.contains("block drop out quick proto { tcp, udp } to any port { 53, 853 }"))
    }

    func testEndpointExceptionsRequireAddressPortProtocolAndGroup() {
        let rules = LeakGuardRuleset.rules(stage: .session(tunnelInterface: "utun10"), policy: policy, runtimeGroupID: 555)
        XCTAssert(rules.contains("pass out quick inet proto tcp from any to 203.0.113.7 port { 443 } group 555"))
        XCTAssert(rules.contains("pass out quick inet6 proto udp from any to 2001:db8::1 port { 4000:4010,51820 } group 555"))
        XCTAssert(rules.contains("pass out quick on utun10 all"))
        XCTAssertFalse(rules.contains("all group"))
        XCTAssertFalse(rules.contains("user root"))
    }

    func testLANPermissionDoesNotReopenDNS() throws {
        let rules = LeakGuardRuleset.rules(stage: .session(tunnelInterface: "utun10"), policy: .init(allowsDirect: true, allowsLAN: true))
        let dnsBlock = try XCTUnwrap(rules.range(of: "block drop out quick proto"))
        let lanPass = try XCTUnwrap(rules.range(of: "pass out quick inet to { 10.0.0.0/8"))
        let directPass = try XCTUnwrap(rules.range(of: "pass out quick proto { tcp, udp } all group"))
        XCTAssertLessThan(dnsBlock.lowerBound, lanPass.lowerBound)
        XCTAssertLessThan(dnsBlock.lowerBound, directPass.lowerBound)
    }

    func testRulesCannotLeavePermissiveStatesAfterNarrowing() {
        for stage in [LeakGuardRuleset.Stage.standby, .session(tunnelInterface: "utun10")] {
            let rules = LeakGuardRuleset.rules(stage: stage, policy: policy)
            for line in rules.split(separator: "\n") where line.hasPrefix("pass") {
                XCTAssert(line.hasSuffix("no state"), "stateful exception: \(line)")
            }
            XCTAssert(rules.hasSuffix("block drop out quick inet all\nblock drop out quick inet6 all\n"))
        }
    }

    func testPacketFilterAcceptsEveryPolicy() throws {
        for stage in [LeakGuardRuleset.Stage.standby, .session(tunnelInterface: "utun10")] {
            for direct in [false, true] {
                for lan in [false, true] {
                    var policy = policy
                    policy.allowsDirect = direct; policy.allowsLAN = lan
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-pf-\(UUID()).conf")
                    try LeakGuardRuleset.rules(stage: stage, policy: policy).write(to: path, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: path) }
                    let process = Process(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
                    process.arguments = ["-a", LeakGuardRuleset.anchorName, "-n", "-f", path.path]
                    process.standardOutput = output; process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
                }
            }
        }
    }
}
