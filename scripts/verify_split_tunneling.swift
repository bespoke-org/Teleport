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
        try testMatcherChecksGeodataRules()
        try testGeodataRulesGenerateRoutingRules()
        try testDomainRuleEmitsDomainPrefixNotSubstring()
        try testGeneratedRoutingRulesMatchSharedMatcher()
        try testDisabledRuleExcludedFromGeneratedRouting()
        try testEmptyRuleListProducesNoSplitTunnelRouting()
        try testDefaultActionSetsCatchAllOutbound()
        try testDirectOutboundBindsToPhysicalInterface()
        try testDirectOutboundCanBindSourceAddress()
        try testHelperAddsScopedDirectRoutes()
        try testTunnelSniffingIncludesQUIC()
        try testTunnelConfigExposesLocalSocksAndHTTPPorts()
        try testLegacySnapshotWithoutSplitTunnelFieldsDefaults()
        try testPreProfilesSnapshotMigratesFlatRulesIntoDefaultProfile()
        try testSnapshotRoundTripPreservesSplitTunnelProfiles()
        try testSelectingUnknownProfileIDFallsBackToFirstProfile()
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

    private static func testMatcherChecksGeodataRules() throws {
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
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [geosite], geodataMatcher: geodataMatcher)?.id == geosite.id)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "10.0.0.1", in: [geoip], geodataMatcher: geodataMatcher)?.id == geoip.id)

        let disabled = SplitTunnelRule(value: "geosite:google", kind: .geosite, action: .direct, isEnabled: false)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [disabled], geodataMatcher: geodataMatcher) == nil)

        // A domain rule sitting after a non-matching geodata-backed rule is still matched normally.
        let domain = SplitTunnelRule(value: "example.com", kind: .domain, action: .block)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: [geosite, domain], geodataMatcher: geodataMatcher)?.id == domain.id)

        let attrRule = SplitTunnelRule(value: "geosite:google@ads", kind: .geosite, action: .block)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "ads.google.com", in: [attrRule], geodataMatcher: geodataMatcher)?.id == attrRule.id)
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.google.com", in: [attrRule], geodataMatcher: geodataMatcher) == nil)
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

    private static func testDomainRuleEmitsDomainPrefixNotSubstring() throws {
        // A bare domain must be emitted with Xray's `domain:` prefix so Xray uses
        // subdomain matching (matching the shared tester's suffix semantics) rather
        // than substring matching, which would also hit hosts like `notexample.com`.
        let bare = SplitTunnelRule(value: "example.com", kind: .domain, action: .direct)
        let bareRoutingRules = try generatedSplitTunnelRoutingRules(for: [bare])
        precondition(bareRoutingRules.count == 1)
        precondition(bareRoutingRules[0]["domain"] as? [String] == ["domain:example.com"],
                     "expected a bare domain to be emitted with the domain: prefix")

        // A `full:`-prefixed exact rule already carries Xray's own exact-match
        // prefix and must pass through unchanged (no double prefixing).
        let exact = SplitTunnelRule(value: "full:api.example.com", kind: .domain, action: .block)
        let exactRoutingRules = try generatedSplitTunnelRoutingRules(for: [exact])
        precondition(exactRoutingRules[0]["domain"] as? [String] == ["full:api.example.com"],
                     "expected a full: rule to be emitted unchanged")

        // Lock in the tester semantics the emitted prefix is meant to agree with:
        // subdomains match, unrelated substrings do not.
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "www.example.com", in: [bare])?.id == bare.id,
                     "expected a subdomain to match the bare domain rule")
        precondition(SplitTunnelRuleMatcher.firstMatch(for: "notexample.com", in: [bare]) == nil,
                     "expected a substring-only host to NOT match the bare domain rule")
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
            case .domain:
                // A bare domain is emitted with Xray's `domain:` prefix so its
                // subdomain semantics match the shared tester's suffix match; a
                // `full:` value already carries Xray's exact-match prefix.
                let domains = routingRule["domain"] as? [String]
                let expected = rule.value.hasPrefix("full:") ? rule.value : "domain:" + rule.value
                precondition(domains == [expected], "expected domain field to carry \(expected)")
            case .geosite:
                let domains = routingRule["domain"] as? [String]
                precondition(domains == [rule.value], "expected geosite token to be emitted as-is")
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
        precondition(decoded.splitTunnelProfiles.count == 1, "expected a default profile when none was ever saved")
        precondition(decoded.splitTunnelProfiles[0].rules.isEmpty, "expected the default profile to start with no rules")
        precondition(decoded.selectedSplitTunnelProfileID == decoded.splitTunnelProfiles[0].id)
        precondition(decoded.isSplitTunnelEnabled == false, "expected legacy snapshot to default split tunneling to disabled")
    }

    private static func testPreProfilesSnapshotMigratesFlatRulesIntoDefaultProfile() throws {
        // Snapshots saved before profiles existed had a flat `splitTunnelRules`
        // list; upgrading must preserve those rules rather than discard them.
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 },
          "isSplitTunnelEnabled": true,
          "splitTunnelRules": [
            { "id": "11111111-1111-1111-1111-111111111111", "value": "example.com", "kind": "domain", "action": "proxy", "isEnabled": false }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(legacyJSON.utf8))
        precondition(decoded.splitTunnelProfiles.count == 1, "expected legacy flat rules to migrate into a single profile")
        precondition(decoded.splitTunnelProfiles[0].rules.count == 1)
        precondition(decoded.splitTunnelProfiles[0].rules[0].value == "example.com")
        precondition(decoded.splitTunnelProfiles[0].rules[0].action == .proxy)
        precondition(decoded.selectedSplitTunnelProfileID == decoded.splitTunnelProfiles[0].id)
        precondition(decoded.isSplitTunnelEnabled == true)
    }

    private static func testSnapshotRoundTripPreservesSplitTunnelProfiles() throws {
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

        precondition(decoded.isSplitTunnelEnabled == true)
        precondition(decoded.splitTunnelProfiles.count == 2)
        precondition(decoded.selectedSplitTunnelProfileID == profileB.id, "expected the selected profile to round-trip")
        let decodedProfileA = decoded.splitTunnelProfiles.first { $0.id == profileA.id }
        precondition(decodedProfileA?.name == "Work")
        precondition(decodedProfileA?.rules.count == 1)
        precondition(decodedProfileA?.rules[0].value == "example.com")
        precondition(decodedProfileA?.rules[0].action == .proxy)
        precondition(decodedProfileA?.rules[0].isEnabled == false)
        precondition(decodedProfileA?.defaultAction == .direct)
    }

    private static func testSelectingUnknownProfileIDFallsBackToFirstProfile() throws {
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
        precondition(decoded.selectedSplitTunnelProfileID?.uuidString == "22222222-2222-2222-2222-222222222222", "expected an unknown selected profile id to fall back to the first profile")
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

    private static func testDirectOutboundCanBindSourceAddress() throws {
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
        precondition(direct["sendThrough"] as? String == "192.168.0.19", "expected direct outbound to bind a physical-interface source address")
    }

    private static func testTunnelSniffingIncludesQUIC() throws {
        let configuration = try ConnectionLinkParser().parse(sampleVLESSLink())
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let data = try writer.tunnelConfigData(for: configuration, interfaceName: "utun9", outboundInterface: "en0", defaultAction: .direct)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = (payload?["inbounds"] as? [[String: Any]]) ?? []
        guard let tun = inbounds.first(where: { $0["tag"] as? String == "tun" }),
              let sniffing = tun["sniffing"] as? [String: Any] else {
            preconditionFailure("expected tun sniffing config")
        }

        precondition(sniffing["routeOnly"] as? Bool == true, "expected sniffing to use routeOnly for split-tunnel routing")
        let overrides = sniffing["destOverride"] as? [String]
        precondition(overrides == ["http", "tls", "quic"], "expected sniffing to include HTTP, TLS, and QUIC")
    }

    private static func testHelperAddsScopedDirectRoutes() throws {
        let helperSource = try String(contentsOfFile: "TeleportPrivilegedHelper/main.swift", encoding: .utf8)
        precondition(helperSource.contains("cleanup_direct_routes"), "expected helper to clean up scoped direct routes")
        precondition(helperSource.contains("protect_direct_routes"), "expected helper to install scoped direct routes")
        precondition(helperSource.contains("-ifscope \"$OUTBOUND_INTERFACE\""), "expected direct routes to be scoped to the physical interface")
        precondition(helperSource.contains("route add -net 0.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected lower IPv4 direct route through the physical gateway")
        precondition(helperSource.contains("route add -net 128.0.0.0/1 \"$direct_gateway\" -ifscope"), "expected upper IPv4 direct route through the physical gateway")
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

    private static func testDefaultActionSetsCatchAllOutbound() throws {
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
            guard let last = rules.last else { preconditionFailure("expected routing rules") }
            precondition(last["network"] as? String == "tcp,udp", "expected the last rule to be the tcp/udp catch-all")
            return last
        }

        // Default (unspecified) keeps the classic full-tunnel behavior.
        let defaultTag = try catchAll(nil)["outboundTag"] as? String
        precondition(defaultTag == "proxy", "expected the default catch-all to proxy everything")
        let proxyTag = try catchAll(.proxy)["outboundTag"] as? String
        precondition(proxyTag == "proxy")
        // Whitelist mode: unmatched traffic goes direct without a hand-written rule.
        let directTag = try catchAll(.direct)["outboundTag"] as? String
        precondition(directTag == "direct", "expected defaultAction .direct to flip the catch-all to direct")
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

    private static func sampleGeositeData() -> Data {
        let googleDomains = [
            protoVarintField(1, 2) + protoMessage(2, Data("google.com".utf8)),
            protoVarintField(1, 3) + protoMessage(2, Data("ads.google.com".utf8)) + protoMessage(3, protoMessage(1, Data("ads".utf8)))
        ]
        let googleSite = protoMessage(1, Data("google".utf8)) + googleDomains.map { protoMessage(2, $0) }.reduce(Data(), +)
        return protoMessage(1, googleSite)
    }

    private static func sampleGeoIPData() -> Data {
        let cidr = protoMessage(1, Data([10, 0, 0, 0])) + protoVarintField(2, 8)
        let privateEntry = protoMessage(1, Data("private".utf8)) + protoMessage(2, cidr)
        return protoMessage(1, privateEntry)
    }

    private static func protoMessage(_ fieldNumber: Int, _ value: Data) -> Data {
        protoVarint(UInt64(fieldNumber << 3 | 2)) + protoVarint(UInt64(value.count)) + value
    }

    private static func protoVarintField(_ fieldNumber: Int, _ value: UInt64) -> Data {
        protoVarint(UInt64(fieldNumber << 3)) + protoVarint(value)
    }

    private static func protoVarint(_ value: UInt64) -> Data {
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
