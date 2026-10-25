import Foundation
import XCTest

final class SubscriptionSupportTests: XCTestCase {
    func testXrayJSONSubscription() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/subscriptions/xray-single.json")
        let links = try SubscriptionPayloadDecoder().decode(Data(contentsOf: fixture))
        let result = try SubscriptionImportProcessor.importEntries(
            candidates: links, parser: ConnectionLinkParser(), sourceID: UUID(), filterDuplicateImports: true
        )
        XCTAssert(result.importedEntries.count == 1)
        let config = result.importedEntries[0].configuration
        XCTAssert(config.host == "vpn.example.com")
        XCTAssert(config.security == .reality)
        XCTAssert(config.vlessFlow == "xtls-rprx-vision")
        XCTAssert(config.serverName == "www.example.com" && config.shortID == "a1b2c3d4")
        XCTAssert(config.publicKey == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try writer.writeConfig(for: config, to: output)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        let outbound = (payload["outbounds"] as! [[String: Any]])[0]
        let stream = outbound["streamSettings"] as! [String: Any]
        let reality = stream["realitySettings"] as! [String: Any]
        XCTAssert(reality["publicKey"] as? String == config.publicKey)
        XCTAssert(reality["shortId"] as? String == config.shortID)
        XCTAssert(reality["serverName"] as? String == config.serverName)
    }

    func testMalformedJSONPaste() throws {
        for proto in ["vless", "trojan", "hysteria"] {
            do {
                _ = try ConnectionLinkParser().parse("{\"outbounds\":[{\"protocol\":\"\(proto)\"")
                XCTFail("Malformed JSON was accepted")
            } catch ConfigurationError.invalidXrayJSON {
                // A JSON syntax error belongs to the format, not a protocol.
            }
        }
    }

    private func xrayProfile() throws -> [String: Any] {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/subscriptions/xray-single.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
    }

    private func importJSON(_ value: Any, filterDuplicates: Bool = true) throws -> SubscriptionImportResult {
        try importPayload(JSONSerialization.data(withJSONObject: value), filterDuplicates: filterDuplicates)
    }

    private func importPayload(_ data: Data, filterDuplicates: Bool = true) throws -> SubscriptionImportResult {
        try SubscriptionImportProcessor.importEntries(
            candidates: SubscriptionPayloadDecoder().decode(data), parser: ConnectionLinkParser(),
            sourceID: UUID(), filterDuplicateImports: filterDuplicates
        )
    }

    private func changingProxy(_ update: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var profile = try xrayProfile()
        var outbounds = profile["outbounds"] as! [[String: Any]]
        update(&outbounds[0])
        profile["outbounds"] = outbounds
        return profile
    }

    func testMixedJSONAndSkipReasons() throws {
        let valid = try xrayProfile()
        let hysteria = try changingProxy { $0["protocol"] = "hysteria" }
        let shadowsocks = try changingProxy { $0["protocol"] = "shadowsocks" }
        var balanced = valid
        balanced["routing"] = ["balancers": [["tag": "auto", "strategy": ["type": "leastLoad"]]]]
        let xhttp = try changingProxy {
            $0["streamSettings"] = ["network": "xhttp", "security": "tls", "xhttpSettings": ["extra": ["xPaddingBytes": "100-200"]]]
        }
        let result = try importJSON([valid, hysteria, shadowsocks, balanced, xhttp, 42] as [Any])
        XCTAssert(result.importedEntries.count == 1)
        XCTAssert(result.skippedCount == 5)
        XCTAssert(result.skippedReasons.keys.contains { $0.contains("Hysteria") })
        XCTAssert(result.skippedReasons["Shadowsocks is not supported"] == 1)
        XCTAssert(result.statusMessage!.contains("Imported 1, skipped 5"))
        XCTAssert(result.statusMessage!.contains("Balancer/observatory"))
        XCTAssert(result.statusMessage!.contains("XHTTP"))
        do {
            _ = try importJSON([hysteria, shadowsocks])
            XCTFail("An all-unsupported subscription must explain why nothing imported")
        } catch let error as SubscriptionError {
            XCTAssert(error.localizedDescription.contains("Hysteria"))
            XCTAssert(error.localizedDescription.contains("Shadowsocks"))
            XCTAssert(error.localizedDescription.contains("skipped 2"))
        }
        let mixedLinks = sampleLinks().joined(separator: "\n") + "\nss://REDACTED\nhy2://"
        let mixed = try importPayload(Data(mixedLinks.utf8))
        XCTAssert(mixed.importedEntries.count == 2 && mixed.skippedCount == 2)
    }

