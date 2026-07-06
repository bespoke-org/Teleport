import Foundation

@main
struct VerifySplitTunneling {
    static func main() throws {
        try testClassifiesValidDomainAndIPValues()
        try testRejectsInvalidValues()
        try testMatcherFirstMatchWinsWithOverlappingRules()
        try testMatcherIgnoresDisabledRules()
        try testMatcherDomainRulesDoNotMatchIPLiterals()
        try testMatcherFullPrefixRequiresExactMatch()
        try testDomainValuesAreNormalizedToLowercase()
        try testClassifiesGeodataTokens()
        try testMatcherSkipsGeodataRules()
        try testGeodataRulesGenerateRoutingRules()
        try testGeneratedRoutingRulesMatchSharedMatcher()
        try testDisabledRuleExcludedFromGeneratedRouting()
        try testEmptyRuleListProducesNoSplitTunnelRouting()
        try testDirectOutboundBindsToPhysicalInterface()
        try testTunnelConfigExposesLocalSocksAndHTTPPorts()
        try testLegacySnapshotWithoutSplitTunnelFieldsDefaults()
        try testSnapshotRoundTripPreservesSplitTunnelState()
        print("verify_split_tunneling: all checks passed")
    }

    private static func testClassifiesValidDomainAndIPValues() throws {
        try expectClassified("example.com", kind: .domain)
        try expectClassified("full:example.com", kind: .domain)
        try expectClassified("sub.example.co.uk", kind: .domain)
        try expectClassified("1.2.3.4", kind: .ip)
        try expectClassified("1.2.3.0/24", kind: .ip)
        try expectClassified("::1", kind: .ip)
        try expectClassified("2001:db8::/32", kind: .ip)
    }

    private static func expectClassified(_ value: String, kind: SplitTunnelRuleKind) throws {
        switch SplitTunnelRuleClassifier.classify(value) {
        case let .success(classified):
            precondition(classified.kind == kind, "\(value) expected \(kind) but got \(classified.kind)")
        case .failure:
            preconditionFailure("\(value) expected to classify as \(kind) but was rejected")
        }
    }

    private static func testRejectsInvalidValues() throws {
        for invalid in ["", "   ", "-example.com", "example..com", "1.2.3.4/99", "not a domain", "example.com/24"] {
            switch SplitTunnelRuleClassifier.classify(invalid) {
            case .success:
                preconditionFailure("expected \"\(invalid)\" to be rejected")
            case .failure:
                break
            }
        }
    }

    private static func testMatcherFirstMatchWinsWithOverlappingRules() throws {
        let broad = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        let specific = SplitTunnelRule(value: "full:api.example.com", kind: .domain, action: .block)
        let rules = [broad, specific]

        let match = SplitTunnelRuleMatcher.firstMatch(for: "api.example.com", in: rules)
        precondition(match?.id == broad.id, "expected first matching rule in saved order to win")

        let reordered = [specific, broad]
        let reorderedMatch = SplitTunnelRuleMatcher.firstMatch(for: "api.example.com", in: reordered)
        precondition(reorderedMatch?.id == specific.id, "expected order change to change which rule wins")
    }

