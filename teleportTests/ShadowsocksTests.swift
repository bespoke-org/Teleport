import Darwin
import Foundation
import XCTest

final class ShadowsocksTests: XCTestCase {
    private let parser = ConnectionLinkParser()

    private func fixture() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("teleportTests/fixtures/subscriptions/shadowsocks.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func imported(_ data: Data, filter: Bool = true) throws -> SubscriptionImportResult {
        try SubscriptionImportProcessor.importEntries(
            candidates: SubscriptionPayloadDecoder().decode(data), parser: parser,
            sourceID: UUID(), filterDuplicateImports: filter)
    }

    private func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    func testLinkEncodingsAndRename() throws {
        let password = "pa:ss@/%+?#密碼"
        let credentials = "chacha20-ietf-poly1305:" + password
        let base64 = Data(credentials.utf8).base64EncodedString()
        let websafe = base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for host in ["example.com", "[2001:db8::1]"] {
            let links = [
                "ss://\(base64)@\(host):8388/#Name%20%23%25",
                "SS://\(websafe)@\(host):8388#Name%20%23%25",
                "ss://chacha20-ietf-poly1305:\(encoded(password))@\(host):8388#Name%20%23%25",
                "ss://\(Data((credentials + "@\(host):8388").utf8).base64EncodedString())#Name%20%23%25",
            ]
            let configs = try links.map(parser.parse)
            XCTAssertTrue(configs.allSatisfy { $0 == configs[0] })
            let config = configs[0]
            XCTAssertEqual(config.shadowsocks?.password, password)
            XCTAssertEqual(config.remarks, "Name #%")
            XCTAssertEqual(config.host, host == "example.com" ? host : "2001:db8::1")
            XCTAssertEqual(config.protocolType.displayName, "Shadowsocks")
            XCTAssertNil(config.securityWarningText)
            XCTAssertTrue(config.descriptiveSummary.contains("chacha20-ietf-poly1305"))
            XCTAssertFalse(config.descriptiveSummary.contains("No encryption"))
            XCTAssertEqual(try parser.parse(config.rawLink), config)
            let renamed = config.withDisplayName("My / # server %")
            XCTAssertEqual(try parser.parse(renamed.rawLink), renamed)
            let unnamed = config.withDisplayName("")
            XCTAssertEqual(try parser.parse(unnamed.rawLink), unnamed)
        }
    }

    func testAEAD2022KeysAndAliases() throws {
        for method in ["2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"] {
            let key = Data(repeating: 251, count: method.contains("aes-128") ? 16 : 32).base64EncodedString()
            let config = try parser.parse("ss://\(method):\(encoded(key))@example.com:8388")
            XCTAssertEqual(config.shadowsocks?.password, key)
            XCTAssertEqual(try parser.parse(config.rawLink), config)
            let chain = "ss://\(method):\(encoded(key + ":" + key))@example.com:8388"
            if method.contains("chacha20") {
                XCTAssertThrowsError(try parser.parse(chain))
            } else {
                XCTAssertEqual(try parser.parse(chain).shadowsocks?.password, key + ":" + key)
            }
            let base64 = Data("\(method):\(key)".utf8).base64EncodedString()
            XCTAssertThrowsError(try parser.parse("ss://\(base64)@example.com:8388"))
        }
        XCTAssertEqual(try parser.parse("ss://CHACHA20-POLY1305:password@example.com:8388").shadowsocks?.method, "chacha20-ietf-poly1305")
    }

    func testInvalidLinksDoNotExposeCredentials() throws {
        let key = Data(repeating: 0, count: 32).base64EncodedString()
        let invalid = [
            "ss://", "ss://REDACTED", "ss://aes-128-gcm:@example.com:8388", "ss://none:private-secret@example.com:8388",
            "ss://aes-256-cfb:private-secret@example.com:8388", "ss://aes-128-gcm:private-secret@example.com:0",
            "ss://aes-128-gcm:private-secret@example.com:65536", "ss://aes-128-gcm:private-secret@example.com",
            "ss://aes-128-gcm:private-secret@:8388", "ss://aes-128-gcm:private-secret@example.com:8388/path",
            "ss://aes-128-gcm:private-secret@example.com:8388/?plugin=obfs-local",
            "ss://aes-128-gcm:private-secret@example.com:8388?prefix=private-secret",
            "ss://aes-128-gcm:private-secret@example.com:8388?plugin=&plugin=",
            "ss://aes-128-gcm:private-secret@example.com:8388?type=ws",
            "ss://aes-128-gcm:private-secret%ZZ@example.com:8388",
            "ss://2022-blake3-aes-128-gcm:\(encoded(key))@example.com:8388",
            "ss://2022-blake3-aes-256-gcm:private-secret@example.com:8388",
            "ss://2022-blake3-aes-256-gcm:\(encoded(key + ":"))@example.com:8388",
        ]
        for link in invalid {
            XCTAssertThrowsError(try parser.parse(link)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-secret"))
            }
        }
    }

