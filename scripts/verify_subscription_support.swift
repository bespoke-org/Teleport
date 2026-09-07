import Foundation

@main
struct VerifySubscriptionSupport {
    static func main() throws {
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

    private static func testPlainAndBase64SubscriptionPayloadParsing() throws {
        let parser = ConnectionLinkParser()
        let links = sampleLinks()

        let plainPayload = links.joined(separator: "\n")
        let encodedPayload = Data(plainPayload.utf8).base64EncodedString()

        let plainDecodedLinks = plainPayload.split(whereSeparator: { $0.isNewline }).map(String.init)
        let base64Decoded = Data(base64Encoded: encodedPayload, options: [.ignoreUnknownCharacters])!
        let base64DecodedLinks = String(decoding: base64Decoded, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)

        precondition(plainDecodedLinks.count == 2)
        precondition(base64DecodedLinks.count == 2)

        let plainFirst = try parser.parse(plainDecodedLinks[0])
        let plainSecond = try parser.parse(plainDecodedLinks[1])
        let base64First = try parser.parse(base64DecodedLinks[0])
        let base64Second = try parser.parse(base64DecodedLinks[1])

        precondition(plainFirst.protocolType == .vless)
        precondition(plainSecond.protocolType == .trojan)
        precondition(base64First.protocolType == .vless)
        precondition(base64Second.protocolType == .trojan)
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
