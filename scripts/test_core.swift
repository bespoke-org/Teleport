import Foundation

@main
struct TestCore {
    static func main() throws {
        try testValidVLESSParsingAndConfigGeneration()
        try testPunycodeHostParsingPreservesASCIIHost()
        try testDisplayHostnameDecodesCyrillicLabels()
        try testCyrillicHostIsDisplayedButNotStored()
        try testPercentEncodedHostIsDecoded()
        try testValidVLESSAdditionalTransports()
        try testValidTrojanParsingAndConfigGeneration()
        try testPercentEncodedTrojanCredentialsAndNames()
        try testValidTrojanRealityParsingAndConfigGeneration()
        try testValidTrojanGRPCParsingAndConfigGeneration()
        try testWireGuardConfigurationFileParsingAndConfigGeneration()
        try testWireGuardLinkParsing()
        try testMalformedAndUnsupportedWireGuardInput()
        try testRenamingSurvivesReparsing()
        try testMalformedAndUnsupportedLinks()
        try testRuntimeStartupFailureWithoutBundledBinary()
        try testBundledArtifactVerifierAcceptsExpectedHash()
        print("test_core: all checks passed")
    }

    private static func testValidVLESSParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=ws&sni=example.com&path=%2Fws&alpn=h2,http%2F1.1#Demo"
        let configuration = try parser.parse(link)

        precondition(configuration.protocolType == .vless)
        precondition(configuration.host == "example.com")
        precondition(configuration.port == 443)
        precondition(configuration.transport == .ws)
        precondition(configuration.security == .tls)
        precondition(configuration.vlessUserID == "123e4567-e89b-12d3-a456-426614174000")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        precondition(content.contains("\"protocol\" : \"vless\""))
        precondition(content.contains("example.com"))
        precondition(content.contains("wsSettings"))
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        precondition(permissions & 0o777 == 0o600, "expected the credential-bearing Xray config to be user-only")

