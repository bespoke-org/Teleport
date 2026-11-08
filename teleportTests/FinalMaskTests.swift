import Foundation
import XCTest

final class FinalMaskTests: XCTestCase {
    private func mask(delay: String = "1-2") -> [String: Any] {
        ["tcp": [["type": "fragment", "settings": ["packets": "tlshello", "length": "10-20", "delay": delay]]]]
    }

    private func link(_ mask: Any, scheme: String = "vless", security: String = "tls") throws -> String {
        var url = URLComponents()
        url.scheme = scheme
        url.host = "proxy.example.test"
        url.port = 443
        url.user = scheme == "trojan" ? "synthetic-password" : "11111111-1111-4111-8111-111111111111"
        url.queryItems = [URLQueryItem(name: "security", value: security), URLQueryItem(name: "type", value: "tcp"),
                         URLQueryItem(name: "fm", value: String(decoding: try JSONSerialization.data(withJSONObject: mask, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self))]
        if security == "reality" {
            url.queryItems! += [URLQueryItem(name: "sni", value: "example.test"),
                               URLQueryItem(name: "pbk", value: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                               URLQueryItem(name: "fp", value: "firefox")]
        }
        return try XCTUnwrap(url.string)
    }

    private func payload(_ config: ConnectionConfiguration) throws -> [String: Any] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: config, to: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testLinkFragmentationReachesGeneratedProxyConfiguration() throws {
        for delay in ["1-2", "2-5"] {
            let config = try ConnectionLinkParser().parse(link(mask(delay: delay)))
            let outbounds = try XCTUnwrap(try payload(config)["outbounds"] as? [[String: Any]])
            let stream = try XCTUnwrap(outbounds.first?["streamSettings"] as? [String: Any])
            XCTAssertEqual(stream["finalmask"] as? NSDictionary, mask(delay: delay) as NSDictionary)
        }
    }

    func testUnsupportedMasksAreRejectedInsteadOfDropped() throws {
        XCTAssertThrowsError(try ConnectionLinkParser().parse(link(["tcp": [["type": "unknown", "settings": [:]]]])))
    }

    func testRoundTripsRenameExportAndLegacyPersistence() throws {
        for scheme in ["vless", "trojan"] {
            let config = try ConnectionLinkParser().parse(link(mask(), scheme: scheme))
            let renamed = config.withDisplayName("My portal")
            XCTAssertEqual(renamed.finalMask, config.finalMask)
            XCTAssertEqual(try ConnectionLinkParser().parse(renamed.rawLink), renamed)
            XCTAssertEqual(config.duplicateFilterIdentity, renamed.duplicateFilterIdentity)
            XCTAssertEqual(try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(config)), config)
            let saved = SavedConnection(id: UUID(), configuration: config, savedAt: Date(), customName: "Shared name")
            XCTAssertEqual(try ConnectionLinkParser().parse(saved.shareableLink).finalMask, config.finalMask)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            legacy.removeValue(forKey: "finalMask")
            XCTAssertNil(try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).finalMask)
        }
    }