    func testUnsupportedJSONSettingsAreNotLost() throws {
        var multi = try xrayProfile()
        var outbounds = multi["outbounds"] as! [[String: Any]]
        outbounds.append(outbounds[0])
        multi["outbounds"] = outbounds
        var unresolved = try xrayProfile()
        unresolved["routing"] = ["rules": [["outboundTag": "missing"]]]
        let unsupported: [[String: Any]] = try [
            multi, unresolved,
            changingProxy { $0["proxySettings"] = ["tag": "another-proxy"] },
            changingProxy { $0["mux"] = ["enabled": true] },
            changingProxy { $0["streamSettings"] = ["security": "tls", "sockopt": ["dialerProxy": "another-proxy"]] },
            changingProxy { $0["streamSettings"] = ["security": "tls", "sockopt": ["interface": "en1"]] },
            changingProxy { $0["streamSettings"] = ["security": "tls", "sockopt": ["domainStrategy": "UseIPv4"]] },
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
            XCTAssert(result.importedEntries.count == 1 && result.skippedCount == 1)
            XCTAssert(!result.statusMessage!.contains("secret"))
        }
        for payload in ["{broken", "[", "[]", "<html>Subscription login</html>", "  ", "null"] {
            do {
                _ = try importPayload(Data(payload.utf8))
                XCTFail("Malformed or empty payload must fail")
            } catch is SubscriptionError {}
        }
    }

    func testLocalJSONSettings() throws {
        let original = try importJSON(xrayProfile()).importedEntries[0].configuration
        var profile = try changingProxy {
            $0["mux"] = ["concurrency": 8]
            var stream = $0["streamSettings"] as! [String: Any]
            var reality = stream["realitySettings"] as! [String: Any]
            reality["show"] = true
            stream["realitySettings"] = reality
            stream["sockopt"] = [String: Any]()
            $0["streamSettings"] = stream
            var settings = $0["settings"] as! [String: Any]
            var endpoints = settings["vnext"] as! [[String: Any]]
            var users = endpoints[0]["users"] as! [[String: Any]]
            users[0]["level"] = 8
            endpoints[0]["users"] = users
            settings["vnext"] = endpoints
            $0["settings"] = settings
        }
        profile["policy"] = ["levels": ["8": ["handshake": 10]]]
        profile["stats"] = [String: Any]()
        profile["api"] = ["tag": "api", "services": ["StatsService"]]
        let imported = try importJSON(profile).importedEntries[0].configuration
        XCTAssert(imported == original, "Local runtime settings must not change the imported endpoint or identity")

        for mux: [String: Any] in [[:], ["enabled": false], ["enabled": false, "concurrency": 8]] {
            let variant = try changingProxy { $0["mux"] = mux }
            let config = try importJSON(variant).importedEntries[0].configuration
            XCTAssert(config == original)
        }
        for level: Any in [0, 8, UInt32.max] {
            let trojan = try changingProxy {
                $0["protocol"] = "trojan"
                $0["settings"] = ["servers": [["address": "vpn.example.com", "port": 443, "password": "test", "level": level]]]
                $0["streamSettings"] = ["security": "tls", "tlsSettings": ["show": false]]
            }
            let config = try importJSON(trojan).importedEntries[0].configuration
            XCTAssert(config.trojanPassword == "test")
        }
        for level: Any in [true, -1, 1.5, "8", Double(UInt32.max) + 1] {
            let invalid = try changingProxy {
                $0["protocol"] = "trojan"
                $0["settings"] = ["servers": [["address": "vpn.example.com", "port": 443, "password": "test", "level": level]]]
            }
            let result = try importJSON([try xrayProfile(), invalid])
            XCTAssert(result.skippedCount == 1)
        }
    }

