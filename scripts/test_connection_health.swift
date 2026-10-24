import Foundation

struct TestConnectionHealth {
    static func main() throws {
        try testHealthMetadataSnapshotRoundTrip()
        try testLegacySnapshotWithoutHealthMetadata()
        try testSubscriptionRefreshPreservesHealthForEquivalentEntry()
        try testScopedWireGuardPeerIsJudgedByItsHandshake()
        print("test_connection_health: all checks passed")
    }

    /// A WireGuard peer that carries only a few subnets cannot deliver a request
    /// to a public address, so probing it that way measured the peer's scope and
    /// reported a healthy peer as failed. Such a peer is judged by its handshake.
    private static func testScopedWireGuardPeerIsJudgedByItsHandshake() throws {
        let parser = ConnectionLinkParser()
        let scoped = try parser.parse(wireGuardConfigurationFile(allowedIPs: "10.72.0.0/16"))
        precondition(scoped.wireguard?.carriesDefaultRoute == false)

        let fullTunnel = try parser.parse(wireGuardConfigurationFile(allowedIPs: "0.0.0.0/0, ::/0"))
        precondition(fullTunnel.wireguard?.carriesDefaultRoute == true)

        // The handshake is only visible in Xray's log at debug level, and the probe
        // must leave through the uplink: routed through a running tunnel it would
        // describe that tunnel instead of the server.
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        _ = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(
            for: scoped,
            to: configURL,
            logLevel: "debug",
            outboundInterface: "en0"
        )
        let payload = try JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? [String: Any]
        precondition((payload?["log"] as? [String: Any])?["loglevel"] as? String == "debug")
        let probeOutbound = (payload?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        let sockopt = (probeOutbound?["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        precondition(sockopt?["interface"] as? String == "en0", "expected a probe to be bound to the uplink")

        // The address the probe pokes has to be one the peer actually carries.
        precondition(ConnectionHealthProbeService.handshakeTriggerTarget(for: scoped.wireguard!) == "10.72.0.0")
        let withResolver = try parser.parse(
            wireGuardConfigurationFile(allowedIPs: "10.72.0.0/16").replacingOccurrences(
                of: "Address = 172.16.0.2/32",
                with: "Address = 172.16.0.2/32\nDNS = 10.72.0.53"
            )
        )
        precondition(ConnectionHealthProbeService.handshakeTriggerTarget(for: withResolver.wireguard!) == "10.72.0.53")

        // An IPv6-first peer would otherwise be poked over IPv6, which a peer with
        // no IPv6 address of its own drops before handshaking at all.
        let dualStack = try parser.parse(wireGuardConfigurationFile(allowedIPs: "fd00::/8, 10.72.0.0/16"))
        precondition(ConnectionHealthProbeService.handshakeTriggerTarget(for: dualStack.wireguard!) == "10.72.0.0")

        // Silence from the peer and never asking are different failures.
        precondition(ConnectionHealthProbeService.containsWireGuardHandshakeAttempt(
            "2026/09/07 00:00:00 [Debug] peer(abcd…wxyz) - Sending handshake initiation"
        ))
        precondition(!ConnectionHealthProbeService.containsWireGuardHandshakeAttempt("2026/09/07 00:00:00 [Warning] core: Xray started"))

        // A default route written as two halves still carries everything, so such a
        // peer must be probed with a real request rather than by its handshake.
        let halves = try parser.parse(wireGuardConfigurationFile(allowedIPs: "0.0.0.0/1, 128.0.0.0/1"))
        precondition(halves.wireguard?.carriesDefaultRoute == true)
        let partial = try parser.parse(wireGuardConfigurationFile(allowedIPs: "0.0.0.0/1"))
        precondition(partial.wireguard?.carriesDefaultRoute == false)

        // The marker matches the wording the bundled Xray actually logs, and does
        // not mistake our own outgoing handshake for the peer's answer.
        precondition(ConnectionHealthProbeService.containsWireGuardHandshakeResponse(
            "2026/09/07 00:00:00 [Debug] peer(abcd…wxyz) - Received handshake response"
        ))
        precondition(!ConnectionHealthProbeService.containsWireGuardHandshakeResponse(
            "2026/09/07 00:00:00 [Debug] peer(abcd…wxyz) - Sending handshake initiation"
        ))
        precondition(!ConnectionHealthProbeService.containsWireGuardHandshakeResponse(""))
    }

    private static func wireGuardConfigurationFile(allowedIPs: String) -> String {
        """
        [Interface]
        PrivateKey = cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM=
        Address = 172.16.0.2/32

        [Peer]
        PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
        AllowedIPs = \(allowedIPs)
        Endpoint = wg.example:51820
        """
    }

    private static func testHealthMetadataSnapshotRoundTrip() throws {
        let parser = ConnectionLinkParser()
        let connection = SavedConnection(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            configuration: try parser.parse(sampleVLESSLink()),
            savedAt: Date(timeIntervalSince1970: 100),
            source: nil,
            healthCheck: ConnectionHealthCheck(
                state: .reachable,
                checkedAt: Date(timeIntervalSince1970: 200),
                latencyMilliseconds: 42,
                latencyKind: .proxyRequest,
                failureSummary: nil
            )
        )
        let snapshot = AppSnapshot(
            savedConnections: [connection],
            subscriptionSources: [],
            selectedConnectionID: connection.id,
            proxyEndpoint: .default
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)

        precondition(decoded.savedConnections.count == 1)
        precondition(decoded.savedConnections[0].healthCheck?.state == .reachable)
        precondition(decoded.savedConnections[0].healthCheck?.latencyMilliseconds == 42)
        precondition(decoded.savedConnections[0].healthCheck?.latencyKind == .proxyRequest)
    }

    private static func testLegacySnapshotWithoutHealthMetadata() throws {
        let legacyJSON = """
        {
          "savedConnections": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "configuration": {
                "rawLink": "\(sampleVLESSLink())",
                "protocolType": "vless",
                "host": "example.com",
                "port": 443,
                "remarks": "Alpha",
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
              "savedAt": 100
            }
          ],
          "subscriptionSources": [],
          "selectedConnectionID": "11111111-2222-3333-4444-555555555555",
          "proxyEndpoint": {
            "host": "127.0.0.1",
            "httpPort": 8080,
            "socksPort": 1080
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: legacyJSON)
        precondition(decoded.savedConnections.count == 1)
        precondition(decoded.savedConnections[0].healthCheck == nil)
    }

    private static func testSubscriptionRefreshPreservesHealthForEquivalentEntry() throws {
        let parser = ConnectionLinkParser()
        let sourceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let sourceEntry = sampleVLESSLink()
        let existing = SavedConnection(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            configuration: try parser.parse(sourceEntry),
            savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: sourceEntry),
            healthCheck: ConnectionHealthCheck(
                state: .reachable,
                checkedAt: Date(timeIntervalSince1970: 200),
                latencyMilliseconds: 34,
                latencyKind: .tcpConnect,
                failureSummary: nil
            )
        )

        let reconciled = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [existing],
            sourceID: sourceID,
            selectedConnectionID: existing.id,
            importedEntries: [
                ImportedSubscriptionEntry(
                    sourceEntryID: sourceEntry,
                    configuration: try parser.parse(sourceEntry)
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 300),
            autoSelectFirstImported: false
        )

        precondition(reconciled.savedConnections.count == 1)
        precondition(reconciled.savedConnections[0].healthCheck?.latencyMilliseconds == 34)
        precondition(reconciled.savedConnections[0].healthCheck?.latencyKind == .tcpConnect)
        precondition(reconciled.selectedConnectionID == existing.id)
    }

    private static func sampleVLESSLink() -> String {
        "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Alpha"
    }
}