        // Plain TLS must mimic a browser fingerprint; a link's fp wins, chrome is the default.
        let tlsWithoutFingerprint = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&security=tls&sni=example.com&type=tcp#TLS")
        let tlsWriter = XrayConfigurationWriter(proxyEndpoint: .default)
        let tlsDefault = try JSONSerialization.jsonObject(with: try tlsWriter.tunnelConfigData(for: tlsWithoutFingerprint, interfaceName: "utun9")) as? [String: Any]
        let tlsDefaultProxy = (tlsDefault?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        let tlsDefaultSettings = (tlsDefaultProxy?["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any]
        precondition(tlsDefaultSettings?["fingerprint"] as? String == "chrome", "plain TLS must default to a browser fingerprint")
        precondition(tlsDefaultProxy?["mux"] == nil, "mux must never be enabled on the proxy outbound")
        let tlsWithFingerprint = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&security=tls&sni=example.com&fp=firefox&type=tcp#TLS")
        let tlsCustom = try JSONSerialization.jsonObject(with: try tlsWriter.tunnelConfigData(for: tlsWithFingerprint, interfaceName: "utun9")) as? [String: Any]
        let tlsCustomProxy = (tlsCustom?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        precondition(((tlsCustomProxy?["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any])?["fingerprint"] as? String == "firefox")

        let realityLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4&type=tcp#Reality"
        let realityConfiguration = try parser.parse(realityLink)
        precondition(realityConfiguration.vlessFlow == "xtls-rprx-vision")

        let realityConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: realityConfiguration, to: temporaryConfigURL())
        let realityContent = try String(contentsOf: realityConfigURL, encoding: .utf8)
        precondition(realityContent.contains("xtls-rprx-vision"))
    }

    private static func testPunycodeHostParsingPreservesASCIIHost() throws {
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@xn--e1afmkfd.test:8443?security=tls&type=tcp&sni=xn--e1afmkfd.test#IDN"
        let configuration = try parser.parse(link)

        precondition(configuration.host == "xn--e1afmkfd.test")
        precondition(!configuration.host.contains("пример"))
    }

    private static func testDisplayHostnameDecodesCyrillicLabels() throws {
        precondition(DisplayHostname.unicode("xn--d1acufc.xn--p1ai") == "домен.рф")
        precondition(DisplayHostname.unicode("XN--D1ACUFC.XN--P1AI") == "домен.рф")
        precondition(DisplayHostname.unicode("xn--d1acufc.xn--p1ai.") == "домен.рф.")
        precondition(DisplayHostname.unicode("api.xn--d1acufc.com") == "api.домен.com")
        precondition(DisplayHostname.unicode("xn--e1afmkfd.test") == "пример.test")

        for unchanged in ["example.com", "", "192.0.2.1", "2001:db8::1", "домен.рф"] {
            precondition(DisplayHostname.unicode(unchanged) == unchanged, "\(unchanged) must display as it is")
        }

        // Labels that are not valid Punycode, or decode to plain ASCII, stay as written.
        for invalid in ["xn--", "xn--abc$.com", "xn--99999999999999999999.com", "xn--abc-.com", "xn--123-.com", "xn--d1acufc-.com"] {
            precondition(DisplayHostname.unicode(invalid) == invalid, "\(invalid) must display as it is")
        }

        // Only Cyrillic is decoded, and never mixed with Latin letters: `xn--pple-43d`
        // is a Cyrillic "а" followed by Latin "pple", which reads as "apple".
        precondition(DisplayHostname.unicode("xn--pple-43d.com") == "xn--pple-43d.com")
        precondition(DisplayHostname.unicode("xn--mnchen-3ya.de") == "xn--mnchen-3ya.de")
        precondition(DisplayHostname.unicode("xn--fiqs8s.xn--p1ai") == "xn--fiqs8s.рф")
    }

    /// The readable host is only shown: the link, the stored host, the shared link
    /// and the Xray config keep the ASCII form.
    private static func testCyrillicHostIsDisplayedButNotStored() throws {
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@xn--d1acufc.xn--p1ai:443?security=tls&type=tcp"
        let configuration = try ConnectionLinkParser().parse(link)
        let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date())

        precondition(connection.displayName == "домен.рф:443")
        precondition(configuration.displayName == "xn--d1acufc.xn--p1ai:443")
        precondition(configuration.host == "xn--d1acufc.xn--p1ai")
        precondition(connection.shareableLink == link)

        let content = try String(contentsOf: try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL()), encoding: .utf8)
        precondition(content.contains("xn--d1acufc.xn--p1ai"))
        precondition(!content.contains("домен"))

        let derivedTitle = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "xn--d1acufc.xn--p1ai", savedAt: Date())
        precondition(derivedTitle.displayName == "домен.рф")
        precondition(derivedTitle.title == "xn--d1acufc.xn--p1ai")
        let untitled = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "", savedAt: Date())
        precondition(untitled.displayName == "домен.рф")
        let customTitle = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "xn--e1afmkfd", savedAt: Date())
        precondition(customTitle.displayName == "xn--e1afmkfd", "a name the user typed is shown as typed")
    }

    private static func testPercentEncodedHostIsDecoded() throws {
        // The raw-authority host extraction must percent-decode the host so an
        // encoded authority resolves to the real hostname (matching what
        // URLComponents.host would have returned) rather than a literal like
        // `t%65st.example.com` leaking into the Xray outbound / protected route.
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@t%65st.example.com:443?security=tls&type=tcp&sni=test.example.com#Encoded"
        let configuration = try parser.parse(link)

        precondition(configuration.host == "test.example.com",
                     "expected percent-encoded host to be decoded, got \(configuration.host)")
    }

    private static func testValidVLESSAdditionalTransports() throws {
        let parser = ConnectionLinkParser()

        let grpcLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=grpc&serviceName=teleport-grpc&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSgRPC"
        let grpcConfiguration = try parser.parse(grpcLink)
        precondition(grpcConfiguration.transport == .grpc)
        precondition(grpcConfiguration.grpcServiceName == "teleport-grpc")

        let grpcConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: grpcConfiguration, to: temporaryConfigURL())
        let grpcContent = try String(contentsOf: grpcConfigURL, encoding: .utf8)
        precondition(grpcContent.contains("\"network\" : \"grpc\""))
        precondition(grpcContent.contains("grpcSettings"))
        precondition(grpcContent.contains("teleport-grpc"))

        let xhttpLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=xhttp&path=%2Fedge&mode=auto&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSxHTTP"
        let xhttpConfiguration = try parser.parse(xhttpLink)
        precondition(xhttpConfiguration.transport == .xhttp)
        precondition(xhttpConfiguration.path == "/edge")
        precondition(xhttpConfiguration.transportMode == "auto")

        let xhttpConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: xhttpConfiguration, to: temporaryConfigURL())
        let xhttpContent = try String(contentsOf: xhttpConfigURL, encoding: .utf8)
        precondition(xhttpContent.contains("\"network\" : \"xhttp\""))
        precondition(xhttpContent.contains("xhttpSettings"))
        precondition(xhttpContent.contains("/edge"))