    func testEmptyJSONServerNameAndHostValidation() throws {
        var configs: [ConnectionConfiguration] = []
        for tls: [String: Any] in [[:], ["serverName": ""]] {
            let profile = try changingProxy {
                $0["settings"] = ["vnext": [["address": "vpn.example.com", "port": 443,
                    "users": [["id": "123e4567-e89b-12d3-a456-426614174000", "flow": ""]]]]]
                $0["streamSettings"] = ["security": "tls", "tlsSettings": tls]
            }
            let config = try importJSON(profile).importedEntries[0].configuration
            configs.append(config)
            XCTAssert(config.serverName == nil && config.vlessFlow == nil)
            let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
                for: config, interfaceName: "utun9", proxyServerAddress: "192.0.2.1"
            )
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let outbound = (payload["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
            let stream = outbound["streamSettings"] as! [String: Any]
            XCTAssert((stream["tlsSettings"] as! [String: Any])["serverName"] as? String == "vpn.example.com")
            let endpoint = ((outbound["settings"] as! [String: Any])["vnext"] as! [[String: Any]])[0]
            XCTAssert(endpoint["address"] as? String == "192.0.2.1")
        }
        XCTAssert(configs[0] == configs[1], "Empty optional fields must preserve canonical identity")

        for host in ["a:b", "[a:b]", "[2001:db8::1", "2001:db8::1]", "fe80::1%en0", "[example.com]", "bad host", "example.com/path"] {
            let invalid = try changingProxy {
                $0["protocol"] = "trojan"
                $0["settings"] = ["servers": [["address": host, "port": 443, "password": "test"]]]
            }
            let result = try importJSON([try xrayProfile(), invalid])
            XCTAssert(result.skippedCount == 1, "Malformed host must be rejected: \(host)")
        }
        for host in ["2001:db8::1", "[2001:db8::1]", "::1", "::ffff:192.0.2.1", "192.0.2.1", "vpn.example.com"] {
            let valid = try changingProxy {
                $0["protocol"] = "trojan"
                $0["settings"] = ["servers": [["address": host, "port": 443, "password": "test"]]]
            }
            let config = try importJSON(valid).importedEntries[0].configuration
            XCTAssert(config.host == host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }
    }

    func testLegacyDuplicateRefresh() throws {
        let sourceID = UUID()
        let entryID = sampleLinks()[0]
        let configuration = try ConnectionLinkParser().parse(entryID)
        let source = ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: entryID)
        let first = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(timeIntervalSince1970: 100),
            source: source, healthCheck: .unknown, customName: "First copy")
        let second = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(timeIntervalSince1970: 200),
            source: source, healthCheck: ConnectionHealthCheck(state: .reachable, checkedAt: Date(timeIntervalSince1970: 210),
                latencyMilliseconds: 42, latencyKind: .tcpConnect, failureSummary: nil), customName: "Selected copy")
        // Round-trip the old persisted state, including the duplicate entry IDs.
        let restored = try JSONDecoder().decode([SavedConnection].self, from: JSONEncoder().encode([first, second]))
        for selectedID in [nil, first.id, second.id] {
            let expected = selectedID == second.id ? second : first
            let result = SubscriptionConnectionReconciler().reconcile(
                existingConnections: restored, sourceID: sourceID, selectedConnectionID: selectedID,
                importedEntries: [ImportedSubscriptionEntry(sourceEntryID: entryID, configuration: configuration)],
                fetchedAt: Date(), autoSelectFirstImported: false
            )
            XCTAssert(result.savedConnections.count == 1)
            let kept = result.savedConnections[0]
            XCTAssert(kept.id == expected.id && result.selectedConnectionID == expected.id)
            XCTAssert(kept.savedAt == expected.savedAt && kept.customName == expected.customName)
            XCTAssert(kept.healthCheck == expected.healthCheck)
        }
    }

    func testJSONIdentityAndRefresh() throws {
        let profile = try xrayProfile()
        let compact = try JSONSerialization.data(withJSONObject: [profile])
        let reordered = try JSONSerialization.data(withJSONObject: [profile], options: [.sortedKeys, .prettyPrinted])
        let initial = try importPayload(compact)
        let refreshed = try importPayload(reordered)
        XCTAssert(initial.importedEntries[0].sourceEntryID == refreshed.importedEntries[0].sourceEntryID)
        let base64 = try importPayload(Data(reordered.base64EncodedString().utf8))
        XCTAssert(base64.importedEntries[0].configuration == refreshed.importedEntries[0].configuration)
        let duplicated = try importJSON([profile, profile], filterDuplicates: false)
        XCTAssert(duplicated.importedEntries.count == 1, "Exact duplicate identities cannot be saved twice")
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
        XCTAssert(replacement.selectedConnectionID == connectionID)
        XCTAssert(replacement.savedConnections[0].customName == "My saved server")
        XCTAssert(replacement.savedConnections[0].savedAt == saved.savedAt)
        let encoded = try JSONEncoder().encode(replacement.savedConnections[0])
        let restored = try JSONDecoder().decode(SavedConnection.self, from: encoded)
        let reparsed = try ConnectionLinkParser().parse(restored.configuration.rawLink)
        XCTAssert(reparsed == restored.configuration)
    }

    func testJSONTransportsAndRuntimeRoundTrip() throws {
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
            XCTAssert(config.transport.rawValue == network)
            XCTAssert(config.allowsInsecureTLS && config.fingerprint == "firefox")
            XCTAssert(config.alpn == ["h2", "http/1.1"])
            let reparsed = try ConnectionLinkParser().parse(config.rawLink)
            XCTAssert(reparsed == config)
            let writer = XrayConfigurationWriter(proxyEndpoint: .default)
            let data = try writer.tunnelConfigData(for: config, interfaceName: "utun9")
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let outbound = (payload["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
            let stream = outbound["streamSettings"] as! [String: Any]
            XCTAssert(stream["network"] as? String == network)
            let tls = stream["tlsSettings"] as! [String: Any]
            XCTAssert(tls["allowInsecure"] as? Bool == true)
            XCTAssert(tls["serverName"] as? String == "www.example.com")
            if !settings.isEmpty {
                XCTAssert(NSDictionary(dictionary: stream[network + "Settings"] as! [String: Any]) == NSDictionary(dictionary: settings))
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
        XCTAssert(config.protocolType == .trojan && config.trojanPassword == password)
        XCTAssert(config.host == "2001:db8::1" && config.remarks == "Literal %25 name")
        let reparsed = try ConnectionLinkParser().parse(config.rawLink)
        XCTAssert(reparsed == config)
    }

    func testPlainAndBase64SubscriptionPayloadParsing() throws {
        let plainPayload = sampleLinks().joined(separator: "\n")
        let plain = try importPayload(Data(plainPayload.utf8))
        let encoded = try importPayload(Data(Data(plainPayload.utf8).base64EncodedString().utf8))
        let withBOM = try importPayload(Data(("\u{FEFF} \n" + plainPayload).utf8))
        XCTAssert(withBOM.importedEntries.count == 2)
        XCTAssert(plain.importedEntries.count == 2 && plain.skippedCount == 0)
        XCTAssert(encoded.importedEntries.map(\.configuration) == plain.importedEntries.map(\.configuration))
        XCTAssert(plain.importedEntries[0].configuration.protocolType == .vless)
        XCTAssert(plain.importedEntries[1].configuration.protocolType == .trojan)
    }

    func testInsecureTLSParsingAndPersistence() throws {
        let parser = ConnectionLinkParser()
        let configuration = try parser.parse(trojanInsecureTLSLink())

        XCTAssert(configuration.protocolType == .trojan)
        XCTAssert(configuration.security == .tls)
        XCTAssert(configuration.transport == .ws)
        XCTAssert(configuration.allowsInsecureTLS)
        XCTAssert(configuration.securityWarningText == "TLS certificate verification is disabled")
        XCTAssert(configuration.descriptiveSummary.contains("Insecure TLS"))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ConnectionConfiguration.self, from: data)
        XCTAssert(decoded.allowsInsecureTLS)
    }

    func testSubscriptionSnapshotRoundTrip() throws {
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

        XCTAssert(decoded.subscriptionSources.count == 1)
        XCTAssert(decoded.savedConnections.count == 1)
        XCTAssert(decoded.savedConnections[0].source?.subscriptionSourceID == sourceID)
        XCTAssert(decoded.selectedConnectionID == importedConnection.id)
        XCTAssert(decoded.subscriptionSources[0].filterDuplicateImports == false)
    }

    func testLegacyMultiConfigSnapshotDecoding() throws {
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
        XCTAssert(decoded.subscriptionSources.isEmpty)
        XCTAssert(decoded.savedConnections.count == 1)
        XCTAssert(decoded.savedConnections[0].source == nil)
        XCTAssert(decoded.savedConnections[0].configuration.allowsInsecureTLS == false)
    }

    func testLegacySubscriptionDefaultsDuplicateFilteringToEnabled() throws {
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
        XCTAssert(decoded.subscriptionSources.count == 1)
        XCTAssert(decoded.subscriptionSources[0].filterDuplicateImports == true)
    }

    func testDuplicateSubscriptionImportFiltering() throws {
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
        XCTAssert(filtered.importedEntries.count == 2)
        XCTAssert(filtered.importedEntries[0].configuration.displayName == "Alpha")
        XCTAssert(filtered.importedEntries[1].configuration.displayName == "Beta")

        let unfiltered = try AppViewModel.importSubscriptionEntries(
            links: links,
            parser: parser,
            sourceID: sourceID,
            filterDuplicateImports: false
        )
        XCTAssert(unfiltered.importedEntries.count == 3)
    }

    /// A name the user gave an imported connection has to survive the next
    /// refresh, which rebuilds every imported entry from the source. Storing it
    /// inside the link would lose it here.
    func testCustomNameSurvivesRefresh() throws {
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
        XCTAssert(named.displayName == "Work")
        // Sharing carries the chosen name even though the stored link is untouched.
        XCTAssert(named.configuration.rawLink == configuration.rawLink)
        let sharedConfiguration = try parser.parse(named.shareableLink)
        XCTAssert(sharedConfiguration.remarks == "Work")

        let refreshed = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [named],
            sourceID: sourceID,
            selectedConnectionID: connectionID,
            importedEntries: [ImportedSubscriptionEntry(sourceEntryID: sourceEntry, configuration: configuration)],
            fetchedAt: Date(timeIntervalSince1970: 300),
            autoSelectFirstImported: false
        )
        let refreshedConnection = refreshed.savedConnections.first { $0.id == connectionID }
        XCTAssert(refreshedConnection?.customName == "Work", "expected a user name to survive a subscription refresh")
        XCTAssert(refreshedConnection?.displayName == "Work")

        // A connection with no name of its own still reads as the source named it.
        let unnamed = SavedConnection(
            id: UUID(),
            configuration: configuration,
            savedAt: Date(timeIntervalSince1970: 100),
            source: nil
        )
        XCTAssert(unnamed.displayName == configuration.displayName)
        XCTAssert(unnamed.shareableLink == configuration.rawLink)
    }

    func testSelectionPreservationAcrossRefresh() throws {
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

        XCTAssert(preserved.selectedConnectionID == selectedID)

        let removed = reconciler.reconcile(
            existingConnections: [existingImported, manual],
            sourceID: sourceID,
            selectedConnectionID: selectedID,
            importedEntries: [],
            fetchedAt: Date(timeIntervalSince1970: 400),
            autoSelectFirstImported: false
        )

        XCTAssert(removed.selectedConnectionID == manualID)
    }

    private func sampleLinks() -> [String] {
        [
            "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Alpha",
            "trojan://secret-password@example.org:443?security=tls&type=ws&sni=example.org&host=cdn.example.org&path=%2Fsocket#Beta"
        ]
    }

    private func trojanInsecureTLSLink() -> String {
        "trojan://secret-password@example.org:443?security=tls&type=ws&sni=example.org&host=cdn.example.org&path=%2Fsocket&allowInsecure=1#Beta"
    }
}
