import Foundation
import XCTest

final class SplitTunnelingTests: XCTestCase {
    func testClassifiesValidDomainAndIPValues() throws {
        try expectClassified("example.com", kind: .domain)
        try expectClassified("full:example.com", kind: .domain)
        try expectClassified("sub.example.co.uk", kind: .domain)
        try expectClassified("1.2.3.4", kind: .ip)
        try expectClassified("1.2.3.0/24", kind: .ip)
        try expectClassified("::1", kind: .ip)
        try expectClassified("2001:db8::/32", kind: .ip)
    }

    private func expectClassified(_ value: String, kind: SplitTunnelRuleKind) throws {
        switch SplitTunnelRuleClassifier.classify(value) {
        case let .success(classified):
            XCTAssert(classified.kind == kind, "\(value) expected \(kind) but got \(classified.kind)")
        case .failure:
            XCTFail("\(value) expected to classify as \(kind) but was rejected")
        }
    }

    func testRejectsInvalidValues() throws {
        for invalid in ["", "   ", "-example.com", "example..com", "1.2.3.4/99", "not a domain", "example.com/24"] {
            switch SplitTunnelRuleClassifier.classify(invalid) {
            case .success:
                XCTFail("expected \"\(invalid)\" to be rejected")
            case .failure:
                break
            }
        }
    }

    func testMatcherFirstMatchWinsWithOverlappingRules() throws {
        let broad = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        let specific = SplitTunnelRule(value: "full:api.example.com", kind: .domain, action: .block)
        let rules = [broad, specific]

        let match = SplitTunnelRuleMatcher.firstMatch(for: "api.example.com", in: rules)
        XCTAssert(match?.id == broad.id, "expected first matching rule in saved order to win")

        let reordered = [specific, broad]
        let reorderedMatch = SplitTunnelRuleMatcher.firstMatch(for: "api.example.com", in: reordered)
        XCTAssert(reorderedMatch?.id == specific.id, "expected order change to change which rule wins")
    }

