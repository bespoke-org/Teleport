import Darwin
import Foundation
import XCTest

/// Runs generated DNS/routing policies in the bundled core. The lab replaces only
/// TUN ingress and outbound transports with loopback listeners, so it can observe
/// every resolver choice without touching the installed app, routes, or PF.
final class DNSLeakIntegrationTests: XCTestCase {
    func testDNSQueriesStayWithinTheirResolverGroupOnSuccessAndFailure() throws {
        executionTimeAllowance = 120
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-dns-lab-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parser = ConnectionLinkParser()
        let publicConnection = RoutedProxyOutbound(connectionID: UUID(), configuration: try parser.parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@192.0.2.1:443?security=tls"))
        func peer(_ resolvers: String) throws -> RoutedProxyOutbound {
            let configuration = try parser.parse("""
            [Interface]
            PrivateKey = cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM=
            Address = 172.16.0.2/32
            DNS = \(resolvers)
            [Peer]
            PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
            AllowedIPs = 0.0.0.0/0
            Endpoint = 192.0.2.2:51820
            """)
            return RoutedProxyOutbound(connectionID: UUID(), configuration: configuration)
        }
        let first = try peer("1.1.1.1"), second = try peer("1.1.1.1")
        let rules: [SplitTunnelRule] = [
            .init(value: "direct.test", kind: .domain, action: .direct),
            .init(value: "first.test", kind: .domain, action: .proxy, connectionID: first.connectionID),
            .init(value: "second.test", kind: .domain, action: .proxy, connectionID: second.connectionID),
            // Intentionally reverse outbound order for overlapping domain rules.
            .init(value: "overlap.test", kind: .domain, action: .proxy, connectionID: second.connectionID),
            .init(value: "overlap.test", kind: .domain, action: .proxy, connectionID: first.connectionID)
        ]
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        func config(_ outbounds: [RoutedProxyOutbound], remote: String, defaultAction: SplitTunnelRuleAction = .proxy,
                    localDomains: [String] = ["domain:home.arpa"]) throws -> Any {
            let data = try writer.tunnelConfigData(for: outbounds, interfaceName: "utun99",
                splitTunnelRules: rules, defaultAction: defaultAction,
                dnsPolicy: .init(localResolvers: ["1.1.1.1"], remoteResolver: remote, localDomains: localDomains))
            return try JSONSerialization.jsonObject(with: data)
        }
        let outbounds = [publicConnection, first, second]
        // Plain DNS is only a controlled test upstream. Production's default DoH
        // remains covered separately by an actual TLS failure with no fallback.
        let fixtures: [String: Any] = [
            "udp": try config(outbounds, remote: "1.1.1.1"),
            "tcp": try config(outbounds, remote: "tcp://1.1.1.1"),
            "direct-default": try config(outbounds, remote: "1.1.1.1", defaultAction: .direct),
            "full-proxy": try config(outbounds, remote: "1.1.1.1", localDomains: []),
            "default-peer": try config([peer("1.1.1.1, 1.0.0.1")], remote: "1.1.1.1"),
            "doh-failure": try config(outbounds, remote: TunnelDNSPolicy.defaultRemoteResolver)
        ]
        let configURL = directory.appendingPathComponent("generated.json")
        try JSONSerialization.data(withJSONObject: fixtures, options: [.sortedKeys]).write(to: configURL)
        let outputURL = directory.appendingPathComponent("lab.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/tests/xray_dns_leak.py").path,
                             root.appendingPathComponent("teleport/Resources/xray").path, configURL.path]
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let completed = exited.wait(timeout: .now() + 100) == .success
        if !completed {
            process.terminate()
            if exited.wait(timeout: .now() + 10) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let log = try String(contentsOf: outputURL, encoding: .utf8)
        print(log)
        XCTAssertTrue(completed, log)
        XCTAssertEqual(process.terminationStatus, 0, log)
    }
}
