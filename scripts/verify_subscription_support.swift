import Foundation

@main
struct VerifySubscriptionSupport {
    static func main() throws {
        try testXrayJSONSubscription()
        try testMixedJSONAndSkipReasons()
        try testUnsupportedJSONSettingsAreNotLost()
        try testJSONIdentityAndRefresh()
        try testJSONTransportsAndRuntimeRoundTrip()
        try testPlainAndBase64SubscriptionPayloadParsing()
        try testVLESSTLSVisionParsing()
        try testExtendedTransportParsing()
        try testInsecureTLSParsingAndPersistence()
        try testSubscriptionSnapshotRoundTrip()
        try testLegacyMultiConfigSnapshotDecoding()
        try testLegacySubscriptionDefaultsDuplicateFilteringToEnabled()
        try testDuplicateSubscriptionImportFiltering()
        try testSelectionPreservationAcrossRefresh()
        try testCustomNameSurvivesRefresh()
        print("verify_subscription_support: all checks passed")
    }

    private static func testXrayJSONSubscription() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/subscriptions/xray-single.json")
        let links = try SubscriptionPayloadDecoder().decode(Data(contentsOf: fixture))
        let result = try SubscriptionImportProcessor.importEntries(
            candidates: links, parser: ConnectionLinkParser(), sourceID: UUID(), filterDuplicateImports: true
        )
        precondition(result.importedEntries.count == 1)
        let config = result.importedEntries[0].configuration
        precondition(config.host == "vpn.example.com")
        precondition(config.security == .reality)
        precondition(config.vlessFlow == "xtls-rprx-vision")
        precondition(config.serverName == "www.example.com" && config.shortID == "a1b2c3d4")
        precondition(config.publicKey == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try writer.writeConfig(for: config, to: output)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        let outbound = (payload["outbounds"] as! [[String: Any]])[0]
        let stream = outbound["streamSettings"] as! [String: Any]
        let reality = stream["realitySettings"] as! [String: Any]
        precondition(reality["publicKey"] as? String == config.publicKey)
        precondition(reality["shortId"] as? String == config.shortID)
        precondition(reality["serverName"] as? String == config.serverName)
    }

    private static func xrayProfile() throws -> [String: Any] {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/subscriptions/xray-single.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
    }

    private static func importJSON(_ value: Any, filterDuplicates: Bool = true) throws -> SubscriptionImportResult {
        try importPayload(JSONSerialization.data(withJSONObject: value), filterDuplicates: filterDuplicates)
    }

    private static func importPayload(_ data: Data, filterDuplicates: Bool = true) throws -> SubscriptionImportResult {
        try SubscriptionImportProcessor.importEntries(
            candidates: SubscriptionPayloadDecoder().decode(data), parser: ConnectionLinkParser(),
            sourceID: UUID(), filterDuplicateImports: filterDuplicates
        )
    }

    private static func changingProxy(_ update: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var profile = try xrayProfile()
        var outbounds = profile["outbounds"] as! [[String: Any]]
        update(&outbounds[0])
        profile["outbounds"] = outbounds
        return profile
    }