    func testMatcherIgnoresDisabledRules() throws {
        let disabled = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct, isEnabled: false)
        let match = SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [disabled])
        XCTAssert(match == nil, "expected disabled rule to have no effect")
    }

    func testMatcherDomainRulesDoNotMatchIPLiterals() throws {
        let rule = SplitTunnelRule(value: "1.2.3.4", kind: .domain, action: .direct)
        let match = SplitTunnelRuleMatcher.firstMatch(for: "1.2.3.4", in: [rule])
        XCTAssert(match == nil, "expected domain-kind rule to not match an IP literal candidate")
    }

    func testMatcherFullPrefixRequiresExactMatch() throws {
        let exact = SplitTunnelRule(value: "full:example.com", kind: .domain, action: .direct)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [exact]) != nil)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [exact]) == nil)

        let broad = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [broad]) != nil)
    }

    func testMatcherSupportsNonOctetCIDRPrefixes() throws {
        let ipv4 = SplitTunnelRule(value: "192.168.1.16/28", kind: .ip, action: .direct)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "192.168.1.17", in: [ipv4])?.id == ipv4.id)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "192.168.1.32", in: [ipv4]) == nil)

        let ipv6 = SplitTunnelRule(value: "2001:db8::/127", kind: .ip, action: .direct)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "2001:db8::1", in: [ipv6])?.id == ipv6.id)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "2001:db8::2", in: [ipv6]) == nil)
    }

    func testDomainValuesAreNormalizedToLowercase() throws {
        switch SplitTunnelRuleClassifier.classify("Example.COM") {
        case let .success(classified):
            XCTAssert(classified.kind == .domain)
            XCTAssert(classified.value == "example.com", "expected domain value to be stored lowercased")
        case .failure:
            XCTFail("expected mixed-case domain to classify successfully")
        }

        // A rule stored from mixed-case input must still match a lowercase candidate,
        // matching how Xray sees sniffed SNI/Host names.
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "API.Example.com", in: [rule]) != nil)
    }

    func testClassifiesGeodataTokens() throws {
        try expectClassified("geosite:google", kind: .geosite)
        try expectClassified("geosite:category-ads-all", kind: .geosite)
        try expectClassified("geosite:google@ads", kind: .geosite)
        try expectClassified("geoip:private", kind: .geoip)
        try expectClassified("geoip:cn", kind: .geoip)

        switch SplitTunnelRuleClassifier.classify("GeoSite:Google") {
        case let .success(classified):
            XCTAssert(classified.kind == .geosite)
            XCTAssert(classified.value == "geosite:google", "expected geosite token to be normalized to lowercase")
        case .failure:
            XCTFail("expected mixed-case geosite token to classify successfully")
        }

        switch SplitTunnelRuleClassifier.classify("GeoIP:Private") {
        case let .success(classified):
            XCTAssert(classified.kind == .geoip)
            XCTAssert(classified.value == "geoip:private", "expected geoip token to be normalized to lowercase")
        case .failure:
            XCTFail("expected mixed-case geoip token to classify successfully")
        }

        for invalid in ["geosite:", "geosite:@ads", "geosite:.foo", "geosite:a b", "geoip:", "geoip:@cn", "geoip:.private", "geoip:a b"] {
            switch SplitTunnelRuleClassifier.classify(invalid) {
            case .success:
                XCTFail("expected \"\(invalid)\" to be rejected")
            case .failure:
                break
            }
        }
    }

    func testMatcherChecksGeodataRules() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("teleport-geodata-test-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let fileManager = TemporaryApplicationSupportFileManager(rootURL: temporaryRoot)
        let service = GeodataUpdateService(fileManager: fileManager)
        try service.store(sampleGeositeData(), for: .geosite)
        try service.store(sampleGeoIPData(), for: .geoip)
        let geodataMatcher = SplitTunnelGeodataMatcher(service: service)
        try geodataMatcher.prepareSynchronously()

        let geosite = SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct)
        let geoip = SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .block)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [geosite], geodataMatcher: geodataMatcher)?.id == geosite.id)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "10.15.255.255", in: [geoip], geodataMatcher: geodataMatcher)?.id == geoip.id)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "10.16.0.0", in: [geoip], geodataMatcher: geodataMatcher) == nil)

        let disabled = SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct, isEnabled: false)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [disabled], geodataMatcher: geodataMatcher) == nil)

        // A domain rule sitting after a non-matching geodata-backed rule is still matched normally.
        let domain = SplitTunnelRule(value: "example.com", kind: .domain, action: .block)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [geosite, domain], geodataMatcher: geodataMatcher)?.id == domain.id)

        let attrRule = SplitTunnelRule(value: "geosite:google@ads", kind: .geosite, action: .block)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "ads.google.com", in: [attrRule], geodataMatcher: geodataMatcher)?.id == attrRule.id)
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [attrRule], geodataMatcher: geodataMatcher) == nil)
    }

    func testGeodataRulesGenerateRoutingRules() throws {
        let rules = [
            SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct),
            SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .block)
        ]
        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        XCTAssert(routingRules.count == 2)
        let domains = routingRules[0]["domain"] as? [String]
        XCTAssert(domains == ["geosite:google"], "expected geosite token to be emitted in the domain array")
        XCTAssert(routingRules[0]["outboundTag"] as? String == "direct")
        let ips = routingRules[1]["ip"] as? [String]
        XCTAssert(ips == ["geoip:private"], "expected geoip token to be emitted in the ip array")
        XCTAssert(routingRules[1]["outboundTag"] as? String == "block")
    }

    func testDomainRulesUseSniffingWithoutDNSInterception() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy),
            SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .block),
            SplitTunnelRule(value: "direct.example", kind: .domain, action: .direct)
        ]
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            splitTunnelRules: rules,
            defaultAction: .direct
        )
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Domain rules are matched from sniffed SNI/Host only. No FakeDNS, no DNS
        // section, and no DNS capture: Xray must never resolve anything itself.
        XCTAssert(payload?["dns"] == nil, "without a DNS policy the tunnel config must not carry a dns section")
        XCTAssert(payload?["fakedns"] == nil, "tunnel config must not enable FakeDNS")
        let outbounds = payload?["outbounds"] as? [[String: Any]] ?? []
        XCTAssert(!outbounds.contains { $0["protocol"] as? String == "dns" }, "no dns outbound expected")
        let routingRules = try routingRulesArray(from: data)
        XCTAssert(!routingRules.contains { $0["port"] as? Int == 53 }, "no DNS capture rule expected")

        let inbounds = payload?["inbounds"] as? [[String: Any]]
        let tun = inbounds?.first { $0["tag"] as? String == "tun" }
        let sniffing = tun?["sniffing"] as? [String: Any]
        XCTAssert(sniffing?["enabled"] as? Bool == true)
        XCTAssert(sniffing?["routeOnly"] as? Bool == true, "without Xray-owned DNS the sniffed domain must only steer routing")
        XCTAssert(sniffing?["destOverride"] as? [String] == ["http", "tls", "quic"])
        let directWithoutDNS = outbounds.first { $0["tag"] as? String == "direct" }
        XCTAssert((directWithoutDNS?["settings"] as? [String: Any])?["domainStrategy"] == nil)

        // With Xray-owned DNS the sniffed domain replaces the destination so the proxy
        // resolves remotely, and freedom resolves through Xray's module, never the OS.
        let ownedData = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration, interfaceName: "utun9", outboundInterface: "en0",
            splitTunnelRules: rules, defaultAction: .direct,
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"])
        )
        let owned = try JSONSerialization.jsonObject(with: ownedData) as? [String: Any]
        let ownedTun = (owned?["inbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "tun" }
        XCTAssert((ownedTun?["sniffing"] as? [String: Any])?["routeOnly"] as? Bool == false)
        let ownedDirect = (owned?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "direct" }
        XCTAssert((ownedDirect?["settings"] as? [String: Any])?["domainStrategy"] as? String == "UseIP")

        // The default action outbound must be first so Xray's implicit fallback agrees
        // with the explicit catch-all rule.
        XCTAssert(outbounds.first?["tag"] as? String == "direct")
    }

    func testDNSModuleOwnsResolution() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy),
            SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .block),
            SplitTunnelRule(value: "direct.example", kind: .domain, action: .direct)
        ]
        // Scoped and malformed resolver entries must be dropped, duplicates collapsed.
        let policy = TunnelDNSPolicy(localResolvers: ["192.0.2.53", "fe80::1%en0", "192.0.2.53", "garbage"])

        func payload(defaultAction: SplitTunnelRuleAction) throws -> [String: Any] {
            let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
                for: configuration,
                interfaceName: "utun9",
                outboundInterface: "en0",
                splitTunnelRules: rules,
                defaultAction: defaultAction,
                dnsPolicy: policy
            )
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }

        let direct = try payload(defaultAction: .direct)
        let directDNS = direct["dns"] as? [String: Any]
        XCTAssert(directDNS?["tag"] as? String == "dns-internal")
        let directServers = directDNS?["servers"] as? [Any] ?? []
        XCTAssert(directServers.count == 2, "one local resolver plus the remote resolver, got \(directServers.count)")
        XCTAssert(directServers[0] as? String == "192.0.2.53", "default direct: unmatched names resolve locally")
        let remote = directServers[1] as? [String: Any]
        XCTAssert(remote?["address"] as? String == TunnelDNSPolicy.defaultRemoteResolver)
        XCTAssert(remote?["domains"] as? [String] == ["domain:example.com"], "proxy domains resolve remotely")
        XCTAssert(remote?["skipFallback"] as? Bool == true)

        let proxy = try payload(defaultAction: .proxy)
        let proxyServers = (proxy["dns"] as? [String: Any])?["servers"] as? [Any] ?? []
        XCTAssert(proxyServers[0] as? String == TunnelDNSPolicy.defaultRemoteResolver, "default proxy: unmatched names resolve remotely")
        let local = proxyServers[1] as? [String: Any]
        XCTAssert(local?["address"] as? String == "192.0.2.53")
        XCTAssert(local?["domains"] as? [String] == ["domain:direct.example"], "direct domains resolve locally")

        let outbounds = direct["outbounds"] as? [[String: Any]] ?? []
        XCTAssert(outbounds.contains { $0["tag"] as? String == "dns-out" && $0["protocol"] as? String == "dns" })
        let routingRules = ((direct["routing"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        guard let hijackIndex = routingRules.firstIndex(where: { $0["outboundTag"] as? String == "dns-out" }) else {
            XCTFail("expected the TUN port 53 hijack rule")
            return
        }
        XCTAssert(routingRules[hijackIndex]["port"] as? Int == 53)
        XCTAssert(routingRules[hijackIndex]["inboundTag"] as? [String] == ["tun"])
        let internalRules = routingRules.filter { $0["inboundTag"] as? [String] == ["dns-internal"] }
        XCTAssert(internalRules.count == 2, "local resolvers go direct, everything else through the proxy")
        XCTAssert(internalRules[0]["ip"] as? [String] == ["192.0.2.53"] && internalRules[0]["outboundTag"] as? String == "direct")
        XCTAssert(internalRules[1]["ip"] == nil && internalRules[1]["outboundTag"] as? String == "proxy")
        XCTAssert(hijackIndex < routingRules.firstIndex { $0["domain"] != nil }!, "DNS rules must precede split rules")

        // No usable local resolver: everything resolves remotely rather than failing.
        let orphan = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration, interfaceName: "utun9", outboundInterface: "en0",
            splitTunnelRules: rules, defaultAction: .direct,
            dnsPolicy: TunnelDNSPolicy(localResolvers: [])
        )
        let orphanServers = (((try JSONSerialization.jsonObject(with: orphan) as? [String: Any])?["dns"] as? [String: Any])?["servers"] as? [Any]) ?? []
        XCTAssert(orphanServers.count == 1 && orphanServers[0] as? String == TunnelDNSPolicy.defaultRemoteResolver)
    }

    func testSplitRoutingConfigurationIsAcceptedByBundledXray() throws {
        let xrayURL = repositoryRoot.appendingPathComponent("teleport/Resources/xray")
        XCTAssert(FileManager.default.isExecutableFile(atPath: xrayURL.path), "teleport/Resources/xray is missing; run just fetch-xray")

        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            splitTunnelRules: [
                SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy),
                SplitTunnelRule(value: "blocked.example", kind: .domain, action: .block)
            ],
            defaultAction: .direct,
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53", "2001:db8::53"], ipv6Enabled: false)
        )
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-split-routing-\(UUID().uuidString).json")
        try data.write(to: configURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let process = Process()
        let errors = Pipe()
        process.executableURL = xrayURL
        process.arguments = ["run", "-test", "-c", configURL.path]
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssert(process.terminationStatus == 0, "bundled Xray rejected split routing config: \(errorText)")
    }

    /// A session may carry several connections at once: each becomes its own
    /// tagged outbound and rules name the connection they leave through.
    func testSeveralConnectionsBecomeTaggedOutbounds() throws {
        let parser = ConnectionLinkParser()
        let defaultConnectionID = UUID()
        let secondConnectionID = UUID()
        let unknownConnectionID = UUID()
        let outbounds = [
            RoutedProxyOutbound(
                connectionID: defaultConnectionID,
                configuration: try parser.parse(sampleVLESSLink()),
                serverAddress: "203.0.113.7"
            ),
            RoutedProxyOutbound(
                connectionID: secondConnectionID,
                configuration: try parser.parse(sampleWireGuardConfigurationFile()),
                serverAddress: "198.51.100.9"
            )
        ]
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: outbounds,
            interfaceName: "utun9",
            outboundInterface: "en0",
            splitTunnelRules: [
                SplitTunnelRule(value: "wg.example", kind: .domain, action: .proxy, connectionID: secondConnectionID),
                SplitTunnelRule(value: "default.example", kind: .domain, action: .proxy),
                SplitTunnelRule(value: "gone.example", kind: .domain, action: .proxy, connectionID: unknownConnectionID),
                // A connection id on a non-proxy rule must not change its outbound.
                SplitTunnelRule(value: "direct.example", kind: .domain, action: .direct, connectionID: secondConnectionID)
            ],
            defaultAction: .proxy,
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"], ipv6Enabled: false)
        )
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let generatedOutbounds = payload?["outbounds"] as? [[String: Any]] ?? []
        let tags = generatedOutbounds.compactMap { $0["tag"] as? String }
        // The default connection keeps the `proxy` tag every existing rule, the
        // local inbounds and the catch-all already point at.
        XCTAssert(tags.first == "proxy", "expected the default connection to keep the proxy tag")
        XCTAssert(tags.contains("proxy-1"), "expected the second connection to get its own tag")
        XCTAssert(Set(tags).count == tags.count, "expected unique outbound tags")

        let defaultOutbound = generatedOutbounds.first { $0["tag"] as? String == "proxy" }
        let secondOutbound = generatedOutbounds.first { $0["tag"] as? String == "proxy-1" }
        XCTAssert(defaultOutbound?["protocol"] as? String == "vless")
        XCTAssert(secondOutbound?["protocol"] as? String == "wireguard")
        // Each outbound dials the address its own protected host route was
        // installed for, not the other connection's.
        let vnext = ((defaultOutbound?["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first
        XCTAssert(vnext?["address"] as? String == "203.0.113.7")
        let peer = ((secondOutbound?["settings"] as? [String: Any])?["peers"] as? [[String: Any]])?.first
        XCTAssert(peer?["endpoint"] as? String == "198.51.100.9:51820")
        // Both transports must leave through the uplink, not the TUN they feed.
        for outbound in [defaultOutbound, secondOutbound] {
            let sockopt = (outbound?["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
            XCTAssert(sockopt?["interface"] as? String == "en0", "expected every proxy outbound bound to the uplink")
        }

        let rules = ((payload?["routing"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        func outboundTag(forDomain domain: String) -> String? {
            rules.first { ($0["domain"] as? [String])?.contains("domain:" + domain) == true }?["outboundTag"] as? String
        }
        XCTAssert(outboundTag(forDomain: "wg.example") == "proxy-1")
        XCTAssert(outboundTag(forDomain: "default.example") == "proxy")
        // A rule pointing at a connection this session does not carry falls back to
        // the default outbound instead of being dropped.
        XCTAssert(outboundTag(forDomain: "gone.example") == "proxy")
        XCTAssert(outboundTag(forDomain: "direct.example") == "direct")

        // Local inbounds and DNS resolution stay on the default connection.
        let localProxyRule = rules.first { ($0["inboundTag"] as? [String])?.contains("socks-in") == true }
        XCTAssert(localProxyRule?["outboundTag"] as? String == "proxy")
        let dnsQueryRule = rules.last { ($0["inboundTag"] as? [String])?.contains("dns-internal") == true }
        XCTAssert(dnsQueryRule?["outboundTag"] as? String == "proxy")

        try assertAcceptedByBundledXray(data)
    }

    /// A peer's resolvers usually live inside its own network: they must be
    /// queried through that peer's outbound and only for the names routed there,
    /// otherwise an internal zone either leaks to a public resolver or cannot be
    /// resolved at all.
    func testConnectionResolversAnswerForTheirOwnRoutedNames() throws {
        let parser = ConnectionLinkParser()
        let privateConnectionID = UUID()
        let outbounds = [
            RoutedProxyOutbound(
                connectionID: UUID(),
                configuration: try parser.parse(sampleVLESSLink()),
                serverAddress: "203.0.113.7"
            ),
            RoutedProxyOutbound(
                connectionID: privateConnectionID,
                configuration: try parser.parse(sampleWireGuardConfigurationFile(dnsServers: "10.72.0.53")),
                serverAddress: "198.51.100.9"
            )
        ]
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: outbounds,
            interfaceName: "utun9",
            outboundInterface: "en0",
            splitTunnelRules: [
                SplitTunnelRule(value: "internal.example", kind: .domain, action: .proxy, connectionID: privateConnectionID),
                SplitTunnelRule(value: "10.72.0.0/16", kind: .ip, action: .proxy, connectionID: privateConnectionID)
            ],
            defaultAction: .proxy,
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"], ipv6Enabled: false)
        )
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let servers = (payload?["dns"] as? [String: Any])?["servers"] as? [Any] ?? []
        guard let firstServer = servers.first as? [String: Any] else {
            XCTFail("expected the peer's resolver to be consulted first")
            return
        }
        XCTAssert(firstServer["address"] as? String == "10.72.0.53")
        // Only the names routed through that connection, and never as a fallback
        // for anything else.
        XCTAssert(firstServer["domains"] as? [String] == ["domain:internal.example"])
        XCTAssert(firstServer["skipFallback"] as? Bool == true)

        let rules = ((payload?["routing"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        let resolverRule = rules.first {
            ($0["inboundTag"] as? [String])?.contains("dns-internal") == true
                && ($0["ip"] as? [String]) == ["10.72.0.53"]
        }
        XCTAssert(resolverRule?["outboundTag"] as? String == "proxy-1",
                     "expected queries to the peer's resolver to leave through that peer's outbound")
        // The catch-all for other names still goes to the default connection.
        let fallbackRule = rules.last { ($0["inboundTag"] as? [String])?.contains("dns-internal") == true }
        XCTAssert(fallbackRule?["outboundTag"] as? String == "proxy")

        // A connection whose resolvers no rule needs adds nothing to the module.
        let unusedData = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: outbounds,
            interfaceName: "utun9",
            outboundInterface: "en0",
            splitTunnelRules: [],
            defaultAction: .proxy,
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"], ipv6Enabled: false)
        )
        let unusedPayload = try JSONSerialization.jsonObject(with: unusedData) as? [String: Any]
        let unusedServers = (unusedPayload?["dns"] as? [String: Any])?["servers"] as? [Any] ?? []
        XCTAssert(!unusedServers.contains { ($0 as? [String: Any])?["address"] as? String == "10.72.0.53" })

        try assertAcceptedByBundledXray(data)
    }

    private func sampleWireGuardConfigurationFile(dnsServers: String? = nil) -> String {
        let dnsLine = dnsServers.map { "DNS = \($0)\n" } ?? ""
        return """
        [Interface]
        PrivateKey = cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM=
        Address = 172.16.0.2/32
        \(dnsLine)
        [Peer]
        PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
        AllowedIPs = 0.0.0.0/0
        Endpoint = wg.example:51820
        """
    }

    private func assertAcceptedByBundledXray(_ data: Data) throws {
        let xrayURL = repositoryRoot.appendingPathComponent("teleport/Resources/xray")
        XCTAssert(FileManager.default.isExecutableFile(atPath: xrayURL.path), "teleport/Resources/xray is missing; run just fetch-xray")

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-multi-outbound-\(UUID().uuidString).json")
        try data.write(to: configURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let process = Process()
        let errors = Pipe()
        process.executableURL = xrayURL
        process.arguments = ["run", "-test", "-c", configURL.path]
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssert(process.terminationStatus == 0, "bundled Xray rejected the generated config: \(errorText)")
    }

    func testDomainRuleEmitsDomainPrefixNotSubstring() throws {
        // A bare domain must be emitted with Xray's `domain:` prefix so Xray uses
        // subdomain matching (matching the shared tester's suffix semantics) rather
        // than substring matching, which would also hit hosts like `notexample.com`.
        let bare = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        let bareRoutingRules = try generatedSplitTunnelRoutingRules(for: [bare])
        XCTAssert(bareRoutingRules.count == 1)
        XCTAssert(bareRoutingRules[0]["domain"] as? [String] == ["domain:example.com"],
                     "expected a bare domain to be emitted with the domain: prefix")

        // A `full:`-prefixed exact rule already carries Xray's own exact-match
        // prefix and must pass through unchanged (no double prefixing).
        let exact = SplitTunnelRule(value: "full:api.example.com", kind: .domain, action: .block)
        let exactRoutingRules = try generatedSplitTunnelRoutingRules(for: [exact])
        XCTAssert(exactRoutingRules[0]["domain"] as? [String] == ["full:api.example.com"],
                     "expected a full: rule to be emitted unchanged")

        // Lock in the tester semantics the emitted prefix is meant to agree with:
        // subdomains match, unrelated substrings do not.
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [bare])?.id == bare.id,
                     "expected a subdomain to match the bare domain rule")
        XCTAssert(SplitTunnelRuleMatcher.firstMatch(for: "notexample.com", in: [bare]) == nil,
                     "expected a substring-only host to NOT match the bare domain rule")
    }

    func testGeneratedRoutingRulesMatchSharedMatcher() throws {
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .direct),
            SplitTunnelRule(value: "10.0.0.0/8", kind: .ip, action: .block),
            SplitTunnelRule(value: "full:api.internal.com", kind: .domain, action: .proxy),
            SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .direct)
        ]

        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        XCTAssert(routingRules.count == rules.count, "expected one routing rule per split-tunnel rule")

        for (rule, routingRule) in zip(rules, routingRules) {
            let outboundTag = routingRule["outboundTag"] as? String
            XCTAssert(outboundTag == rule.action.rawValue, "expected outboundTag \(rule.action.rawValue) but got \(outboundTag ?? "nil")")

            switch rule.kind {
            case .domain:
                // A bare domain is emitted with Xray's `domain:` prefix so its
                // subdomain semantics match the shared tester's suffix match; a
                // `full:` value already carries Xray's exact-match prefix.
                let domains = routingRule["domain"] as? [String]
                let expected = rule.value.hasPrefix("full:") ? rule.value : "domain:" + rule.value
                XCTAssert(domains == [expected], "expected domain field to carry \(expected)")
            case .geosite:
                let domains = routingRule["domain"] as? [String]
                XCTAssert(domains == [rule.value], "expected geosite token to be emitted as-is")
            case .ip, .geoip:
                let ips = routingRule["ip"] as? [String]
                XCTAssert(ips == [rule.value], "expected ip field to carry rule value as-is")
            }
        }
    }

    func testDisabledRuleExcludedFromGeneratedRouting() throws {
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .direct, isEnabled: true),
            SplitTunnelRule(value: "disabled.com", kind: .domain, action: .direct, isEnabled: false)
        ]
        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        XCTAssert(routingRules.count == 1, "expected disabled rule to be excluded from generated routing rules")
    }

    func testEmptyRuleListProducesNoSplitTunnelRouting() throws {
        let routingRules = try generatedSplitTunnelRoutingRules(for: [])
        XCTAssert(routingRules.isEmpty, "expected no split-tunnel routing rules when the rule list is empty")
    }

    func testLegacySnapshotWithoutSplitTunnelFieldsDefaults() throws {
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 }
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssert(decoded.splitTunnelProfiles.count == 1, "expected a default profile when none was ever saved")
        XCTAssert(decoded.splitTunnelProfiles[0].rules.isEmpty, "expected the default profile to start with no rules")
        XCTAssert(decoded.selectedSplitTunnelProfileID == decoded.splitTunnelProfiles[0].id)
        XCTAssert(decoded.isSplitTunnelEnabled == false, "expected legacy snapshot to default split tunneling to disabled")
    }

    func testSnapshotRoundTripPreservesSplitTunnelProfiles() throws {
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy, isEnabled: false)
        let profileA = SplitTunnelProfile(name: "Work", rules: [rule], defaultAction: .direct)
        let profileB = SplitTunnelProfile(name: "Home", rules: [])
        let snapshot = AppSnapshot(
            savedConnections: [],
            subscriptionSources: [],
            selectedConnectionID: nil,
            proxyEndpoint: .default,
            splitTunnelProfiles: [profileA, profileB],
            selectedSplitTunnelProfileID: profileB.id,
            isSplitTunnelEnabled: true
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)

        XCTAssert(decoded.isSplitTunnelEnabled == true)
        XCTAssert(decoded.splitTunnelProfiles.count == 2)
        XCTAssert(decoded.selectedSplitTunnelProfileID == profileB.id, "expected the selected profile to round-trip")
        let decodedProfileA = decoded.splitTunnelProfiles.first { $0.id == profileA.id }
        XCTAssert(decodedProfileA?.name == "Work")
        XCTAssert(decodedProfileA?.rules.count == 1)
        XCTAssert(decodedProfileA?.rules[0].value == "example.com")
        XCTAssert(decodedProfileA?.rules[0].action == .proxy)
        XCTAssert(decodedProfileA?.rules[0].isEnabled == false)
        XCTAssert(decodedProfileA?.defaultAction == .direct)
    }

    func testSelectingUnknownProfileIDFallsBackToFirstProfile() throws {
        let json = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 },
          "splitTunnelProfiles": [ { "id": "22222222-2222-2222-2222-222222222222", "name": "Only", "rules": [] } ],
          "selectedSplitTunnelProfileID": "99999999-9999-9999-9999-999999999999"
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        XCTAssert(decoded.selectedSplitTunnelProfileID?.uuidString == "22222222-2222-2222-2222-222222222222", "expected an unknown selected profile id to fall back to the first profile")
    }

    func testDirectOutboundBindsToPhysicalInterface() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)

        // With a concrete interface, the direct outbound must bind to it so that
        // split-tunnel "direct" traffic egresses the physical uplink, not the TUN.
        let boundData = try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            proxyServerAddress: "203.0.113.7"
        )
        let boundDirect = try directOutbound(from: boundData)
        let sockopt = (boundDirect["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        XCTAssert(sockopt?["interface"] as? String == "en0", "expected direct outbound to bind to the physical interface")

        let boundProxy = try proxyOutbound(from: boundData)
        let proxyStreamSettings = boundProxy["streamSettings"] as? [String: Any]
        let proxySockopt = proxyStreamSettings?["sockopt"] as? [String: Any]
        XCTAssert(proxySockopt?["interface"] as? String == "en0", "expected the proxy server connection to stay on the physical interface")
        let proxySettings = boundProxy["settings"] as? [String: Any]
        let vnext = proxySettings?["vnext"] as? [[String: Any]]
        XCTAssert(vnext?.first?["address"] as? String == "203.0.113.7", "expected Xray to dial the pre-resolved protected address")
        let tlsSettings = proxyStreamSettings?["tlsSettings"] as? [String: Any]
        XCTAssert(tlsSettings?["serverName"] as? String == configuration.host, "expected TLS identity to retain the original hostname")

        // With no resolvable interface ("auto") we must not emit a bogus binding.
        let autoData = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", outboundInterface: "auto")
        let autoDirect = try directOutbound(from: autoData)
        XCTAssert(autoDirect["streamSettings"] == nil, "expected no interface binding when the interface is unknown")
    }

    func testDirectOutboundCanBindSourceAddress() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let data = try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            directSendThrough: "192.168.0.19",
            defaultAction: .direct
        )
        let direct = try directOutbound(from: data)
        XCTAssert(direct["sendThrough"] as? String == "192.168.0.19", "expected direct outbound to bind a physical-interface source address")
    }

    func testTunnelConfigIncludesIPv6() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0"
        )
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = (payload?["inbounds"] as? [[String: Any]]) ?? []
        guard let tun = inbounds.first(where: { $0["tag"] as? String == "tun" }),
              let settings = tun["settings"] as? [String: Any] else {
            XCTFail("expected tun settings")
            return
        }
        XCTAssert(settings["gateway"] as? [String] == ["172.18.0.1/30", "fdfe:dcba:9876::1/126"])
        XCTAssert(settings["autoSystemRoutingTable"] as? [String] == ["0.0.0.0/0", "::/0"])

        // Uplink without global IPv6: the TUN claims IPv4 only and DNS answers A only,
        // so nothing ever tries an IPv6 connection the tunnel could not deliver.
        let ipv4OnlyData = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"], ipv6Enabled: false)
        )
        let ipv4Only = try JSONSerialization.jsonObject(with: ipv4OnlyData) as? [String: Any]
        let ipv4OnlyTun = (ipv4Only?["inbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "tun" }
        let ipv4OnlySettings = ipv4OnlyTun?["settings"] as? [String: Any]
        XCTAssert(ipv4OnlySettings?["gateway"] as? [String] == ["172.18.0.1/30"])
        XCTAssert(ipv4OnlySettings?["autoSystemRoutingTable"] as? [String] == ["0.0.0.0/0"])
        XCTAssert((ipv4Only?["dns"] as? [String: Any])?["queryStrategy"] as? String == "UseIPv4")
        let dualStackData = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: configuration, interfaceName: "utun9", outboundInterface: "en0",
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"], ipv6Enabled: true)
        )
        let dualStack = try JSONSerialization.jsonObject(with: dualStackData) as? [String: Any]
        XCTAssert((dualStack?["dns"] as? [String: Any])?["queryStrategy"] as? String == "UseIP")
    }

    func testHelperRoutesIPv6AndDoesNotBypassDNS() throws {
        let helperScripts = generatedHelperScripts()
        XCTAssert(helperScripts.contains("route add -inet6 -net ::/1 -interface \"$tun_interface\""))
        XCTAssert(helperScripts.contains("route add -inet6 -net 8000::/1 -interface \"$tun_interface\""))
        XCTAssert(helperScripts.contains("route add -inet6 -net ::/1 \"$direct_ipv6_gateway\" -ifscope \"$OUTBOUND_INTERFACE\""))
        XCTAssert(helperScripts.contains("route add -inet6 -net 8000::/1 \"$direct_ipv6_gateway\" -ifscope \"$OUTBOUND_INTERFACE\""))
        XCTAssert(helperScripts.contains("route delete -inet6 -net ::/1"))
        XCTAssert(helperScripts.contains("route delete -inet6 -net 8000::/1"))
        XCTAssert(!helperScripts.contains("scutil --dns"), "expected system DNS to follow the TUN instead of receiving physical-gateway bypass routes")
        // The route family is now derived per protected host rather than once per
        // session, since a session may dial servers of both families.
        XCTAssert(helperScripts.contains("case \"$1\" in *:*) printf '%s' \"-inet6\""), "expected IPv6 proxy endpoints to receive an IPv6 protected route")
    }

    /// Every proxy server in a session needs its own host route pinned to the
    /// uplink, and all four phases (start, readiness re-application, failure
    /// cleanup, stop) must walk the same list.
    func testHelperProtectsEveryProxyServerRoute() throws {
        let builder = XrayTunScriptBuilder(installedXrayPath: "/Library/PrivilegedHelperTools/xray")
        let script = builder.makeStartScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            configPath: "/var/db/dev.x.teleport/xray-tun-config.json",
            assetDirectoryPath: "/tmp/geodata-resolved",
            protectedHosts: ["203.0.113.7", "2001:db8::7"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            installsIPv6Routes: true
        )
        try assertValidShell(script)
        XCTAssert(script.contains("PROTECTED_HOSTS='203.0.113.7\n2001:db8::7'"), "expected every proxy server to reach the helper")
        XCTAssert(script.contains("\"$PROTECTED_HOSTS\" > \"$PROTECTED_HOST_FILE\""))

        // Gateways must be captured while the physical default routes still exist;
        // reading them back afterwards would return the TUN and pin each server
        // inside the tunnel it carries.
        guard let captureIndex = script.range(of: "capture_host_gateways\n")?.lowerBound,
              let tunRouteIndex = script.range(of: "route add -net 0.0.0.0/1 -interface")?.lowerBound else {
            XCTFail("expected the start script to capture gateways and install TUN routes")
            return
        }
        XCTAssert(captureIndex < tunRouteIndex, "expected proxy gateways to be captured before the TUN default routes exist")

        // No phase may fall back to a single-host variable.
        XCTAssert(!script.contains("$PROTECTED_HOST\""), "expected no single-host protected route handling to remain")
        XCTAssert(script.contains("protect_host_routes"))
        XCTAssert(script.contains("cleanup_host_routes"))
        XCTAssert(script.contains("first_tunneled_protected_host"))

        let stopScript = builder.makeStopScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            protectedHosts: ["203.0.113.7", "2001:db8::7"],
            outboundInterface: "en0"
        )
        try assertValidShell(stopScript)
        XCTAssert(stopScript.contains("delete_host_route '203.0.113.7'"))
        XCTAssert(stopScript.contains("delete_host_route '2001:db8::7'"))
        // A stop after a helper restart knows no hosts, so the helper's own file
        // is always walked as well.
        XCTAssert(stopScript.contains("cleanup_host_routes"))
        XCTAssert(stopScript.contains("rm -f '/var/db/dev.x.teleport/xray-tun-protected-gateways'"))

        let fileOnlyStop = builder.makeStopScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            protectedHosts: nil,
            outboundInterface: nil
        )
        try assertValidShell(fileOnlyStop)
        XCTAssert(fileOnlyStop.contains("cleanup_host_routes"))
    }

    func testGeneratedHelperScriptsHaveValidShellSyntax() throws {
        let builder = XrayTunScriptBuilder(installedXrayPath: "/Library/PrivilegedHelperTools/xray")
        try assertValidShell(builder.makeStartScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            configPath: "/var/db/dev.x.teleport/xray-tun-config.json",
            assetDirectoryPath: "/tmp/geodata-resolved",
            protectedHosts: ["2001:db8::7"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            installsIPv6Routes: true
        ))
        let ipv4OnlyScript = builder.makeStartScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            configPath: "/var/db/dev.x.teleport/xray-tun-config.json",
            assetDirectoryPath: "/tmp/geodata-resolved",
            protectedHosts: ["203.0.113.7"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            installsIPv6Routes: false
        )
        try assertValidShell(ipv4OnlyScript)
        XCTAssert(ipv4OnlyScript.contains("INSTALL_IPV6_ROUTES=0"), "uplink without global IPv6 must not claim IPv6 routes")
        try assertValidShell(builder.makeStopScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            protectedHosts: ["2001:db8::7"],
            outboundInterface: "en0"
        ))
    }

    private func assertValidShell(_ script: String) throws {
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssert(process.terminationStatus == 0, "generated helper script has invalid shell syntax: \(errorText)")
    }

    func testProxyAddressResolutionIncludesIPv4AndIPv6() {
        let output = """
        name: proxy.example
        ipv6_address: 2001:db8::7
        ip_address: 203.0.113.7
        ipv6_address: 2001:db8::7
        """
        XCTAssert(
            XrayTunRouteInspector.resolvedAddresses(in: output) == ["2001:db8::7", "203.0.113.7"],
            "expected both address families with duplicate DNS answers removed"
        )
    }

    func testInterfaceInventoryReadsKernelFacts() {
        let names = NetworkInterfaceInventory.interfaceNames()
        XCTAssert(names.contains("lo0"), "getifaddrs must list the loopback interface")
        XCTAssert(NetworkInterfaceInventory.ipv4Address(of: "lo0") == "127.0.0.1")
        XCTAssert(!NetworkInterfaceInventory.hasGlobalIPv6Address("lo0"), "::1 is not a global address")
        XCTAssert(NetworkInterfaceInventory.isGlobalUnicastIPv6("2606:4700:4700::1111"))
        XCTAssert(!NetworkInterfaceInventory.isGlobalUnicastIPv6("fe80::1"))
        XCTAssert(!NetworkInterfaceInventory.isGlobalUnicastIPv6("fd00::1"), "unique-local is not globally routable")
        XCTAssert(!NetworkInterfaceInventory.isGlobalUnicastIPv6("not-an-address"))
    }

    func testExistingVPNDetectionCoversSplitDefaultsAndIPv6() throws {
        let physicalLookup = """
           route to: 1.1.1.1
        destination: default
          interface: en0
        """
        let splitVPNLookup = """
           route to: 129.0.0.1
        destination: 128.0.0.0
          interface: utun4
        """
        let ipv6VPNLookup = """
           route to: 2606:4700:4700::1111
        destination: default
          interface: utun7
        """
        XCTAssert(XrayTunRouteInspector.detectedVPNInterface(inRouteLookups: [physicalLookup]) == nil)
        XCTAssert(XrayTunRouteInspector.detectedVPNInterface(inRouteLookups: [physicalLookup, splitVPNLookup]) == "utun4")
        XCTAssert(XrayTunRouteInspector.detectedVPNInterface(inRouteLookups: [ipv6VPNLookup]) == "utun7")
    }

    func testTunnelSniffingIncludesQUIC() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", outboundInterface: "en0", defaultAction: .direct)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = (payload?["inbounds"] as? [[String: Any]]) ?? []
        guard let tun = inbounds.first(where: { $0["tag"] as? String == "tun" }),
              let sniffing = tun["sniffing"] as? [String: Any] else {
            XCTFail("expected tun sniffing config")
            return
        }

        XCTAssert(sniffing["routeOnly"] as? Bool == true, "expected sniffing to use routeOnly for split-tunnel routing")
        let overrides = sniffing["destOverride"] as? [String]
        XCTAssert(overrides == ["http", "tls", "quic"], "expected sniffing to include HTTP, TLS, and QUIC")
    }

    /// The other half of the same problem: sniffing recovers a QUIC name only
    /// sometimes, and the flows it misses fall through to the catch-all — direct,
    /// in the profile this leak was found in. The block sits ahead of the split
    /// rules so it holds whatever they say, and applications retry over TCP.
    func testQUICIsBlockedSoNamesStaySniffable() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let data = try writer.tunnelConfigData(
            for: configuration, interfaceName: "utun9", outboundInterface: "en0",
            splitTunnelRules: [SplitTunnelRule(value: "geosite:anthropic", kind: .geosite, action: .proxy)],
            defaultAction: .direct
        )
        let routingRules = try routingRulesArray(from: data)
        guard let blockIndex = routingRules.firstIndex(where: {
            $0["network"] as? String == "udp" && $0["port"] as? String == "443"
        }) else {
            XCTFail("expected UDP/443 to be blocked")
            return
        }
        XCTAssert(routingRules[blockIndex]["outboundTag"] as? String == "block")
        let splitIndex = routingRules.firstIndex { $0["domain"] != nil }
        XCTAssert(splitIndex == nil || blockIndex < splitIndex!, "the QUIC block must precede the split rules")
        XCTAssert(blockIndex < routingRules.count - 1, "the QUIC block must precede the catch-all")
    }

    private func generatedHelperScripts() -> String {
        let builder = XrayTunScriptBuilder(installedXrayPath: "/Library/PrivilegedHelperTools/xray")
        let startScript = builder.makeStartScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            configPath: "/var/db/dev.x.teleport/xray-tun-config.json",
            assetDirectoryPath: "/tmp/geodata-resolved",
            protectedHosts: ["203.0.113.7", "2001:db8::7"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            installsIPv6Routes: true
        )
        let stopScript = builder.makeStopScript(
            helperStateDirectoryPath: "/var/db/dev.x.teleport",
            protectedHosts: ["203.0.113.7", "2001:db8::7"],
            outboundInterface: "en0"
        )
        return startScript + "\n" + stopScript
    }

    func testHelperAddsScopedDirectRoutes() throws {
        let helperScripts = generatedHelperScripts()
        XCTAssert(helperScripts.contains("cleanup_direct_routes"), "expected helper to clean up scoped direct routes")
        XCTAssert(helperScripts.contains("protect_direct_routes"), "expected helper to install scoped direct routes")
        XCTAssert(helperScripts.contains("-ifscope \"$OUTBOUND_INTERFACE\""), "expected direct routes to be scoped to the physical interface")
        XCTAssert(helperScripts.contains("route add -net 0.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected lower IPv4 direct route through the physical gateway")
        XCTAssert(helperScripts.contains("route add -net 128.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected upper IPv4 direct route through the physical gateway")
    }

    func testTunnelConfigExposesLocalSocksAndHTTPPorts() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let endpoint = ProxyEndpoint(host: "127.0.0.1", httpPort: 8123, socksPort: 1234)
        let writer = XrayConfigurationWriter(proxyEndpoint: endpoint)

        let data = try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            defaultAction: .direct
        )
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = (payload?["inbounds"] as? [[String: Any]]) ?? []

        guard let socksInbound = inbounds.first(where: { $0["tag"] as? String == "socks-in" }) else {
            XCTFail("expected a socks-in inbound alongside the tun inbound in TUN mode")
            return
        }
        XCTAssert(socksInbound["protocol"] as? String == "socks")
        XCTAssert(socksInbound["listen"] as? String == "127.0.0.1")
        XCTAssert(socksInbound["port"] as? Int == 1234)

        guard let httpInbound = inbounds.first(where: { $0["tag"] as? String == "http-in" }) else {
            XCTFail("expected an http-in inbound alongside the tun inbound in TUN mode")
            return
        }
        XCTAssert(httpInbound["protocol"] as? String == "http")
        XCTAssert(httpInbound["listen"] as? String == "127.0.0.1")
        XCTAssert(httpInbound["port"] as? Int == 8123)

        XCTAssert(inbounds.contains { $0["tag"] as? String == "tun" }, "expected the tun inbound to remain present")

        let routingRules = try routingRulesArray(from: data)
        guard let localProxyRule = routingRules.first else {
            XCTFail("expected routing rules for local proxy inbounds")
            return
        }
        XCTAssert(localProxyRule["inboundTag"] as? [String] == ["socks-in", "http-in"])
        XCTAssert(localProxyRule["outboundTag"] as? String == "proxy")
        XCTAssert(
            localProxyRule["network"] as? String == "tcp,udp",
            "explicit local proxy ports must stay proxied even when unmatched TUN traffic is direct"
        )
    }

    func testDefaultActionSetsCatchAllOutbound() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)

        // The catch-all is always the last routing rule and covers all tcp/udp.
        func catchAll(_ action: SplitTunnelRuleAction?) throws -> [String: Any] {
            let data: Data
            if let action {
                data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", defaultAction: action)
            } else {
                data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9")
            }
            let rules = try routingRulesArray(from: data)
            let last = try XCTUnwrap(rules.last, "expected routing rules")
            XCTAssert(last["network"] as? String == "tcp,udp", "expected the last rule to be the tcp/udp catch-all")
            return last
        }

        // Default (unspecified) keeps the classic full-tunnel behavior.
        let defaultTag = try catchAll(nil)["outboundTag"] as? String
        XCTAssert(defaultTag == "proxy", "expected the default catch-all to proxy everything")
        let proxyTag = try catchAll(.proxy)["outboundTag"] as? String
        XCTAssert(proxyTag == "proxy")
        // Whitelist mode: unmatched traffic goes direct without a hand-written rule.
        let directTag = try catchAll(.direct)["outboundTag"] as? String
        XCTAssert(directTag == "direct", "expected defaultAction .direct to flip the catch-all to direct")

        // Xray's implicit no-rule fallback is the first outbound. It must agree
        // with the explicit catch-all as a defense against unclassified TUN flows.
        let directData = try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            defaultAction: .direct
        )
        let directPayload = try JSONSerialization.jsonObject(with: directData) as? [String: Any]
        let directOutbounds = directPayload?["outbounds"] as? [[String: Any]]
        XCTAssert(directOutbounds?.first?["tag"] as? String == "direct")

        let proxyData = try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            defaultAction: .proxy
        )
        let proxyPayload = try JSONSerialization.jsonObject(with: proxyData) as? [String: Any]
        let proxyOutbounds = proxyPayload?["outbounds"] as? [[String: Any]]
        XCTAssert(proxyOutbounds?.first?["tag"] as? String == "proxy")
    }

    private func directOutbound(from data: Data) throws -> [String: Any] {
        try outbound(tag: "direct", from: data)
    }

    private func proxyOutbound(from data: Data) throws -> [String: Any] {
        try outbound(tag: "proxy", from: data)
    }

    private func outbound(tag: String, from data: Data) throws -> [String: Any] {
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outbounds = (payload?["outbounds"] as? [[String: Any]]) ?? []
        return try XCTUnwrap(outbounds.first(where: { $0["tag"] as? String == tag }), "expected a \(tag) outbound in the tunnel config")
    }

    private func generatedSplitTunnelRoutingRules(for rules: [SplitTunnelRule]) throws -> [[String: Any]] {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)

        let baselineData = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", splitTunnelRules: [])
        let baselineRules = try routingRulesArray(from: baselineData)

        let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", splitTunnelRules: rules)
        let allRules = try routingRulesArray(from: data)
        let policyRules = allRules.filter {
            $0["outboundTag"] as? String != "dns-out"
                && $0["ip"] as? [String] != ["198.18.0.0/15", "fc00::/18"]
        }

        let enabledCount = rules.filter { $0.isEnabled }.count
        XCTAssert(
            policyRules.count == baselineRules.count + enabledCount,
            "expected exactly one routing rule per enabled split-tunnel rule"
        )

        // Split-tunnel rules are inserted after the fixed block rules and before the final catch-all proxy rule.
        let insertionIndex = baselineRules.count - 1
        return Array(policyRules[insertionIndex ..< insertionIndex + enabledCount])
    }

    private func routingRulesArray(from data: Data) throws -> [[String: Any]] {
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let routing = payload?["routing"] as? [String: Any]
        return (routing?["rules"] as? [[String: Any]]) ?? []
    }

    private func sampleVLESSLink() -> String {
        "vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&type=tcp#Sample"
    }

    private final class TemporaryApplicationSupportFileManager: FileManager {
        let rootURL: URL

        init(rootURL: URL) {
            self.rootURL = rootURL
            super.init()
        }

        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            if directory == .applicationSupportDirectory {
                return [rootURL]
            }
            return super.urls(for: directory, in: domainMask)
        }
    }

    private func sampleGeositeData() -> Data {
        let googleDomains = [
            protoVarintField(1, 2) + protoMessage(2, Data("google.com".utf8)),
            protoVarintField(1, 3) + protoMessage(2, Data("ads.google.com".utf8)) + protoMessage(3, protoMessage(1, Data("ads".utf8)))
        ]
        let googleSite = protoMessage(1, Data("google".utf8)) + googleDomains.map { protoMessage(2, $0) }.reduce(Data(), +)
        return protoMessage(1, googleSite)
    }

    private func sampleGeoIPData() -> Data {
        let cidr = protoMessage(1, Data([10, 0, 0, 0])) + protoVarintField(2, 12)
        let privateEntry = protoMessage(1, Data("private".utf8)) + protoMessage(2, cidr)
        return protoMessage(1, privateEntry)
    }

    private func protoMessage(_ fieldNumber: Int, _ value: Data) -> Data {
        protoVarint(UInt64(fieldNumber << 3 | 2)) + protoVarint(UInt64(value.count)) + value
    }

    private func protoVarintField(_ fieldNumber: Int, _ value: UInt64) -> Data {
        protoVarint(UInt64(fieldNumber << 3)) + protoVarint(value)
    }

    private func protoVarint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}