    func testJSONShapesAndUnsupportedSettings() throws {
        let profile = try fixture()
        let config = try XraySubscriptionProfileParser().parseConfiguration(profile)
        XCTAssertEqual(config.shadowsocks?.method, "aes-128-gcm")
        XCTAssertEqual(config.shadowsocks?.password, "synthetic-password")
        var outbound = try XCTUnwrap((profile["outbounds"] as? [[String: Any]])?.first)
        let endpoint = try XCTUnwrap(outbound["settings"] as? [String: Any])
        outbound["settings"] = ["servers": [endpoint]]
        let legacy: [String: Any] = ["remarks": "Example Shadowsocks", "outbounds": [outbound]]
        XCTAssertEqual(try XraySubscriptionProfileParser().parseConfiguration(legacy), config)
        outbound["streamSettings"] = ["network": "raw", "security": "none", "rawSettings": ["header": ["type": "none"]]]
        XCTAssertEqual(try XraySubscriptionProfileParser().parseConfiguration(["remarks": "Example Shadowsocks", "outbounds": [outbound]]), config)
        for change: [String: Any] in [
            ["settings": ["servers": [endpoint, endpoint]]],
            ["settings": ["servers": [endpoint], "address": "example.com"]],
            ["streamSettings": ["network": "ws"]],
            ["streamSettings": ["security": "tls"]],
            ["streamSettings": ["tcpSettings": ["header": ["type": "http"]]]],
            ["streamSettings": ["sockopt": ["dialerProxy": "secret-chain"]]],
            ["streamSettings": ["finalmask": ["tcp": []]]],
            ["mux": ["enabled": true]], ["plugin": "private-secret"],
        ] {
            let changed = outbound.merging(change, uniquingKeysWith: { _, new in new })
            XCTAssertThrowsError(try XraySubscriptionProfileParser().parseConfiguration(["outbounds": [changed]])) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-secret"))
            }
        }
        for port: Any in [0, 65536, 1.5, true, "8388"] {
            var bad = endpoint
            bad["port"] = port
            XCTAssertThrowsError(try XraySubscriptionProfileParser().parseConfiguration(["outbounds": [["protocol": "shadowsocks", "settings": bad]]]))
        }
        for host in ["example.com\u{0}", "bad host", "[invalid:ipv6]", "example.com/path"] {
            var bad = endpoint
            bad["address"] = host
            XCTAssertThrowsError(try XraySubscriptionProfileParser().parseConfiguration(["outbounds": [["protocol": "shadowsocks", "settings": bad]]]))
        }
    }

    func testSubscriptionIdentityPersistenceAndRefresh() throws {
        let profile = try fixture()
        let first = try imported(JSONSerialization.data(withJSONObject: [profile])).importedEntries[0]
        let config = first.configuration
        let variant = "ss://\(Data("aes-128-gcm:synthetic-password".utf8).base64EncodedString())@EXAMPLE.COM:8388#Provider%20rename"
        let mixed = "\(config.rawLink)\n\(variant)\nss://aes-128-gcm:different@example.com:8388\nss://aes-256-gcm:synthetic-password@example.com:8388"
        for data in [Data(mixed.utf8), Data(Data(mixed.utf8).base64EncodedString().utf8)] {
            XCTAssertEqual(try imported(data).importedEntries.count, 3)
            XCTAssertEqual(try imported(data, filter: false).importedEntries.count, 3)
        }
        let refreshed = try imported(Data(variant.utf8)).importedEntries[0]
        XCTAssertEqual(first.sourceEntryID, refreshed.sourceEntryID)
        let sourceID = UUID()
        let saved = SavedConnection(
            id: UUID(), configuration: config, savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: first.sourceEntryID), customName: "My # server")
        let replacement = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [saved], sourceID: sourceID, selectedConnectionID: saved.id,
            importedEntries: [refreshed], fetchedAt: Date(), autoSelectFirstImported: false)
        XCTAssertEqual(replacement.selectedConnectionID, saved.id)
        let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(replacement.savedConnections[0]))
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.savedAt, saved.savedAt)
        XCTAssertEqual(restored.customName, saved.customName)
        XCTAssertEqual(try parser.parse(restored.configuration.rawLink), restored.configuration)
        XCTAssertEqual(try parser.parse(restored.shareableLink).remarks, "My # server")
        XCTAssertEqual(try parser.parse(restored.shareableLink).shadowsocks, config.shadowsocks)
        let old = try parser.parse("trojan://password@example.com:443")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(old)), old)
        let mixedResult = try imported(Data((variant + "\nss://none:private-secret@example.com:8388\ntrojan://password@example.com:443").utf8))
        XCTAssertEqual(mixedResult.importedEntries.count, 2)
        XCTAssertEqual(mixedResult.skippedCount, 1)
        XCTAssertFalse(mixedResult.statusMessage!.contains("private-secret"))
    }

    func testSplitRoutingAndCompositeMembers() throws {
        let shadowsocks = try XraySubscriptionProfileParser().parseConfiguration(fixture())
        let other = try parser.parse("trojan://synthetic-password@other.example.com:443")
        let firstID = UUID()
        let secondID = UUID()
        let routes = [
            RoutedProxyOutbound(connectionID: firstID, configuration: other, serverAddress: "192.0.2.1"),
            RoutedProxyOutbound(connectionID: secondID, configuration: shadowsocks, serverAddress: "192.0.2.2"),
        ]
        let rule = SplitTunnelRule(value: "example.org", kind: .domain, action: .proxy, connectionID: secondID)
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: routes, interfaceName: "utun99", outboundInterface: "en0", splitTunnelRules: [rule],
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"]))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbound = try XCTUnwrap((payload["outbounds"] as? [[String: Any]])?.first { $0["protocol"] as? String == "shadowsocks" })
        XCTAssertEqual((outbound["settings"] as? [String: Any])?["address"] as? String, "192.0.2.2")
        let rules = try XCTUnwrap((payload["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first { $0["domain"] as? [String] == ["domain:example.org"] }?["outboundTag"] as? String, outbound["tag"] as? String)

        let url = repositoryRoot.appendingPathComponent("teleportTests/fixtures/subscriptions/balanced-ws.json")
        var group = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var members = try XCTUnwrap(group["outbounds"] as? [[String: Any]])
        var member = try XCTUnwrap((fixture()["outbounds"] as? [[String: Any]])?.first)
        member["tag"] = members[0]["tag"]
        members[0] = member
        group["outbounds"] = members
        let composite = try XraySubscriptionProfileParser().parseConfiguration(group)
        XCTAssertEqual(composite.composite?.members.first?.configuration.shadowsocks, shadowsocks.shadowsocks)
        XCTAssertEqual(try parser.parse(composite.rawLink), composite)
        XCTAssertTrue(composite.endpointConfigurations.contains { $0.host == shadowsocks.host })
    }

    func testGeneratedConfigsAndLoopbackTCPUDP() throws {
        executionTimeAllowance = 110
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-shadowsocks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let methods = [
            "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        ]
        for method in methods {
            let password =
                method.hasPrefix("2022-")
                ? Data(repeating: 7, count: method.contains("aes-128") ? 16 : 32).base64EncodedString() : "synthetic-password"
            let config = try parser.parse("ss://\(method):\(encoded(password))@example.com:8388")
            let writer = XrayConfigurationWriter(proxyEndpoint: .default)
            _ = try writer.writeConfig(for: config, to: directory.appendingPathComponent("\(method)-system.json"))
            let tunnel = try writer.tunnelConfigData(
                for: config, interfaceName: "utun99", outboundInterface: "lo0", proxyServerAddress: "127.0.0.1",
                dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"]))
            try tunnel.write(to: directory.appendingPathComponent("\(method)-tunnel.json"))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: tunnel) as? [String: Any])
            let proxy = try XCTUnwrap((payload["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" })
            let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
            XCTAssertEqual(settings["address"] as? String, "127.0.0.1")
            XCTAssertEqual(settings["method"] as? String, method)
            XCTAssertEqual(settings["password"] as? String, password)
            let stream = proxy["streamSettings"] as? [String: Any]
            XCTAssertEqual((stream?["sockopt"] as? [String: Any])?["interface"] as? String, "lo0")
        }
        let outputURL = directory.appendingPathComponent("lab.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/tests/xray_shadowsocks.py").path,
            repositoryRoot.appendingPathComponent("teleport/Resources/xray").path, directory.path,
        ]
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let completed = exited.wait(timeout: .now() + 90) == .success
        if !completed {
            process.terminate()
            if exited.wait(timeout: .now() + 10) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let log = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(completed, log)
        XCTAssertEqual(process.terminationStatus, 0, log)
    }
}