    private static func testMixedJSONAndSkipReasons() throws {
        let valid = try xrayProfile()
        let hysteria = try changingProxy { $0["protocol"] = "hysteria" }
        let shadowsocks = try changingProxy { $0["protocol"] = "shadowsocks" }
        var balanced = valid
        balanced["routing"] = ["balancers": [["tag": "auto", "strategy": ["type": "leastLoad"]]]]
        let xhttp = try changingProxy {
            $0["streamSettings"] = ["network": "xhttp", "security": "tls", "xhttpSettings": ["extra": ["xPaddingBytes": "100-200"]]]
        }
        let result = try importJSON([valid, hysteria, shadowsocks, balanced, xhttp, 42] as [Any])
        precondition(result.importedEntries.count == 1)
        precondition(result.skippedCount == 5)
        precondition(result.skippedReasons["Hysteria is not supported"] == 1)
        precondition(result.skippedReasons["Shadowsocks is not supported"] == 1)
        precondition(result.statusMessage!.contains("Imported 1, skipped 5"))
        precondition(result.statusMessage!.contains("Balancer/observatory"))
        precondition(result.statusMessage!.contains("XHTTP"))
        do {
            _ = try importJSON([hysteria, shadowsocks])
            preconditionFailure("An all-unsupported subscription must explain why nothing imported")
        } catch let error as SubscriptionError {
            precondition(error.localizedDescription.contains("Hysteria"))
            precondition(error.localizedDescription.contains("Shadowsocks"))
            precondition(error.localizedDescription.contains("skipped 2"))
        }
        let mixedLinks = sampleLinks().joined(separator: "\n") + "\nss://REDACTED\nhy2://REDACTED"
        let mixed = try importPayload(Data(mixedLinks.utf8))
        precondition(mixed.importedEntries.count == 2 && mixed.skippedCount == 2)
    }

    private static func testUnsupportedJSONSettingsAreNotLost() throws {
        var multi = try xrayProfile()
        var outbounds = multi["outbounds"] as! [[String: Any]]
        outbounds.append(outbounds[0])
        multi["outbounds"] = outbounds
        var unresolved = try xrayProfile()
        unresolved["routing"] = ["rules": [["outboundTag": "missing"]]]
        var policy = try xrayProfile()
        policy["policy"] = ["levels": ["1": ["handshake": 10]]]
        let unsupported: [[String: Any]] = try [
            multi, unresolved, policy,
            changingProxy { $0["proxySettings"] = ["tag": "another-proxy"] },
            changingProxy { $0["mux"] = ["enabled": true] },
            changingProxy { $0["streamSettings"] = ["security": "tls", "sockopt": ["dialerProxy": "another-proxy"]] },
            changingProxy { $0["streamSettings"] = ["network": "tcp", "tcpSettings": ["header": ["type": "http"]]] },
            changingProxy { $0["streamSettings"] = ["security": "tls", "tlsSettings": ["pinnedPeerCertificateChainSha256": ["secret"]]] },
            changingProxy { $0["streamSettings"] = ["network": "ws", "wsSettings": ["headers": ["Authorization": "secret"]]] },
            changingProxy {
                $0["settings"] = ["vnext": [["address": "example.com", "port": true, "users": [["id": "123e4567-e89b-12d3-a456-426614174000"]]]]]
            },
            changingProxy {
                $0["settings"] = ["vnext": [["address": "example.com", "port": 65536, "users": [["id": "123e4567-e89b-12d3-a456-426614174000"]]]]]
            },
            changingProxy {
                $0["settings"] = [
                    "vnext": [["address": "example.com", "port": 443, "users": [["id": "123e4567-e89b-12d3-a456-426614174000", "encryption": "secret"]]]]
                ]
            },
            changingProxy { $0["streamSettings"] = ["security": "tls", "tlsSettings": ["allowInsecure": "false"]] },
        ]
        for profile in unsupported {
            let result = try importJSON([try xrayProfile(), profile])
            precondition(result.importedEntries.count == 1 && result.skippedCount == 1)
            precondition(!result.statusMessage!.contains("secret"))
        }
        for payload in ["{broken", "[", "[]", "<html>Subscription login</html>", "  ", "null"] {
            do {
                _ = try importPayload(Data(payload.utf8))
                preconditionFailure("Malformed or empty payload must fail")
            } catch is SubscriptionError {}
        }
    }

