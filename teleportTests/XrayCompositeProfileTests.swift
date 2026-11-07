import Foundation
import XCTest

final class XrayCompositeProfileTests: XCTestCase {
    private func fixture(_ name: String = "balanced-ws") throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/subscriptions/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func parse(_ name: String = "balanced-ws") throws -> ConnectionConfiguration {
        try XraySubscriptionProfileParser().parseConfiguration(fixture(name))
    }

    private func proxyPayload(_ configuration: ConnectionConfiguration) throws -> [String: Any] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testGroupsSurviveCanonicalReparseCodableAndRename() throws {
        for name in ["balanced-ws", "balanced-xhttp", "balanced-xhttp-header"] {
            let config = try parse(name)
            XCTAssertEqual(config.composite?.members.count, 2)
            XCTAssertEqual(config.endpointConfigurations.map(\.host), ["proxy-0.example.test", "proxy-1.example.test"])
            XCTAssertEqual(try ConnectionLinkParser().parse(config.rawLink), config)
            XCTAssertEqual(try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(config)), config)
            let renamed = config.withDisplayName("My group")
            XCTAssertEqual(try ConnectionLinkParser().parse(renamed.rawLink), renamed)
            XCTAssertEqual(config.duplicateFilterIdentity, renamed.duplicateFilterIdentity)
            XCTAssertNotEqual(config.duplicateFilterIdentity, config.composite!.members[0].configuration.duplicateFilterIdentity)
        }
    }

    func testBalancerPreservesFallbackCostsAndObserverReferences() throws {
        let payload = try proxyPayload(parse())
        let outbounds = try XCTUnwrap(payload["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.filter { $0["protocol"] as? String == "vless" }.count, 2)
        let routing = try XCTUnwrap(payload["routing"] as? [String: Any])
        let balancer = try XCTUnwrap((routing["balancers"] as? [[String: Any]])?.first)
        XCTAssertEqual(balancer["tag"] as? String, "proxy")
        XCTAssertEqual(balancer["fallbackTag"] as? String, "proxy-member-1/")
        XCTAssertEqual(balancer["selector"] as? [String], ["proxy-member-0/", "proxy-member-1/"])
        let settings = (balancer["strategy"] as? [String: Any])?["settings"] as? [String: Any]
        let costs = settings?["costs"] as? [[String: Any]]
        XCTAssertEqual(costs?.first?["match"] as? String, "proxy-member-1/")
        XCTAssertEqual(costs?.first?["value"] as? Int, 10)
        XCTAssertEqual((payload["burstObservatory"] as? [String: Any])?["subjectSelector"] as? [String], balancer["selector"] as? [String])
        XCTAssertEqual((routing["rules"] as? [[String: Any]])?.first?["balancerTag"] as? String, "proxy")
        XCTAssertNil((routing["rules"] as? [[String: Any]])?.first?["outboundTag"])
    }

    func testTunnelPinsAllMembersAndKeepsGroupsSeparate() throws {
        let config = try parse()
        let firstID = UUID(), secondID = UUID()
        let resolved = try RoutedProxyOutbound.resolve(connectionID: firstID, configuration: config) { host in
            (host == "proxy-0.example.test" ? "192.0.2.1" : "192.0.2.2", "en0")
        }
        XCTAssertEqual(Set(resolved.outbound.memberAddresses.values), ["192.0.2.1", "192.0.2.2"])
        let second = RoutedProxyOutbound(connectionID: secondID, configuration: config, memberAddresses: resolved.outbound.memberAddresses)
        let rule = SplitTunnelRule(value: "example.org", kind: .domain, action: .proxy, connectionID: secondID)
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: [resolved.outbound, second], interfaceName: "utun99", outboundInterface: "en0", splitTunnelRules: [rule], dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"]))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(payload["outbounds"] as? [[String: Any]])
        let proxies = outbounds.filter { $0["protocol"] as? String == "vless" }
        XCTAssertEqual(proxies.count, 4)
        XCTAssertEqual(Set(proxies.compactMap { $0["tag"] as? String }).count, 4)
        for proxy in proxies {
            let stream = proxy["streamSettings"] as? [String: Any]
            XCTAssertEqual((stream?["sockopt"] as? [String: Any])?["interface"] as? String, "en0")
            let servers = (proxy["settings"] as? [String: Any])?["vnext"] as? [[String: Any]]
            XCTAssertTrue(["192.0.2.1", "192.0.2.2"].contains(servers?.first?["address"] as? String ?? ""))
        }
        let routing = try XCTUnwrap(payload["routing"] as? [String: Any])
        let rules = try XCTUnwrap(routing["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first { $0["domain"] as? [String] == ["domain:example.org"] }?["balancerTag"] as? String, "proxy-1")
        XCTAssertTrue(rules.contains { $0["inboundTag"] as? [String] == [XrayConfigurationWriter.dnsQueryTag] && $0["balancerTag"] as? String == "proxy" })
        let balancers = try XCTUnwrap(routing["balancers"] as? [[String: Any]])
        XCTAssertEqual(balancers[1]["selector"] as? [String], ["proxy-1-member-0/", "proxy-1-member-1/"])
        XCTAssertEqual((payload["burstObservatory"] as? [String: Any])?["subjectSelector"] as? [String], ["proxy-member-0/", "proxy-member-1/", "proxy-1-member-0/", "proxy-1-member-1/"])
    }

    func testXHTTPExtraReachesGeneratedConfigAndStandaloneReparse() throws {
        for name in ["balanced-xhttp", "balanced-xhttp-header"] {
            let config = try parse(name)
            let member = try XCTUnwrap(config.composite?.members.last?.configuration)
            XCTAssertNotNil(member.xhttpExtra)
            XCTAssertEqual(try ConnectionLinkParser().parse(member.rawLink), member)
            let payload = try proxyPayload(config)
            let proxies = try XCTUnwrap(payload["outbounds"] as? [[String: Any]])
            let stream = try XCTUnwrap(proxies.compactMap { $0["streamSettings"] as? [String: Any] }.first { $0["network"] as? String == "xhttp" })
            let extra = try XCTUnwrap((stream["xhttpSettings"] as? [String: Any])?["extra"] as? [String: Any])
            XCTAssertEqual(try XrayJSONObject(extra), member.xhttpExtra)
            if name.hasSuffix("header") {
                XCTAssertEqual(extra["uplinkHTTPMethod"] as? String, "GET")
                XCTAssertEqual(extra["uplinkDataPlacement"] as? String, "header")
            } else { XCTAssertNotNil(extra["xmux"]) }
        }
    }

    func testRejectsUnresolvedFallbackAndSelectiveProxyRouting() throws {
        var profile = try fixture()
        var routing = profile["routing"] as! [String: Any]
        var balancers = routing["balancers"] as! [[String: Any]]
        balancers[0]["fallbackTag"] = "absent"
        routing["balancers"] = balancers
        profile["routing"] = routing
        XCTAssertThrowsError(try XraySubscriptionProfileParser().parseConfiguration(profile))
        profile = try fixture()
        routing = profile["routing"] as! [String: Any]
        var rules = routing["rules"] as! [[String: Any]]
        rules.insert(["type": "field", "domain": ["example.test"], "outboundTag": "proxy-0"], at: 0)
        routing["rules"] = rules
        profile["routing"] = routing
        XCTAssertThrowsError(try XraySubscriptionProfileParser().parseConfiguration(profile))
    }

    func testRejectsUnsafeExtraAndMalformedNumericFields() throws {
        for extra: [String: Any] in [["downloadSettings": ["address": "other.example.test"]], ["xPaddingBytes": true], ["scMaxBufferedPosts": -1], ["unknown": 1], ["xmux": ["maxConnections": "5-2"]], ["xPaddingBytes": "0-100"], ["xmux": ["maxConnections": 2, "maxConcurrency": 4]]] {
            XCTAssertThrowsError(try XrayProfileValidation.xhttpExtra(extra, mode: "packet-up"))
        }
    }

    func testMuxSurvivesStandaloneImportAndBothWriters() throws {
        let member = try XCTUnwrap(parse().composite?.members.last?.configuration)
        XCTAssertEqual(try ConnectionLinkParser().parse(member.rawLink), member)
        XCTAssertEqual(member.outboundMux?.object["concurrency"] as? Int, 8)
        let local = try proxyPayload(member)
        let tunnelData = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: member, interfaceName: "utun99")
        let tunnel = try XCTUnwrap(JSONSerialization.jsonObject(with: tunnelData) as? [String: Any])
        for payload in [local, tunnel] {
            let proxy = try XCTUnwrap((payload["outbounds"] as? [[String: Any]])?.first)
            XCTAssertEqual(try XrayJSONObject(XCTUnwrap(proxy["mux"] as? [String: Any])), member.outboundMux)
        }
    }

    func testDifferentObserverSettingsCannotSilentlyOverrideEachOther() throws {
        var profile = try fixture()
        var observer = profile["burstObservatory"] as! [String: Any]
        var ping = observer["pingConfig"] as! [String: Any]
        ping["interval"] = "30s"
        observer["pingConfig"] = ping
        profile["burstObservatory"] = observer
        let other = try XraySubscriptionProfileParser().parseConfiguration(profile)
        let outbounds = [RoutedProxyOutbound(connectionID: UUID(), configuration: try parse()), RoutedProxyOutbound(connectionID: UUID(), configuration: other)]
        XCTAssertThrowsError(try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: outbounds, interfaceName: "utun99"))
    }

    func testImportDeduplicationKeepsAlternativeMembersAndRefreshIdentity() throws {
        let original = try fixture()
        var changed = original
        var outbounds = changed["outbounds"] as! [[String: Any]]
        var stream = outbounds[1]["streamSettings"] as! [String: Any]
        var ws = stream["wsSettings"] as! [String: Any]
        ws["path"] = "/other-transport"
        stream["wsSettings"] = ws
        outbounds[1]["streamSettings"] = stream
        changed["outbounds"] = outbounds
        let sourceID = UUID()
        let candidates = try SubscriptionPayloadDecoder().decode(JSONSerialization.data(withJSONObject: [original, changed, original]))
        let imported = try SubscriptionImportProcessor.importEntries(candidates: candidates, parser: ConnectionLinkParser(), sourceID: sourceID, filterDuplicateImports: true)
        XCTAssertEqual(imported.importedEntries.count, 2)
        XCTAssertEqual(imported.skippedCount, 0)
        let saved = imported.importedEntries.map { entry in
            SavedConnection(id: UUID(), configuration: entry.configuration, savedAt: Date(), source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: entry.sourceEntryID), customName: "My portal")
        }
        let refreshed = SubscriptionConnectionReconciler().reconcile(existingConnections: saved, sourceID: sourceID, selectedConnectionID: saved[0].id, importedEntries: imported.importedEntries, fetchedAt: Date(), autoSelectFirstImported: false)
        XCTAssertEqual(refreshed.selectedConnectionID, saved[0].id)
        XCTAssertEqual(refreshed.savedConnections, saved)
    }

    func testEndpointResolutionCannotOmitFailedMember() throws {
        var hosts: [String] = []
        XCTAssertThrowsError(try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: parse()) { host in
            hosts.append(host)
            if hosts.count == 2 { throw XrayProfileValidation.reject("test resolution") }
            return ("192.0.2.1", "en0")
        })
        XCTAssertEqual(hosts, ["proxy-0.example.test", "proxy-1.example.test"])
    }

    func testUnavailableFallbackDoesNotPreventUsingReachableGroupMember() throws {
        let config = try parse()
        let resolved = try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: config) { host in
            if host == "proxy-1.example.test" { throw XrayTunConnectionError.proxyRouteUnavailable(host) }
            return ("192.0.2.1", "en0")
        }
        XCTAssertEqual(resolved.outbound.configuration, config, "Network availability must not edit the saved profile")
        XCTAssertEqual(resolved.outbound.memberAddresses, ["proxy-0.example.test": "192.0.2.1"])
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: [resolved.outbound], interfaceName: "utun99", outboundInterface: "en0")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proxies = (json["outbounds"] as? [[String: Any]])?.filter { $0["protocol"] as? String == "vless" }
        XCTAssertEqual(proxies?.count, 1)
        let routing = json["routing"] as? [String: Any]
        let balancer = try XCTUnwrap((routing?["balancers"] as? [[String: Any]])?.first)
        XCTAssertEqual(balancer["selector"] as? [String], ["proxy-member-0/"])
        XCTAssertEqual(balancer["fallbackTag"] as? String, "proxy-member-0/")
        XCTAssertEqual((json["burstObservatory"] as? [String: Any])?["subjectSelector"] as? [String], ["proxy-member-0/"])
    }

    func testGroupReportsAggregateDNSAndIPv6Failures() throws {
        XCTAssertThrowsError(try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: parse()) { host in
            if host == "proxy-0.example.test" { throw XrayTunConnectionError.proxyAddressResolutionFailed(host) }
            throw XrayTunConnectionError.proxyIPv6RouteUnavailable(host)
        }) { error in
            guard case let .noReachableGroupMembers(dns, ipv6, route) = error as? XrayTunConnectionError else {
                return XCTFail("Expected group diagnosis, got \(error)")
            }
            XCTAssertEqual(dns, 1)
            XCTAssertEqual(ipv6, 1)
            XCTAssertEqual(route, 0)
            let failure = ConnectionFailure(error: error)
            XCTAssertTrue(failure.summary.hasPrefix("No eligible server in this group"))
            XCTAssertTrue(failure.details?.contains("IPv6") == true)
        }
    }

    func testIPv6OnlyMemberCanBeExcludedAndReconsideredNextTime() throws {
        let config = try parse()
        let first = try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: config) { host in
            if host == "proxy-0.example.test" { throw XrayTunConnectionError.proxyIPv6RouteUnavailable(host) }
            return ("192.0.2.2", "en0")
        }
        XCTAssertEqual(first.outbound.unavailableMemberHosts, ["proxy-0.example.test"])
        let second = try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: first.outbound.configuration) { host in
            (host == "proxy-0.example.test" ? "2001:db8::1" : "192.0.2.2", "en0")
        }
        XCTAssertTrue(second.outbound.unavailableMemberHosts.isEmpty)
        XCTAssertEqual(second.outbound.memberAddresses.count, 2)
    }

    func testAllUnavailableMembersAndStandaloneStillFail() throws {
        let group = try parse()
        for configuration in [group, try XCTUnwrap(group.composite?.members.first?.configuration)] {
            XCTAssertThrowsError(try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: configuration) { host in
                throw XrayTunConnectionError.proxyAddressResolutionFailed(host)
            })
        }
    }

    func testUnavailableSelectedMemberCanUseOnlyItsExplicitFallback() throws {
        var profile = try fixture()
        var routing = profile["routing"] as! [String: Any]
        var balancers = routing["balancers"] as! [[String: Any]]
        balancers[0]["selector"] = ["proxy-0"]
        routing["balancers"] = balancers
        profile["routing"] = routing
        let config = try XraySubscriptionProfileParser().parseConfiguration(profile)
        let resolved = try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: config) { host in
            if host == "proxy-0.example.test" { throw XrayTunConnectionError.proxyAddressResolutionFailed(host) }
            return ("192.0.2.2", "en0")
        }
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: [resolved.outbound], interfaceName: "utun99")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let generated = (json["routing"] as? [String: Any])?["balancers"] as? [[String: Any]]
        XCTAssertEqual(generated?.first?["selector"] as? [String], ["proxy-member-1/"])

        // A reachable outbound outside both selector and fallback is not an
        // authorized substitute for the provider's selected members.
        balancers[0]["fallbackTag"] = "proxy-0"
        routing["balancers"] = balancers
        profile["routing"] = routing
        let noFallback = try XraySubscriptionProfileParser().parseConfiguration(profile)
        XCTAssertThrowsError(try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: noFallback) { host in
            if host == "proxy-0.example.test" { throw XrayTunConnectionError.proxyAddressResolutionFailed(host) }
            return ("192.0.2.2", "en0")
        })
        XCTAssertThrowsError(try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: noFallback) { host in
            if host == "proxy-0.example.test" { throw XrayTunConnectionError.proxyAddressResolutionFailed(host) }
            throw XrayTunConnectionError.proxyIPv6RouteUnavailable(host)
        }) { error in
            // The unselected member's IPv6 failure must not obscure the
            // selected/fallback member's DNS failure.
            guard case let .noReachableGroupMembers(dns, ipv6, route) = error as? XrayTunConnectionError else {
                return XCTFail("Expected group diagnosis, got \(error)")
            }
            XCTAssertEqual(dns, 1)
            XCTAssertEqual(ipv6, 0)
            XCTAssertEqual(route, 0)
        }
    }

    func testLiteralRegexCostsAreExpandedWithoutChangingMatches() throws {
        var profile = try fixture()
        var routing = profile["routing"] as! [String: Any]
        var balancers = routing["balancers"] as! [[String: Any]]
        var strategy = balancers[0]["strategy"] as! [String: Any]
        var settings = strategy["settings"] as! [String: Any]
        settings["costs"] = [["regexp": true, "match": "-1", "value": 3], ["regexp": true, "match": "bypass", "value": 5]]
        strategy["settings"] = settings
        balancers[0]["strategy"] = strategy
        routing["balancers"] = balancers
        profile["routing"] = routing
        let config = try XraySubscriptionProfileParser().parseConfiguration(profile)
        XCTAssertEqual(try ConnectionLinkParser().parse(config.rawLink), config)
        let payload = try proxyPayload(config)
        let emitted = ((payload["routing"] as? [String: Any])?["balancers"] as? [[String: Any]])?.first
        let costs = ((emitted?["strategy"] as? [String: Any])?["settings"] as? [String: Any])?["costs"] as? [[String: Any]]
        XCTAssertEqual(costs?.count, 1)
        XCTAssertEqual(costs?.first?["match"] as? String, "proxy-member-1/")
        XCTAssertEqual(costs?.first?["value"] as? Int, 3)
    }

    private actor FailingSecondExemption: ProbeUplinkExemption {
        var hosts: [String] = []
        var closed: [String] = []
        let failure: ProbeUplinkExemptionOutcome
        init(failure: ProbeUplinkExemptionOutcome) { self.failure = failure }
        func open(host: String) async -> ProbeUplinkExemptionOutcome {
            hosts.append(host)
            return hosts.count == 1 ? .opened(["192.0.2.1"]) : failure
        }
        func close(_ addresses: [String]) async { closed.append(contentsOf: addresses) }
    }

    func testHealthProbeClosesEarlierExemptionsWhenAMemberCannotResolve() async throws {
        for failure in [ProbeUplinkExemptionOutcome.couldNotResolve, .unavailable] {
            let exemption = FailingSecondExemption(failure: failure)
            let service = ConnectionHealthProbeService(uplinkExemption: exemption)
            let result = await service.probe(SavedConnection(id: UUID(), configuration: try parse(), savedAt: Date()))
            XCTAssertEqual(result.state, .unknown)
            let hosts = await exemption.hosts, closed = await exemption.closed
            XCTAssertEqual(hosts, ["proxy-0.example.test", "proxy-1.example.test"])
            XCTAssertEqual(closed, ["192.0.2.1"])
        }
    }

    func testSharingHysteriaLedGroupKeepsEveryMember() throws {
        let single = try ConnectionLinkParser().parse("hy2://test-password@hy.example.test:443")
        XCTAssertNotNil(single.hysteriaShareLink)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(single.rawLink.utf8)) as? [String: Any])
        var outbound = (raw["outbounds"] as! [[String: Any]])[0]
        outbound["tag"] = "proxy-0"
        var profile = try fixture()
        var outbounds = profile["outbounds"] as! [[String: Any]]
        outbounds[0] = outbound
        profile["outbounds"] = outbounds
        let config = try XraySubscriptionProfileParser().parseConfiguration(profile)
        XCTAssertNil(config.hysteriaShareLink)
        XCTAssertNotNil(config.shareExportNote)
        let saved = SavedConnection(id: UUID(), configuration: config, savedAt: Date(), customName: "My group")
        XCTAssertEqual(try ConnectionLinkParser().parse(saved.shareableLink), config.withDisplayName("My group"))
    }

    func testBundledXrayAcceptsAllFixtureConfigs() throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("teleport/Resources/xray")
        for name in ["balanced-ws", "balanced-xhttp", "balanced-xhttp-header"] {
            let config = try parse(name)
            let payload = try proxyPayload(config)
            let tunnel = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(for: [RoutedProxyOutbound(connectionID: UUID(), configuration: config), RoutedProxyOutbound(connectionID: UUID(), configuration: config)], interfaceName: "utun99")
            let prepared = try RoutedProxyOutbound.resolve(connectionID: UUID(), configuration: config) { host in
                if host == "proxy-1.example.test" { throw XrayTunConnectionError.proxyRouteUnavailable(host) }
                return ("192.0.2.1", "en0")
            }
            let partialTunnel = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
                for: [prepared.outbound], interfaceName: "utun99", outboundInterface: "en0")
            for data in [try JSONSerialization.data(withJSONObject: payload), tunnel, partialTunnel] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: url) }
                try data.write(to: url)
                let process = Process(), pipe = Pipe()
                process.executableURL = executable
                process.arguments = ["run", "-test", "-config", url.path]
                process.standardOutput = pipe; process.standardError = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "\(name): \(String(decoding: output, as: UTF8.self))")
            }
        }
    }
}