    func testMaskDifferencesSurviveDeduplicationAndRefresh() throws {
        let sourceID = UUID()
        let links = try [link(mask()), link(mask(delay: "2-5")), link(mask())]
        let candidates = try SubscriptionPayloadDecoder().decode(Data(Data(links.joined(separator: "\n").utf8).base64EncodedString().utf8))
        let imported = try SubscriptionImportProcessor.importEntries(candidates: candidates, parser: ConnectionLinkParser(), sourceID: sourceID, filterDuplicateImports: true)
        XCTAssertEqual(imported.importedEntries.count, 2)
        XCTAssertEqual(imported.skippedCount, 0)
        let saved = imported.importedEntries.map { entry in
            SavedConnection(id: UUID(), configuration: entry.configuration, savedAt: Date(),
                source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: entry.sourceEntryID), customName: "Custom name")
        }
        let refreshed = SubscriptionConnectionReconciler().reconcile(existingConnections: saved, sourceID: sourceID,
            selectedConnectionID: saved[0].id, importedEntries: imported.importedEntries, fetchedAt: Date(), autoSelectFirstImported: false)
        XCTAssertEqual(refreshed.savedConnections, saved)
        XCTAssertEqual(refreshed.selectedConnectionID, saved[0].id)
        for connection in refreshed.savedConnections {
            XCTAssertNotNil(try ConnectionLinkParser().parse(connection.configuration.rawLink).finalMask)
        }
        var reordered = try XCTUnwrap(URLComponents(string: links[0]))
        reordered.queryItems?.reverse()
        let same = try ConnectionLinkParser().parse(XCTUnwrap(reordered.string))
        XCTAssertEqual(same.duplicateFilterIdentity, imported.importedEntries[0].configuration.duplicateFilterIdentity)
    }

    func testJSONAndBalancedMembersPreserveFragmentation() throws {
        let config = try ConnectionLinkParser().parse(link(mask()))
        let outbound = try XCTUnwrap((try payload(config)["outbounds"] as? [[String: Any]])?.first)
        let imported = try XraySubscriptionProfileParser().parseConfiguration(["outbounds": [outbound]])
        XCTAssertEqual(imported.finalMask, config.finalMask)
        XCTAssertEqual(try ConnectionLinkParser().parse(imported.rawLink).finalMask, config.finalMask)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/subscriptions/balanced-ws.json")
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        var members = try XCTUnwrap(fixture["outbounds"] as? [[String: Any]])
        for index in members.indices where members[index]["protocol"] as? String == "vless" {
            var replacement = outbound
            replacement["tag"] = members[index]["tag"]
            members[index] = replacement
        }
        fixture["outbounds"] = members
        let group = try XraySubscriptionProfileParser().parseConfiguration(fixture)
        XCTAssertEqual(group.composite?.members.count, 2)
        XCTAssertTrue(group.composite!.members.allSatisfy { $0.configuration.finalMask == config.finalMask })
        let tunnel = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: group, interfaceName: "utun99")
        let generated = try XCTUnwrap(JSONSerialization.jsonObject(with: tunnel) as? [String: Any])
        let proxies = try XCTUnwrap(generated["outbounds"] as? [[String: Any]]).filter { $0["protocol"] as? String == "vless" }
        XCTAssertEqual(proxies.count, 2)
        for proxy in proxies {
            XCTAssertEqual((proxy["streamSettings"] as? [String: Any])?["finalmask"] as? NSDictionary, mask() as NSDictionary)
        }
    }

    func testInvalidMasksAndIncompatibleTransportsAreRejectedWithSafeErrors() throws {
        let badSettings: [[String: Any]] = [
            ["packets": "tlshello", "length": "0-20"], ["length": "20-10"], ["length": -1],
            ["length": true], ["length": 1.5], ["length": "2147483648"], ["length": "10-20", "delay": "2-1"],
            ["lengths": []], ["lengths": [10, 0]], ["length": 10, "lengths": [20]],
            ["length": 10, "delay": 1, "delays": [2]], ["length": 10, "delays": []],
            ["length": 10, "maxSplit": false], ["length": 10, "packets": "0-3"],
            ["length": 10, "packets": true], ["length": 10, "secret-option": "must-not-leak"], [:]
        ]
        let invalid: [Any] = [NSNull(), [], "secret", ["udp": []], ["tcp": NSNull()], ["tcp": ["not an object"]],
                              ["tcp": [["type": "fragment"]]], ["quicParams": [:]]] + badSettings.map {
            ["tcp": [["type": "fragment", "settings": $0]]]
        }
        for value in invalid {
            XCTAssertThrowsError(try ConnectionLinkParser().parse(link(value))) { error in
                XCTAssertEqual(error as? ConfigurationError, .invalidFinalMask)
                XCTAssertFalse(error.localizedDescription.contains("must-not-leak"))
                XCTAssertEqual(SubscriptionImportProcessor.skipReason(for: error), "Unsupported or invalid FinalMask settings")
            }
        }
        let base = try link(mask())
        for incompatible in [base.replacingOccurrences(of: "type=tcp", with: "type=ws"),
                             base.replacingOccurrences(of: "security=tls", with: "security=none"),
                             base.replacingOccurrences(of: "vless://", with: "hy2://"),
                             base.replacingOccurrences(of: "vless://", with: "wireguard://")] {
            XCTAssertThrowsError(try ConnectionLinkParser().parse(incompatible)) { error in
                XCTAssertEqual(error as? ConfigurationError, .invalidFinalMask)
            }
        }
        var malformed = try XCTUnwrap(URLComponents(string: base))
        malformed.queryItems = [URLQueryItem(name: "fm", value: "{")]
        XCTAssertThrowsError(try ConnectionLinkParser().parse(XCTUnwrap(malformed.string)))
    }

    func testBundledXrayAcceptsProxyProbeAndTunnelConfigurations() throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("teleport/Resources/xray")
        let arrays: [String: Any] = ["tcp": [["type": "fragment", "settings": ["packets": "tlshello", "lengths": ["10-20", "20-30"], "delays": ["1-2"], "maxSplit": "5-10"]]]]
        for mask in [mask(), mask(delay: "2-5"), arrays] {
            for (scheme, security) in [("vless", "tls"), ("vless", "reality"), ("trojan", "tls"), ("trojan", "reality")] {
                let config = try ConnectionLinkParser().parse(link(mask, scheme: scheme, security: security))
                let writer = XrayConfigurationWriter(proxyEndpoint: .default)
                let tunnel = try writer.tunnelConfigData(for: config, interfaceName: "utun99", outboundInterface: "en0")
                let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
                defer { try? FileManager.default.removeItem(at: probeURL) }
                _ = try writer.writeConfig(for: config, to: probeURL, outboundInterface: "en0")
                for data in [try JSONSerialization.data(withJSONObject: payload(config)), tunnel, try Data(contentsOf: probeURL)] {
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let proxy = try XCTUnwrap((json["outbounds"] as? [[String: Any]])?.first)
                    let stream = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
                    XCTAssertEqual(stream["finalmask"] as? NSDictionary, mask as NSDictionary)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try data.write(to: url)
                    let process = Process(), pipe = Pipe()
                    process.executableURL = executable
                    process.arguments = ["run", "-test", "-config", url.path]
                    process.standardOutput = pipe; process.standardError = pipe
                    try process.run()
                    let output = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
                }
            }
        }
    }


    func testBundledXrayActuallyFragmentsTheClientHello() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for delay in ["1-2", "2-5"] {
            let config = try ConnectionLinkParser().parse(link(mask(delay: delay)))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: config, to: url)
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [root.appendingPathComponent("scripts/tests/xray_fragment.py").path,
                                 root.appendingPathComponent("teleport/Resources/xray").path, url.path]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        }
    }

}