    private static func testJSONIdentityAndRefresh() throws {
        let profile = try xrayProfile()
        let compact = try JSONSerialization.data(withJSONObject: [profile])
        let reordered = try JSONSerialization.data(withJSONObject: [profile], options: [.sortedKeys, .prettyPrinted])
        let initial = try importPayload(compact)
        let refreshed = try importPayload(reordered)
        precondition(initial.importedEntries[0].sourceEntryID == refreshed.importedEntries[0].sourceEntryID)
        let base64 = try importPayload(Data(reordered.base64EncodedString().utf8))
        precondition(base64.importedEntries[0].configuration == refreshed.importedEntries[0].configuration)
        let duplicated = try importJSON([profile, profile], filterDuplicates: false)
        precondition(duplicated.importedEntries.count == 1, "Exact duplicate identities cannot be saved twice")
        let sourceID = UUID()
        let connectionID = UUID()
        let saved = SavedConnection(
            id: connectionID, configuration: initial.importedEntries[0].configuration, savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: initial.importedEntries[0].sourceEntryID),
            customName: "My saved server"
        )
        let replacement = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [saved], sourceID: sourceID, selectedConnectionID: connectionID,
            importedEntries: refreshed.importedEntries, fetchedAt: Date(), autoSelectFirstImported: false
        )
        precondition(replacement.selectedConnectionID == connectionID)
        precondition(replacement.savedConnections[0].customName == "My saved server")
        precondition(replacement.savedConnections[0].savedAt == saved.savedAt)
        let encoded = try JSONEncoder().encode(replacement.savedConnections[0])
        let restored = try JSONDecoder().decode(SavedConnection.self, from: encoded)
        let reparsed = try ConnectionLinkParser().parse(restored.configuration.rawLink)
        precondition(reparsed == restored.configuration)
    }

    private static func testJSONTransportsAndRuntimeRoundTrip() throws {
        let transports: [(String, [String: Any])] = [
            ("tcp", [:]), ("raw", [:]),
            ("ws", ["path": "/edge?token=%25&x=1", "headers": ["Host": "cdn.example.com"]]),
            ("grpc", ["serviceName": "service/with%25"]),
            ("xhttp", ["path": "/edge", "host": "cdn.example.com", "mode": "auto"]),
        ]
        for (network, settings) in transports {
            let profile = try changingProxy {
                $0["settings"] = [
                    "vnext": [["address": "vpn.example.com", "port": 8443, "users": [["id": "123e4567-e89b-12d3-a456-426614174000", "encryption": "none"]]]]
                ]
                $0["streamSettings"] = [
                    "network": network, "security": "tls", network + "Settings": settings,
                    "tlsSettings": ["serverName": "www.example.com", "fingerprint": "firefox", "alpn": ["h2", "http/1.1"], "allowInsecure": true],
                ]
            }
            let config = try importJSON(profile).importedEntries[0].configuration
            precondition(config.transport.rawValue == network)
            precondition(config.allowsInsecureTLS && config.fingerprint == "firefox")
            precondition(config.alpn == ["h2", "http/1.1"])
            let reparsed = try ConnectionLinkParser().parse(config.rawLink)
            precondition(reparsed == config)
            let writer = XrayConfigurationWriter(proxyEndpoint: .default)
            let data = try writer.tunnelConfigData(for: config, interfaceName: "utun9")
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let outbound = (payload["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
            let stream = outbound["streamSettings"] as! [String: Any]
            precondition(stream["network"] as? String == network)
            let tls = stream["tlsSettings"] as! [String: Any]
            precondition(tls["allowInsecure"] as? Bool == true)
            precondition(tls["serverName"] as? String == "www.example.com")
            if !settings.isEmpty {
                precondition(NSDictionary(dictionary: stream[network + "Settings"] as! [String: Any]) == NSDictionary(dictionary: settings))
            }
        }

        let password = "literal%25:@/?# + secret"
        var trojan = try changingProxy {
            $0["protocol"] = "trojan"
            $0["settings"] = ["servers": [["address": "2001:db8::1", "port": 443, "password": password]]]
            $0["streamSettings"] = ["network": "tcp", "security": "tls"]
        }
        trojan["remarks"] = "Literal %25 name"
        let config = try importJSON(trojan).importedEntries[0].configuration
        precondition(config.protocolType == .trojan && config.trojanPassword == password)
        precondition(config.host == "2001:db8::1" && config.remarks == "Literal %25 name")
        let reparsed = try ConnectionLinkParser().parse(config.rawLink)
        precondition(reparsed == config)
    }

    private static func testPlainAndBase64SubscriptionPayloadParsing() throws {
        let plainPayload = sampleLinks().joined(separator: "\n")
        let plain = try importPayload(Data(plainPayload.utf8))
        let encoded = try importPayload(Data(Data(plainPayload.utf8).base64EncodedString().utf8))
        let withBOM = try importPayload(Data(("\u{FEFF} \n" + plainPayload).utf8))
        precondition(withBOM.importedEntries.count == 2)
        precondition(plain.importedEntries.count == 2 && plain.skippedCount == 0)
        precondition(encoded.importedEntries.map(\.configuration) == plain.importedEntries.map(\.configuration))
        precondition(plain.importedEntries[0].configuration.protocolType == .vless)
        precondition(plain.importedEntries[1].configuration.protocolType == .trojan)
    }

    private static func testVLESSTLSVisionParsing() throws {
        let parser = ConnectionLinkParser()
        let configuration = try parser.parse(vlessTLSVisionLink())

        precondition(configuration.protocolType == .vless)
        precondition(configuration.security == .tls)
        precondition(configuration.transport == .tcp)
        precondition(configuration.vlessFlow == "xtls-rprx-vision")
        precondition(configuration.serverName == "example.com")
        precondition(configuration.alpn == ["http/1.1"])
    }

    private static func testExtendedTransportParsing() throws {
        let parser = ConnectionLinkParser()

        let grpcConfiguration = try parser.parse(vlessGRPCLink())
        precondition(grpcConfiguration.transport == .grpc)
        precondition(grpcConfiguration.grpcServiceName == "teleport-grpc")

        let xhttpConfiguration = try parser.parse(vlessXHTTPLink())
        precondition(xhttpConfiguration.transport == .xhttp)
        precondition(xhttpConfiguration.transportMode == "auto")
        precondition(xhttpConfiguration.path == "/edge")

        let rawConfiguration = try parser.parse(vlessRawLink())
        precondition(rawConfiguration.transport == .raw)
        precondition(rawConfiguration.security == .none)

        let trojanGRPCConfiguration = try parser.parse(trojanGRPCLink())
        precondition(trojanGRPCConfiguration.transport == .grpc)
        precondition(trojanGRPCConfiguration.grpcServiceName == "teleport-trojan")
    }

    private static func testInsecureTLSParsingAndPersistence() throws {
        let parser = ConnectionLinkParser()
        let configuration = try parser.parse(trojanInsecureTLSLink())

        precondition(configuration.protocolType == .trojan)
        precondition(configuration.security == .tls)
        precondition(configuration.transport == .ws)
        precondition(configuration.allowsInsecureTLS)
        precondition(configuration.securityWarningText == "TLS certificate verification is disabled")
        precondition(configuration.descriptiveSummary.contains("Insecure TLS"))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ConnectionConfiguration.self, from: data)
        precondition(decoded.allowsInsecureTLS)
    }

    private static func testSubscriptionSnapshotRoundTrip() throws {
        let parser = ConnectionLinkParser()
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let importedConnection = SavedConnection(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            configuration: try parser.parse(sampleLinks()[0]),
            savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: sampleLinks()[0])
        )
        let source = SubscriptionSource(
            id: sourceID,
            urlString: "https://example.com/subscription",
            title: "example.com",
            savedAt: Date(timeIntervalSince1970: 0),
            filterDuplicateImports: false,
            lastRefreshedAt: Date(timeIntervalSince1970: 200),
            lastError: nil,
            lastSkippedCount: 1
        )
        let snapshot = AppSnapshot(
            savedConnections: [importedConnection],
            subscriptionSources: [source],
            selectedConnectionID: importedConnection.id,
            proxyEndpoint: .default
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)

        precondition(decoded.subscriptionSources.count == 1)
        precondition(decoded.savedConnections.count == 1)
        precondition(decoded.savedConnections[0].source?.subscriptionSourceID == sourceID)
        precondition(decoded.selectedConnectionID == importedConnection.id)
        precondition(decoded.subscriptionSources[0].filterDuplicateImports == false)
    }

    private static func testLegacyMultiConfigSnapshotDecoding() throws {
        let legacyJSON = """
        {
          "savedConnections": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "configuration": {
                "rawLink": "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Legacy",
                "protocolType": "vless",
                "host": "example.com",
                "port": 443,
                "remarks": "Legacy",
                "security": "tls",
                "transport": "tcp",
                "path": null,
                "hostHeader": null,
                "serverName": "example.com",
                "alpn": [],
                "fingerprint": null,
                "publicKey": null,
                "shortID": null,
                "spiderX": null,
                "vlessUserID": "123e4567-e89b-12d3-a456-426614174000",
                "vlessFlow": null,
                "trojanPassword": null
              },
              "savedAt": 0
            }
          ],
          "selectedConnectionID": "11111111-2222-3333-4444-555555555555",
          "proxyEndpoint": {
            "host": "127.0.0.1",
            "httpPort": 8080,
            "socksPort": 1080
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: legacyJSON)
        precondition(decoded.subscriptionSources.isEmpty)
        precondition(decoded.savedConnections.count == 1)
        precondition(decoded.savedConnections[0].source == nil)
        precondition(decoded.savedConnections[0].configuration.allowsInsecureTLS == false)
    }

    private static func testLegacySubscriptionDefaultsDuplicateFilteringToEnabled() throws {
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [
            {
              "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
              "urlString": "https://example.com/subscription",
              "title": "example.com",
              "savedAt": 0,
              "autoUpdateIntervalMinutes": 60,
              "lastRefreshedAt": 200,
              "lastError": null,
              "lastSkippedCount": 0
            }
          ],
          "selectedConnectionID": null,
          "proxyEndpoint": {
            "host": "127.0.0.1",
            "httpPort": 8080,
            "socksPort": 1080
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: legacyJSON)
        precondition(decoded.subscriptionSources.count == 1)
        precondition(decoded.subscriptionSources[0].filterDuplicateImports == true)
    }

    private static func testDuplicateSubscriptionImportFiltering() throws {
        let parser = ConnectionLinkParser()
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let links = [
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Alpha",
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Beta",
            sampleLinks()[1]
        ]

        let filtered = try AppViewModel.importSubscriptionEntries(
            links: links,
            parser: parser,
            sourceID: sourceID,
            filterDuplicateImports: true
        )
        precondition(filtered.importedEntries.count == 2)
        precondition(filtered.importedEntries[0].configuration.displayName == "Alpha")
        precondition(filtered.importedEntries[1].configuration.displayName == "Beta")

        let unfiltered = try AppViewModel.importSubscriptionEntries(
            links: links,
            parser: parser,
            sourceID: sourceID,
            filterDuplicateImports: false
        )
        precondition(unfiltered.importedEntries.count == 3)
    }

    /// A name the user gave an imported connection has to survive the next
    /// refresh, which rebuilds every imported entry from the source. Storing it
    /// inside the link would lose it here.
    private static func testCustomNameSurvivesRefresh() throws {
        let parser = ConnectionLinkParser()
        let sourceID = UUID()
        let connectionID = UUID()
        let sourceEntry = sampleLinks()[0]
        let configuration = try parser.parse(sourceEntry)

        let named = SavedConnection(
            id: connectionID,
            configuration: configuration,
            savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: sourceEntry),
            customName: "Work"
        )
        precondition(named.displayName == "Work")
        // Sharing carries the chosen name even though the stored link is untouched.
        precondition(named.configuration.rawLink == configuration.rawLink)
        let sharedConfiguration = try parser.parse(named.shareableLink)
        precondition(sharedConfiguration.remarks == "Work")

        let refreshed = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [named],
            sourceID: sourceID,
            selectedConnectionID: connectionID,
            importedEntries: [ImportedSubscriptionEntry(sourceEntryID: sourceEntry, configuration: configuration)],
            fetchedAt: Date(timeIntervalSince1970: 300),
            autoSelectFirstImported: false
        )
        let refreshedConnection = refreshed.savedConnections.first { $0.id == connectionID }
        precondition(refreshedConnection?.customName == "Work", "expected a user name to survive a subscription refresh")
        precondition(refreshedConnection?.displayName == "Work")

        // A connection with no name of its own still reads as the source named it.
        let unnamed = SavedConnection(
            id: UUID(),
            configuration: configuration,
            savedAt: Date(timeIntervalSince1970: 100),
            source: nil
        )
        precondition(unnamed.displayName == configuration.displayName)
        precondition(unnamed.shareableLink == configuration.rawLink)
    }

    private static func testSelectionPreservationAcrossRefresh() throws {
        let parser = ConnectionLinkParser()
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let selectedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let manualID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let sourceEntry = sampleLinks()[0]

        let existingImported = SavedConnection(
            id: selectedID,
            configuration: try parser.parse(sourceEntry),
            savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: sourceEntry)
        )
        let manual = SavedConnection(
            id: manualID,
            configuration: try parser.parse(sampleLinks()[1]),
            savedAt: Date(timeIntervalSince1970: 200),
            source: nil
        )

        let reconciler = SubscriptionConnectionReconciler()
        let preserved = reconciler.reconcile(
            existingConnections: [existingImported, manual],
            sourceID: sourceID,
            selectedConnectionID: selectedID,
            importedEntries: [ImportedSubscriptionEntry(sourceEntryID: sourceEntry, configuration: try parser.parse(sourceEntry))],
            fetchedAt: Date(timeIntervalSince1970: 300),
            autoSelectFirstImported: false
        )

        precondition(preserved.selectedConnectionID == selectedID)

        let removed = reconciler.reconcile(
            existingConnections: [existingImported, manual],
            sourceID: sourceID,
            selectedConnectionID: selectedID,
            importedEntries: [],
            fetchedAt: Date(timeIntervalSince1970: 400),
            autoSelectFirstImported: false
        )

        precondition(removed.selectedConnectionID == manualID)
    }

    private static func sampleLinks() -> [String] {
        [
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Alpha",
            "trojan://secret-password@example.org:443?security=tls&type=ws&sni=example.org&host=cdn.example.org&path=%2Fsocket#Beta"
        ]
    }

    private static func vlessTLSVisionLink() -> String {
        "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com&alpn=http%2F1.1&flow=xtls-rprx-vision#TLSVision"
    }

    private static func trojanInsecureTLSLink() -> String {
        "trojan://secret-password@example.org:443?security=tls&type=ws&sni=example.org&host=cdn.example.org&path=%2Fsocket&allowInsecure=1#Beta"
    }

    private static func vlessGRPCLink() -> String {
        "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=grpc&serviceName=teleport-grpc&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSgRPC"
    }

    private static func vlessXHTTPLink() -> String {
        "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=xhttp&path=%2Fedge&mode=auto&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSxHTTP"
    }

    private static func vlessRawLink() -> String {
        "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=none&type=raw#VLESSraw"
    }

    private static func trojanGRPCLink() -> String {
        "trojan://secret-password@example.org:443?security=tls&type=grpc&sni=example.org&serviceName=teleport-trojan#TrojanGRPC"
    }
}
