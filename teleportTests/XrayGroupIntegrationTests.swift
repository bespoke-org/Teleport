import Darwin
import Foundation
import XCTest

/// Runs the real parser and writer, then passes their output to a loopback lab.
/// This exercises Xray selection, failure and recovery without changing the
/// machine's routes, resolver, system proxy or privileged helper state.
final class XrayGroupIntegrationTests: XCTestCase {
    func testLeastLoadFailoverAllDownAndRecovery() throws {
        try exercise(strategy: "leastLoad")
    }

    func testLeastPingFailoverAllDownAndRecovery() throws {
        try exercise(strategy: "leastPing")
    }

    private func exercise(strategy: String) throws {
        executionTimeAllowance = 110
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-failover-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ports = try (0..<5).map { _ in try ReservedLoopbackPort() }
        defer { ports.forEach { $0.closeSocket() } }
        let profile: [String: Any] = [
            "outbounds": (0..<2).map { index -> [String: Any] in
                ["tag": "member-\(index)", "protocol": "vless",
                 "settings": ["vnext": [["address": "127.0.0.1", "port": ports[index].port,
                    "users": [["id": "11111111-1111-4111-8111-111111111111", "encryption": "none"]]]]],
                 "streamSettings": ["network": "tcp", "security": "none"]]
            },
            "routing": [
                "balancers": [["tag": "auto", "selector": ["member-"], "fallbackTag": "member-0",
                               "strategy": ["type": strategy]]],
                "rules": [["type": "field", "network": "tcp,udp", "balancerTag": "auto"]]
            ],
            "burstObservatory": ["subjectSelector": ["member-"], "pingConfig": [
                "destination": "http://127.0.0.1:\(ports[4].port)/probe",
                "connectivity": "", "interval": "10s", "timeout": "500ms", "sampling": 1, "httpMethod": "GET"
            ]]
        ]
        let config = try XraySubscriptionProfileParser().parseConfiguration(profile)
        let endpoint = ProxyEndpoint(host: "127.0.0.1", httpPort: ports[2].port, socksPort: ports[3].port)
        let configURL = directory.appendingPathComponent("client.json")
        _ = try XrayConfigurationWriter(proxyEndpoint: endpoint).writeConfig(for: config, to: configURL)
        // Reserve all ports together so our own listeners cannot collide. The
        // subprocess checks every bind; a competing external bind fails loudly.
        ports.forEach { $0.closeSocket() }
        let outputURL = directory.appendingPathComponent("lab.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/tests/xray_group_failover.py").path,
                             root.appendingPathComponent("teleport/Resources/xray").path, configURL.path]
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let completed = exited.wait(timeout: .now() + 90) == .success
        if !completed {
            process.terminate() // Python's finally block reaps every child.
            if exited.wait(timeout: .now() + 10) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let log = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(completed, log)
        XCTAssertEqual(process.terminationStatus, 0, log)
    }
}

private final class ReservedLoopbackPort {
    let port: Int
    private var descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { Darwin.close(descriptor); throw POSIXError(.EINVAL) }
        port = Int(UInt16(bigEndian: address.sin_port))
        self.descriptor = descriptor
    }

    func closeSocket() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { closeSocket() }
}