        let rawLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=none&type=raw#VLESSraw"
        let rawConfiguration = try parser.parse(rawLink)
        precondition(rawConfiguration.transport == .raw)
        precondition(rawConfiguration.security == .none)

        let rawConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: rawConfiguration, to: temporaryConfigURL())
        let rawContent = try String(contentsOf: rawConfigURL, encoding: .utf8)
        precondition(rawContent.contains("\"network\" : \"raw\""))
    }

    private static func testValidTrojanParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=tls&type=ws&sni=example.com&host=cdn.example.com&path=%2Fsocket#Trojan"
        let configuration = try parser.parse(link)

        precondition(configuration.protocolType == .trojan)
        precondition(configuration.host == "example.com")
        precondition(configuration.port == 443)
        precondition(configuration.transport == .ws)
        precondition(configuration.security == .tls)
        precondition(configuration.trojanPassword == "secret-password")
        precondition(configuration.hostHeader == "cdn.example.com")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        precondition(content.contains("\"protocol\" : \"trojan\""))
        precondition(content.contains("secret-password"))
        precondition(content.contains("cdn.example.com"))
        precondition(content.contains("wsSettings"))
    }

    private static func testPercentEncodedTrojanCredentialsAndNames() throws {
        for (encoded, expected) in [("100%25%20x", "100% x"), ("literal%2525", "literal%25")] {
            let config = try ConnectionLinkParser().parse("trojan://\(encoded)@example.com:443?security=tls#Name%2525")
            precondition(config.trojanPassword == expected)
            precondition(config.remarks == "Name%25")
            let saved = SavedConnection(id: UUID(), configuration: config, savedAt: Date(), source: nil)
            let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
            let reparsed = try ConnectionLinkParser().parse(restored.configuration.rawLink)
            precondition(reparsed == config)
        }
    }

    private static func testValidTrojanRealityParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#TrojanReality"
        let configuration = try parser.parse(link)

        precondition(configuration.protocolType == .trojan)
        precondition(configuration.security == .reality)
        precondition(configuration.transport == .tcp)
        precondition(configuration.serverName == "www.microsoft.com")
        precondition(configuration.publicKey == "abc123abc123abc123abc123abc123abc123abc123")
        precondition(configuration.shortID == "a1b2c3d4")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        precondition(content.contains("\"protocol\" : \"trojan\""))
        precondition(content.contains("\"security\" : \"reality\""))
        precondition(content.contains("realitySettings"))
        precondition(content.contains("abc123abc123abc123abc123abc123abc123abc123"))
    }

    private static func testValidTrojanGRPCParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=tls&type=grpc&sni=example.com&serviceName=teleport-trojan#TrojanGRPC"
        let configuration = try parser.parse(link)

        precondition(configuration.protocolType == .trojan)
        precondition(configuration.transport == .grpc)
        precondition(configuration.grpcServiceName == "teleport-trojan")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        precondition(content.contains("\"protocol\" : \"trojan\""))
        precondition(content.contains("\"network\" : \"grpc\""))
        precondition(content.contains("grpcSettings"))
        precondition(content.contains("teleport-trojan"))
    }


    private static let wireGuardSecretKey = "cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM="
    private static let wireGuardPeerKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    private static func wireGuardConfigurationFile(
        endpoint: String = "example.com:51820",
        extraPeer: Bool = false,
        privateKey: String? = wireGuardSecretKey
    ) -> String {
        let privateKeyLine = privateKey.map { "PrivateKey = \($0)\n" } ?? ""
        let secondPeer = extraPeer ? """

        [Peer]
        PublicKey = \(wireGuardPeerKey)
        Endpoint = other.example.com:51820
        """ : ""
        return """
        # Frankfurt WG
        [Interface]
        \(privateKeyLine)Address = 172.16.0.2/32, fd00::2/128
        DNS = 1.1.1.1
        MTU = 1380

        [Peer]
        PublicKey = \(wireGuardPeerKey)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = \(endpoint)
        PersistentKeepalive = 25
        \(secondPeer)
        """
    }

    private static func testWireGuardConfigurationFileParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let rawConfiguration = wireGuardConfigurationFile()
        let configuration = try parser.parse(rawConfiguration)

        precondition(configuration.protocolType == .wireguard)
        precondition(configuration.host == "example.com")
        precondition(configuration.port == 51820)
        // The format carries no name field, so the leading comment becomes one.
        precondition(configuration.remarks == "Frankfurt WG")
        precondition(configuration.displayName == "Frankfurt WG")
        // WireGuard always encrypts; its placeholder `.none` security must not
        // raise the "traffic is not encrypted" warning shown for plain links.
        precondition(configuration.securityWarningText == nil)
        precondition(configuration.descriptiveSummary == "WireGuard • MTU 1380")

        let parameters = configuration.wireguard
        precondition(parameters?.secretKey == wireGuardSecretKey)
        precondition(parameters?.peerPublicKey == wireGuardPeerKey)
        precondition(parameters?.presharedKey == nil)
        precondition(parameters?.addresses == ["172.16.0.2/32", "fd00::2/128"])
        precondition(parameters?.allowedIPs == ["0.0.0.0/0", "::/0"])
        precondition(parameters?.mtu == 1380)
        precondition(parameters?.persistentKeepalive == 25)
        // The peer's resolvers are kept: they answer for the names routed through
        // this connection.
        precondition(parameters?.dnsServers == ["1.1.1.1"])

        // `AppViewModel` re-parses every stored `rawLink` on launch, so the raw
        // configuration text must survive a round trip unchanged.
        let reparsedConfiguration = try parser.parse(configuration.rawLink)
        precondition(reparsedConfiguration == configuration)

        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let tunnelPayload = try JSONSerialization.jsonObject(with: try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            proxyServerAddress: "192.0.2.1"
        )) as? [String: Any]
        let tunnelProxy = (tunnelPayload?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        precondition(tunnelProxy?["protocol"] as? String == "wireguard")

        let settings = tunnelProxy?["settings"] as? [String: Any]
        precondition(settings?["secretKey"] as? String == wireGuardSecretKey)
        precondition(settings?["address"] as? [String] == ["172.16.0.2/32", "fd00::2/128"])
        precondition(settings?["mtu"] as? Int == 1380)
        // Kernel mode is Linux-only; macOS must run Xray's userspace tunnel.
        precondition(settings?["kernelMode"] as? Bool == false)
        precondition(settings?["reserved"] == nil)

        let peers = settings?["peers"] as? [[String: Any]]
        precondition(peers?.count == 1)
        // The peer endpoint carries the same numeric address that receives the
        // protected physical route, not the hostname.
        precondition(peers?.first?["endpoint"] as? String == "192.0.2.1:51820")
        precondition(peers?.first?["publicKey"] as? String == wireGuardPeerKey)
        precondition(peers?.first?["keepAlive"] as? Int == 25)
        precondition(peers?.first?["preSharedKey"] == nil)

        // WireGuard has no Xray stream layer, but the uplink binding must survive:
        // it is what keeps the handshake out of the tunnel it is establishing.
        let tunnelStreamSettings = tunnelProxy?["streamSettings"] as? [String: Any]
        precondition(tunnelStreamSettings?["network"] == nil)
        precondition(tunnelStreamSettings?["security"] == nil)
        precondition(tunnelStreamSettings?["tlsSettings"] == nil)
        precondition((tunnelStreamSettings?["sockopt"] as? [String: Any])?["interface"] as? String == "en0")

        // The unprivileged local-proxy config has no interface to bind, so the
        // outbound carries no stream settings at all.
        let proxyConfigURL = try writer.writeConfig(for: configuration, to: temporaryConfigURL())
        let proxyPayload = try JSONSerialization.jsonObject(with: try Data(contentsOf: proxyConfigURL)) as? [String: Any]
        let localProxyOutbound = (proxyPayload?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        precondition(localProxyOutbound?["protocol"] as? String == "wireguard")
        precondition(localProxyOutbound?["streamSettings"] == nil)
    }

    private static func testWireGuardLinkParsing() throws {
        let parser = ConnectionLinkParser()
        // Base64url keys and mixed-case query names are both emitted in the wild.
        let link = "wireguard://cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM%3D@example.com:51820"
            + "?PublicKey=bmXOC-F1FxEMF9dyiK2H5_1SUtzH0JuVo51h2wPfgyo"
            + "&address=172.16.0.2/32&reserved=1,2,3#Link%20WG"
        let configuration = try parser.parse(link)

        precondition(configuration.protocolType == .wireguard)
        precondition(configuration.remarks == "Link WG")
        precondition(configuration.wireguard?.secretKey == wireGuardSecretKey)
        precondition(configuration.wireguard?.peerPublicKey == wireGuardPeerKey)
        precondition(configuration.wireguard?.reserved == [1, 2, 3])
        // Absent AllowedIPs means the peer takes everything the tunnel offers.
        precondition(configuration.wireguard?.allowedIPs == ["0.0.0.0/0", "::/0"])
        let reparsedConfiguration = try parser.parse(configuration.rawLink)
        precondition(reparsedConfiguration == configuration)

        let payload = try JSONSerialization.jsonObject(with: try XrayConfigurationWriter(proxyEndpoint: .default)
            .tunnelConfigData(for: configuration, interfaceName: "utun9")) as? [String: Any]
        let settings = ((payload?["outbounds"] as? [[String: Any]])?
            .first { $0["tag"] as? String == "proxy" })?["settings"] as? [String: Any]
        precondition(settings?["reserved"] as? [Int] == [1, 2, 3])
        // Without an MTU the config still pins WireGuard's own default rather
        // than leaving the choice to Xray.
        precondition(settings?["mtu"] as? Int == WireGuardParameters.defaultMTU)
        // An IPv6 endpoint literal has to reach Xray bracketed.
        let ipv6Configuration = try parser.parse(wireGuardConfigurationFile(endpoint: "[2001:db8::1]:51820"))
        precondition(ipv6Configuration.host == "2001:db8::1")
        let ipv6Payload = try JSONSerialization.jsonObject(with: try XrayConfigurationWriter(proxyEndpoint: .default)
            .tunnelConfigData(for: ipv6Configuration, interfaceName: "utun9")) as? [String: Any]
        let ipv6Settings = ((ipv6Payload?["outbounds"] as? [[String: Any]])?
            .first { $0["tag"] as? String == "proxy" })?["settings"] as? [String: Any]
        let ipv6Peer = (ipv6Settings?["peers"] as? [[String: Any]])?.first
        precondition(ipv6Peer?["endpoint"] as? String == "[2001:db8::1]:51820")
    }

    private static func testMalformedAndUnsupportedWireGuardInput() throws {
        let parser = ConnectionLinkParser()

        do {
            _ = try parser.parse(wireGuardConfigurationFile(privateKey: "not-base64"))
            fatalError("Expected invalidWireGuardKey")
        } catch let error as ConfigurationError {
            if case .invalidWireGuardKey("PrivateKey") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        do {
            _ = try parser.parse(wireGuardConfigurationFile(privateKey: nil))
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("PrivateKey") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        do {
            _ = try parser.parse(wireGuardConfigurationFile(endpoint: "example.com"))
            fatalError("Expected invalidPort")
        } catch let error as ConfigurationError {
            precondition(error == .invalidPort)
        }

        // Xray supports several peers per outbound; this release deliberately
        // rejects them instead of silently using only the first.
        do {
            _ = try parser.parse(wireGuardConfigurationFile(extraPeer: true))
            fatalError("Expected multipleWireGuardPeers")
        } catch let error as ConfigurationError {
            precondition(error == .multipleWireGuardPeers)
        }

        do {
            _ = try parser.parse("wireguard://\(wireGuardSecretKey)@example.com:51820?address=172.16.0.2/32")
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("PublicKey") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }
    }

    /// A name is stored inside the raw link, which the app re-parses on every
    /// launch, so renaming must produce something that still parses to the same
    /// connection. A WireGuard configuration is not a URL: writing the name into a
    /// "#" fragment would cut the file off at its first comment.
    private static func testRenamingSurvivesReparsing() throws {
        let parser = ConnectionLinkParser()

        let link = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Old")
        let renamedLink = link.withDisplayName("Work VLESS")
        let reparsedLink = try parser.parse(renamedLink.rawLink)
        precondition(reparsedLink.remarks == "Work VLESS")
        precondition(reparsedLink.host == link.host && reparsedLink.vlessUserID == link.vlessUserID)

        // Replacing an existing name comment.
        let named = try parser.parse(wireGuardConfigurationFile())
        precondition(named.remarks == "Frankfurt WG")
        let renamedNamed = named.withDisplayName("wg")
        let reparsedNamed = try parser.parse(renamedNamed.rawLink)
        precondition(reparsedNamed.remarks == "wg")
        precondition(reparsedNamed.wireguard == named.wireguard, "renaming must not disturb the peer material")
        precondition(reparsedNamed.host == named.host && reparsedNamed.port == named.port)

        // A configuration with no name comment gains one.
        let anonymous = try parser.parse(
            wireGuardConfigurationFile().replacingOccurrences(of: "# Frankfurt WG\n", with: "")
        )
        precondition(anonymous.remarks == nil)
        precondition(anonymous.displayName == "example.com:51820")
        let renamedAnonymous = anonymous.withDisplayName("wg")
        let reparsedAnonymous = try parser.parse(renamedAnonymous.rawLink)
        precondition(reparsedAnonymous.remarks == "wg")
        precondition(reparsedAnonymous.wireguard == anonymous.wireguard)
    }

    private static func testMalformedAndUnsupportedLinks() throws {
        let parser = ConnectionLinkParser()

        do {
            _ = try parser.parse("https://example.com")
            fatalError("Expected invalidScheme")
        } catch let error as ConfigurationError {
            precondition(error == .invalidScheme)
        }

        do {
            _ = try parser.parse("vless://not-a-uuid@example.com:443?security=tls&type=tcp")
            fatalError("Expected invalidUUID")
        } catch let error as ConfigurationError {
            precondition(error == .invalidUUID)
        }

        do {
            _ = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=grpc")
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("serviceName") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        do {
            _ = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=tcp")
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("pbk") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        let tlsVision = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&flow=xtls-rprx-vision&sni=example.com")
        precondition(tlsVision.transport == .tcp)
        precondition(tlsVision.security == .tls)
        precondition(tlsVision.vlessFlow == "xtls-rprx-vision")

        do {
            _ = try parser.parse("trojan://@example.com:443?security=tls&type=tcp")
            fatalError("Expected missingPassword")
        } catch let error as ConfigurationError {
            precondition(error == .missingPassword)
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=reality&type=tcp")
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("pbk") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=reality&type=ws&sni=example.com&pbk=abc123")
            fatalError("Expected unsupportedTransport")
        } catch let error as ConfigurationError {
            if case .unsupportedTransport("ws") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=tls&type=grpc&sni=example.com")
            fatalError("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("serviceName") = error {
            } else {
                fatalError("Unexpected error: \(error)")
            }
        }
    }

    private static func testRuntimeStartupFailureWithoutBundledBinary() throws {
        let parser = ConnectionLinkParser()
        let configuration = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com")
        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let runtimeManager = XrayRuntimeManager(bundle: .main)

        do {
            try runtimeManager.start(configURL: configURL)
            fatalError("Expected binaryNotFound")
        } catch let error as XrayRuntimeManager.RuntimeError {
            switch error {
            case .binaryNotFound:
                break
            case .startupTimedOut:
                fatalError("Expected binaryNotFound")
            }
        }
    }

    private static func testBundledArtifactVerifierAcceptsExpectedHash() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-empty-artifact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL)

        let policy = BundledArtifactPolicy(
            xraySHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        try BundledArtifactVerifier(policy: policy).verifyXrayHash(fileURL)
    }

    private static func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

}