    private static func testMatcherIgnoresDisabledRules() throws {
        let disabled = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct, isEnabled: false)
        let match = SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [disabled])
        precondition(match == nil, "expected disabled rule to have no effect")
    }

    private static func testMatcherDomainRulesDoNotMatchIPLiterals() throws {
        let rule = SplitTunnelRule(value: "1.2.3.4", kind: .domain, action: .direct)
        let match = SplitTunnelRuleMatcher.firstMatch(for: "1.2.3.4", in: [rule])
        precondition(match == nil, "expected domain-kind rule to not match an IP literal candidate")
    }

    private static func testMatcherFullPrefixRequiresExactMatch() throws {
        let exact = SplitTunnelRule(value: "full:example.com", kind: .domain, action: .direct)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [exact]) != nil)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [exact]) == nil)

        let broad = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [broad]) != nil)
    }

    private static func testDomainValuesAreNormalizedToLowercase() throws {
        switch SplitTunnelRuleClassifier.classify("Example.COM") {
        case let .success(classified):
            precondition(classified.kind == .domain)
            precondition(classified.value == "example.com", "expected domain value to be stored lowercased")
        case .failure:
            preconditionFailure("expected mixed-case domain to classify successfully")
        }

        // A rule stored from mixed-case input must still match a lowercase candidate,
        // matching how Xray sees sniffed SNI/Host names.
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "API.Example.com", in: [rule]) != nil)
    }

    private static func testClassifiesGeodataTokens() throws {
        try expectClassified("geosite:google", kind: .geosite)
        try expectClassified("geosite:category-ads-all", kind: .geosite)
        try expectClassified("geosite:google@ads", kind: .geosite)
        try expectClassified("geoip:private", kind: .geoip)
        try expectClassified("geoip:cn", kind: .geoip)

        switch SplitTunnelRuleClassifier.classify("GeoSite:Google") {
        case let .success(classified):
            precondition(classified.kind == .geosite)
            precondition(classified.value == "geosite:google", "expected geosite token to be normalized to lowercase")
        case .failure:
            preconditionFailure("expected mixed-case geosite token to classify successfully")
        }

        switch SplitTunnelRuleClassifier.classify("GeoIP:Private") {
        case let .success(classified):
            precondition(classified.kind == .geoip)
            precondition(classified.value == "geoip:private", "expected geoip token to be normalized to lowercase")
        case .failure:
            preconditionFailure("expected mixed-case geoip token to classify successfully")
        }

        for invalid in ["geosite:", "geosite:@ads", "geosite:.foo", "geosite:a b", "geoip:", "geoip:@cn", "geoip:.private", "geoip:a b"] {
            switch SplitTunnelRuleClassifier.classify(invalid) {
            case .success:
                preconditionFailure("expected \"\(invalid)\" to be rejected")
            case .failure:
                break
            }
        }
    }

    private static func testMatcherSkipsGeodataRules() throws {
        // Geodata-backed rules can't be evaluated locally, so the tester never
        // claims a match for them and reports that untestable rules are present.
        let geosite = SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct)
        let geoip = SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .block)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [geosite]) == nil)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "10.0.0.1", in: [geoip]) == nil)
        precondition(SplitTunnelRuleMatcher.hasUntestableGeodataRules(in: [geosite, geoip]))

        let disabled = SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct, isEnabled: false)
        precondition(!SplitTunnelRuleMatcher.hasUntestableGeodataRules(in: [disabled]))

        // A domain rule sitting after a geodata-backed rule is still matched normally.
        let domain = SplitTunnelRule(value: "example.com", kind: .domain, action: .block)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [geosite, domain])?.id == domain.id)
    }

    private static func testGeodataRulesGenerateRoutingRules() throws {
        let rules = [
            SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct),
            SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .block)
        ]
        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        precondition(routingRules.count == 2)
        let domains = routingRules[0]["domain"] as? [String]
        precondition(domains == ["geosite:google"], "expected geosite token to be emitted in the domain array")
        precondition(routingRules[0]["outboundTag"] as? String == "direct")
        let ips = routingRules[1]["ip"] as? [String]
        precondition(ips == ["geoip:private"], "expected geoip token to be emitted in the ip array")
        precondition(routingRules[1]["outboundTag"] as? String == "block")
    }

    private static func testGeneratedRoutingRulesMatchSharedMatcher() throws {
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .direct),
            SplitTunnelRule(value: "10.0.0.0/8", kind: .ip, action: .block),
            SplitTunnelRule(value: "full:api.internal.com", kind: .domain, action: .proxy),
            SplitTunnelRule(value: "geoip:private", kind: .geoip, action: .direct)
        ]

        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        precondition(routingRules.count == rules.count, "expected one routing rule per split-tunnel rule")

        for (rule, routingRule) in zip(rules, routingRules) {
            let outboundTag = routingRule["outboundTag"] as? String
            precondition(outboundTag == rule.action.rawValue, "expected outboundTag \(rule.action.rawValue) but got \(outboundTag ?? "nil")")

            switch rule.kind {
            case .domain, .geosite:
                let domains = routingRule["domain"] as? [String]
                precondition(domains == [rule.value], "expected domain field to carry rule value as-is")
            case .ip, .geoip:
                let ips = routingRule["ip"] as? [String]
                precondition(ips == [rule.value], "expected ip field to carry rule value as-is")
            }
        }
    }

    private static func testDisabledRuleExcludedFromGeneratedRouting() throws {
        let rules = [
            SplitTunnelRule(value: "example.com", kind: .domain, action: .direct, isEnabled: true),
            SplitTunnelRule(value: "disabled.com", kind: .domain, action: .direct, isEnabled: false)
        ]
        let routingRules = try generatedSplitTunnelRoutingRules(for: rules)
        precondition(routingRules.count == 1, "expected disabled rule to be excluded from generated routing rules")
    }

    private static func testEmptyRuleListProducesNoSplitTunnelRouting() throws {
        let routingRules = try generatedSplitTunnelRoutingRules(for: [])
        precondition(routingRules.isEmpty, "expected no split-tunnel routing rules when the rule list is empty")
    }

    private static func testLegacySnapshotWithoutSplitTunnelFieldsDefaults() throws {
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 }
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(legacyJSON.utf8))
        precondition(decoded.splitTunnelRules.isEmpty, "expected legacy snapshot to default to no split-tunnel rules")
        precondition(decoded.isSplitTunnelEnabled == false, "expected legacy snapshot to default split tunneling to disabled")
    }

    private static func testSnapshotRoundTripPreservesSplitTunnelState() throws {
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy, isEnabled: false)
        let snapshot = AppSnapshot(
            savedConnections: [],
            subscriptionSources: [],
            selectedConnectionID: nil,
            proxyEndpoint: .default,
            splitTunnelRules: [rule],
            isSplitTunnelEnabled: true
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)

        precondition(decoded.isSplitTunnelEnabled == true)
        precondition(decoded.splitTunnelRules.count == 1)
        precondition(decoded.splitTunnelRules[0].value == "example.com")
        precondition(decoded.splitTunnelRules[0].action == .proxy)
        precondition(decoded.splitTunnelRules[0].isEnabled == false)
    }

    private static func testDirectOutboundBindsToPhysicalInterface() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)

        // With a concrete interface, the direct outbound must bind to it so that
        // split-tunnel "direct" traffic egresses the physical uplink, not the TUN.
        let boundData = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", outboundInterface: "en0")
        let boundDirect = try directOutbound(from: boundData)
        let sockopt = (boundDirect["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        precondition(sockopt?["interface"] as? String == "en0", "expected direct outbound to bind to the physical interface")

        // With no resolvable interface ("auto") we must not emit a bogus binding.
        let autoData = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", outboundInterface: "auto")
        let autoDirect = try directOutbound(from: autoData)
        precondition(autoDirect["streamSettings"] == nil, "expected no interface binding when the interface is unknown")
    }

    private static func testTunnelConfigExposesLocalSocksAndHTTPPorts() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let endpoint = ProxyEndpoint(host: "127.0.0.1", httpPort: 8123, socksPort: 1234)
        let writer = XrayConfigurationWriter(proxyEndpoint: endpoint)

        let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9")
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = (payload?["inbounds"] as? [[String: Any]]) ?? []

        guard let socksInbound = inbounds.first(where: { $0["tag"] as? String == "socks-in" }) else {
            preconditionFailure("expected a socks-in inbound alongside the tun inbound in VPN mode")
        }
        precondition(socksInbound["protocol"] as? String == "socks")
        precondition(socksInbound["listen"] as? String == "127.0.0.1")
        precondition(socksInbound["port"] as? Int == 1234)

        guard let httpInbound = inbounds.first(where: { $0["tag"] as? String == "http-in" }) else {
            preconditionFailure("expected an http-in inbound alongside the tun inbound in VPN mode")
        }
        precondition(httpInbound["protocol"] as? String == "http")
        precondition(httpInbound["listen"] as? String == "127.0.0.1")
        precondition(httpInbound["port"] as? Int == 8123)

        precondition(inbounds.contains { $0["tag"] as? String == "tun" }, "expected the tun inbound to remain present")
    }

    private static func directOutbound(from data: Data) throws -> [String: Any] {
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outbounds = (payload?["outbounds"] as? [[String: Any]]) ?? []
        guard let direct = outbounds.first(where: { $0["tag"] as? String == "direct" }) else {
            preconditionFailure("expected a direct outbound in the tunnel config")
        }
        return direct
    }

    private static func generatedSplitTunnelRoutingRules(for rules: [SplitTunnelRule]) throws -> [[String: Any]] {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)

        let baselineData = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", splitTunnelRules: [])
        let baselineRules = try routingRulesArray(from: baselineData)

        let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", splitTunnelRules: rules)
        let allRules = try routingRulesArray(from: data)

        let enabledCount = rules.filter { $0.isEnabled }.count
        precondition(
            allRules.count == baselineRules.count + enabledCount,
            "expected exactly one routing rule per enabled split-tunnel rule"
        )

        // Split-tunnel rules are inserted after the fixed block rules and before the final catch-all proxy rule.
        let insertionIndex = baselineRules.count - 1
        return Array(allRules[insertionIndex ..< insertionIndex + enabledCount])
    }

    private static func routingRulesArray(from data: Data) throws -> [[String: Any]] {
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let routing = payload?["routing"] as? [String: Any]
        return (routing?["rules"] as? [[String: Any]]) ?? []
    }

    private static func sampleVLESSLink() -> String {
        "vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&type=tcp#Sample"
    }
}
