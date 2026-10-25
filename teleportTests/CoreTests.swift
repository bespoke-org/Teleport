import Foundation
import XCTest

final class CoreTests: XCTestCase {
    func testValidVLESSParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=ws&sni=example.com&path=%2Fws&alpn=h2,http%2F1.1#Demo"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.protocolType == .vless)
        XCTAssert(configuration.host == "example.com")
        XCTAssert(configuration.port == 443)
        XCTAssert(configuration.transport == .ws)
        XCTAssert(configuration.security == .tls)
        XCTAssert(configuration.vlessUserID == "123e4567-e89b-12d3-a456-426614174000")
        XCTAssert(configuration.alpn == ["h2", "http/1.1"])

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssert(content.contains("\"protocol\" : \"vless\""))
        XCTAssert(content.contains("example.com"))
        XCTAssert(content.contains("wsSettings"))
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssert(permissions & 0o777 == 0o600, "expected the credential-bearing Xray config to be user-only")

        // Plain TLS must mimic a browser fingerprint; a link's fp wins, chrome is the default.
        let tlsWithoutFingerprint = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&security=tls&sni=example.com&type=tcp#TLS")
        let tlsWriter = XrayConfigurationWriter(proxyEndpoint: .default)
        let tlsDefault = try JSONSerialization.jsonObject(with: try tlsWriter.tunnelConfigData(for: tlsWithoutFingerprint, interfaceName: "utun9")) as? [String: Any]
        let tlsDefaultProxy = (tlsDefault?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        let tlsDefaultSettings = (tlsDefaultProxy?["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any]
        XCTAssert(tlsDefaultSettings?["fingerprint"] as? String == "chrome", "plain TLS must default to a browser fingerprint")
        XCTAssert(tlsDefaultProxy?["mux"] == nil, "mux must never be enabled on the proxy outbound")
        let tlsWithFingerprint = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&security=tls&sni=example.com&fp=firefox&type=tcp#TLS")
        let tlsCustom = try JSONSerialization.jsonObject(with: try tlsWriter.tunnelConfigData(for: tlsWithFingerprint, interfaceName: "utun9")) as? [String: Any]
        let tlsCustomProxy = (tlsCustom?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        XCTAssert(((tlsCustomProxy?["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any])?["fingerprint"] as? String == "firefox")

        let realityLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4&type=tcp#Reality"
        let realityConfiguration = try parser.parse(realityLink)
        XCTAssert(realityConfiguration.vlessFlow == "xtls-rprx-vision")

        let realityConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: realityConfiguration, to: temporaryConfigURL())
        let realityContent = try String(contentsOf: realityConfigURL, encoding: .utf8)
        XCTAssert(realityContent.contains("xtls-rprx-vision"))
    }

    func testPunycodeHostParsingPreservesASCIIHost() throws {
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@xn--e1afmkfd.test:8443?security=tls&type=tcp&sni=xn--e1afmkfd.test#IDN"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.host == "xn--e1afmkfd.test")
        XCTAssert(!configuration.host.contains("пример"))
    }

    func testDisplayHostnameDecodesCyrillicLabels() throws {
        XCTAssert(DisplayHostname.unicode("xn--d1acufc.xn--p1ai") == "домен.рф")
        XCTAssert(DisplayHostname.unicode("XN--D1ACUFC.XN--P1AI") == "домен.рф")
        XCTAssert(DisplayHostname.unicode("xn--d1acufc.xn--p1ai.") == "домен.рф.")
        XCTAssert(DisplayHostname.unicode("api.xn--d1acufc.com") == "api.домен.com")
        XCTAssert(DisplayHostname.unicode("xn--e1afmkfd.test") == "пример.test")

        for unchanged in ["example.com", "", "192.0.2.1", "2001:db8::1", "домен.рф"] {
            XCTAssert(DisplayHostname.unicode(unchanged) == unchanged, "\(unchanged) must display as it is")
        }

        // Labels that are not valid Punycode, or decode to plain ASCII, stay as written.
        for invalid in ["xn--", "xn--abc$.com", "xn--99999999999999999999.com", "xn--abc-.com", "xn--123-.com", "xn--d1acufc-.com"] {
            XCTAssert(DisplayHostname.unicode(invalid) == invalid, "\(invalid) must display as it is")
        }

        // Only Cyrillic is decoded, and never mixed with Latin letters: `xn--pple-43d`
        // is a Cyrillic "а" followed by Latin "pple", which reads as "apple".
        XCTAssert(DisplayHostname.unicode("xn--pple-43d.com") == "xn--pple-43d.com")
        XCTAssert(DisplayHostname.unicode("xn--mnchen-3ya.de") == "xn--mnchen-3ya.de")
        XCTAssert(DisplayHostname.unicode("xn--fiqs8s.xn--p1ai") == "xn--fiqs8s.рф")
    }

    /// The readable host is only shown: the link, the stored host, the shared link
    /// and the Xray config keep the ASCII form.
    func testCyrillicHostIsDisplayedButNotStored() throws {
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@xn--d1acufc.xn--p1ai:443?security=tls&type=tcp"
        let configuration = try ConnectionLinkParser().parse(link)
        let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date())

        XCTAssert(connection.displayName == "домен.рф:443")
        XCTAssert(configuration.displayName == "xn--d1acufc.xn--p1ai:443")
        XCTAssert(configuration.host == "xn--d1acufc.xn--p1ai")
        XCTAssert(connection.shareableLink == link)

        let content = try String(contentsOf: try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL()), encoding: .utf8)
        XCTAssert(content.contains("xn--d1acufc.xn--p1ai"))
        XCTAssert(!content.contains("домен"))

        let derivedTitle = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "xn--d1acufc.xn--p1ai", savedAt: Date())
        XCTAssert(derivedTitle.displayName == "домен.рф")
        XCTAssert(derivedTitle.title == "xn--d1acufc.xn--p1ai")
        let untitled = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "", savedAt: Date())
        XCTAssert(untitled.displayName == "домен.рф")
        let customTitle = SubscriptionSource(id: UUID(), urlString: "https://xn--d1acufc.xn--p1ai/sub", title: "xn--e1afmkfd", savedAt: Date())
        XCTAssert(customTitle.displayName == "xn--e1afmkfd", "a name the user typed is shown as typed")
    }

    func testPercentEncodedHostIsDecoded() throws {
        // The raw-authority host extraction must percent-decode the host so an
        // encoded authority resolves to the real hostname (matching what
        // URLComponents.host would have returned) rather than a literal like
        // `t%65st.example.com` leaking into the Xray outbound / protected route.
        let parser = ConnectionLinkParser()
        let link = "vless://123e4567-e89b-12d3-a456-426614174000@t%65st.example.com:443?security=tls&type=tcp&sni=test.example.com#Encoded"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.host == "test.example.com",
                     "expected percent-encoded host to be decoded, got \(configuration.host)")
    }

    func testValidVLESSAdditionalTransports() throws {
        let parser = ConnectionLinkParser()

        let grpcLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=grpc&serviceName=teleport-grpc&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSgRPC"
        let grpcConfiguration = try parser.parse(grpcLink)
        XCTAssert(grpcConfiguration.transport == .grpc)
        XCTAssert(grpcConfiguration.grpcServiceName == "teleport-grpc")

        let grpcConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: grpcConfiguration, to: temporaryConfigURL())
        let grpcContent = try String(contentsOf: grpcConfigURL, encoding: .utf8)
        XCTAssert(grpcContent.contains("\"network\" : \"grpc\""))
        XCTAssert(grpcContent.contains("grpcSettings"))
        XCTAssert(grpcContent.contains("teleport-grpc"))

        let xhttpLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=xhttp&path=%2Fedge&mode=auto&sni=example.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#VLESSxHTTP"
        let xhttpConfiguration = try parser.parse(xhttpLink)
        XCTAssert(xhttpConfiguration.transport == .xhttp)
        XCTAssert(xhttpConfiguration.path == "/edge")
        XCTAssert(xhttpConfiguration.transportMode == "auto")

        let xhttpConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: xhttpConfiguration, to: temporaryConfigURL())
        let xhttpContent = try String(contentsOf: xhttpConfigURL, encoding: .utf8)
        XCTAssert(xhttpContent.contains("\"network\" : \"xhttp\""))
        XCTAssert(xhttpContent.contains("xhttpSettings"))
        XCTAssert(xhttpContent.contains("/edge"))

        let rawLink = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=none&type=raw#VLESSraw"
        let rawConfiguration = try parser.parse(rawLink)
        XCTAssert(rawConfiguration.transport == .raw)
        XCTAssert(rawConfiguration.security == .none)

        let rawConfigURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: rawConfiguration, to: temporaryConfigURL())
        let rawContent = try String(contentsOf: rawConfigURL, encoding: .utf8)
        XCTAssert(rawContent.contains("\"network\" : \"raw\""))
    }

    func testValidTrojanParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=tls&type=ws&sni=example.com&host=cdn.example.com&path=%2Fsocket#Trojan"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.protocolType == .trojan)
        XCTAssert(configuration.host == "example.com")
        XCTAssert(configuration.port == 443)
        XCTAssert(configuration.transport == .ws)
        XCTAssert(configuration.security == .tls)
        XCTAssert(configuration.trojanPassword == "secret-password")
        XCTAssert(configuration.hostHeader == "cdn.example.com")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssert(content.contains("\"protocol\" : \"trojan\""))
        XCTAssert(content.contains("secret-password"))
        XCTAssert(content.contains("cdn.example.com"))
        XCTAssert(content.contains("wsSettings"))
    }

    func testPercentEncodedTrojanCredentialsAndNames() throws {
        for (encoded, expected) in [("100%25%20x", "100% x"), ("literal%2525", "literal%25")] {
            let config = try ConnectionLinkParser().parse("trojan://\(encoded)@example.com:443?security=tls#Name%2525")
            XCTAssert(config.trojanPassword == expected)
            XCTAssert(config.remarks == "Name%25")
            let saved = SavedConnection(id: UUID(), configuration: config, savedAt: Date(), source: nil)
            let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
            let reparsed = try ConnectionLinkParser().parse(restored.configuration.rawLink)
            XCTAssert(reparsed == config)
        }
    }

    func testValidTrojanRealityParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=abc123abc123abc123abc123abc123abc123abc123&sid=a1b2c3d4#TrojanReality"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.protocolType == .trojan)
        XCTAssert(configuration.security == .reality)
        XCTAssert(configuration.transport == .tcp)
        XCTAssert(configuration.serverName == "www.microsoft.com")
        XCTAssert(configuration.publicKey == "abc123abc123abc123abc123abc123abc123abc123")
        XCTAssert(configuration.shortID == "a1b2c3d4")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssert(content.contains("\"protocol\" : \"trojan\""))
        XCTAssert(content.contains("\"security\" : \"reality\""))
        XCTAssert(content.contains("realitySettings"))
        XCTAssert(content.contains("abc123abc123abc123abc123abc123abc123abc123"))
    }

    func testValidTrojanGRPCParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let link = "trojan://secret-password@example.com:443?security=tls&type=grpc&sni=example.com&serviceName=teleport-trojan#TrojanGRPC"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.protocolType == .trojan)
        XCTAssert(configuration.transport == .grpc)
        XCTAssert(configuration.grpcServiceName == "teleport-trojan")

        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssert(content.contains("\"protocol\" : \"trojan\""))
        XCTAssert(content.contains("\"network\" : \"grpc\""))
        XCTAssert(content.contains("grpcSettings"))
        XCTAssert(content.contains("teleport-trojan"))
    }


    private static let wireGuardSecretKey = "cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM="
    private static let wireGuardPeerKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    private func wireGuardConfigurationFile(
        endpoint: String = "example.com:51820",
        extraPeer: Bool = false,
        privateKey: String? = CoreTests.wireGuardSecretKey
    ) -> String {
        let privateKeyLine = privateKey.map { "PrivateKey = \($0)\n" } ?? ""
        let secondPeer = extraPeer ? """

        [Peer]
        PublicKey = \(Self.wireGuardPeerKey)
        Endpoint = other.example.com:51820
        """ : ""
        return """
        # Frankfurt WG
        [Interface]
        \(privateKeyLine)Address = 172.16.0.2/32, fd00::2/128
        DNS = 1.1.1.1
        MTU = 1380

        [Peer]
        PublicKey = \(Self.wireGuardPeerKey)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = \(endpoint)
        PersistentKeepalive = 25
        \(secondPeer)
        """
    }

    func testWireGuardConfigurationFileParsingAndConfigGeneration() throws {
        let parser = ConnectionLinkParser()
        let rawConfiguration = wireGuardConfigurationFile()
        let configuration = try parser.parse(rawConfiguration)

        XCTAssert(configuration.protocolType == .wireguard)
        XCTAssert(configuration.host == "example.com")
        XCTAssert(configuration.port == 51820)
        // The format carries no name field, so the leading comment becomes one.
        XCTAssert(configuration.remarks == "Frankfurt WG")
        XCTAssert(configuration.displayName == "Frankfurt WG")
        // WireGuard always encrypts; its placeholder `.none` security must not
        // raise the "traffic is not encrypted" warning shown for plain links.
        XCTAssert(configuration.securityWarningText == nil)
        XCTAssert(configuration.descriptiveSummary == "WireGuard • MTU 1380")

        let parameters = configuration.wireguard
        XCTAssert(parameters?.secretKey == Self.wireGuardSecretKey)
        XCTAssert(parameters?.peerPublicKey == Self.wireGuardPeerKey)
        XCTAssert(parameters?.presharedKey == nil)
        XCTAssert(parameters?.addresses == ["172.16.0.2/32", "fd00::2/128"])
        XCTAssert(parameters?.allowedIPs == ["0.0.0.0/0", "::/0"])
        XCTAssert(parameters?.mtu == 1380)
        XCTAssert(parameters?.persistentKeepalive == 25)
        // The peer's resolvers are kept: they answer for the names routed through
        // this connection.
        XCTAssert(parameters?.dnsServers == ["1.1.1.1"])

        // `AppViewModel` re-parses every stored `rawLink` on launch, so the raw
        // configuration text must survive a round trip unchanged.
        let reparsedConfiguration = try parser.parse(configuration.rawLink)
        XCTAssert(reparsedConfiguration == configuration)

        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let tunnelPayload = try JSONSerialization.jsonObject(with: try writer.tunnelConfigData(
            for: configuration,
            interfaceName: "utun9",
            outboundInterface: "en0",
            proxyServerAddress: "192.0.2.1"
        )) as? [String: Any]
        let tunnelProxy = (tunnelPayload?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        XCTAssert(tunnelProxy?["protocol"] as? String == "wireguard")

        let settings = tunnelProxy?["settings"] as? [String: Any]
        XCTAssert(settings?["secretKey"] as? String == Self.wireGuardSecretKey)
        XCTAssert(settings?["address"] as? [String] == ["172.16.0.2/32", "fd00::2/128"])
        XCTAssert(settings?["mtu"] as? Int == 1380)
        // Kernel mode is Linux-only; macOS must run Xray's userspace tunnel.
        XCTAssert(settings?["kernelMode"] as? Bool == false)
        XCTAssert(settings?["reserved"] == nil)

        let peers = settings?["peers"] as? [[String: Any]]
        XCTAssert(peers?.count == 1)
        // The peer endpoint carries the same numeric address that receives the
        // protected physical route, not the hostname.
        XCTAssert(peers?.first?["endpoint"] as? String == "192.0.2.1:51820")
        XCTAssert(peers?.first?["publicKey"] as? String == Self.wireGuardPeerKey)
        XCTAssert(peers?.first?["keepAlive"] as? Int == 25)
        XCTAssert(peers?.first?["preSharedKey"] == nil)

        // WireGuard has no Xray stream layer, but the uplink binding must survive:
        // it is what keeps the handshake out of the tunnel it is establishing.
        let tunnelStreamSettings = tunnelProxy?["streamSettings"] as? [String: Any]
        XCTAssert(tunnelStreamSettings?["network"] == nil)
        XCTAssert(tunnelStreamSettings?["security"] == nil)
        XCTAssert(tunnelStreamSettings?["tlsSettings"] == nil)
        XCTAssert((tunnelStreamSettings?["sockopt"] as? [String: Any])?["interface"] as? String == "en0")

        // The unprivileged local-proxy config has no interface to bind, so the
        // outbound carries no stream settings at all.
        let proxyConfigURL = try writer.writeConfig(for: configuration, to: temporaryConfigURL())
        let proxyPayload = try JSONSerialization.jsonObject(with: try Data(contentsOf: proxyConfigURL)) as? [String: Any]
        let localProxyOutbound = (proxyPayload?["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        XCTAssert(localProxyOutbound?["protocol"] as? String == "wireguard")
        XCTAssert(localProxyOutbound?["streamSettings"] == nil)
    }

    func testWireGuardLinkParsing() throws {
        let parser = ConnectionLinkParser()
        // Base64url keys and mixed-case query names are both emitted in the wild.
        let link = "wireguard://cJl3zBqYlKrLmZ1r9gCVKzZ9lHhP5rQ0nX2sYy8vWmM%3D@example.com:51820"
            + "?PublicKey=bmXOC-F1FxEMF9dyiK2H5_1SUtzH0JuVo51h2wPfgyo"
            + "&address=172.16.0.2/32&reserved=1,2,3#Link%20WG"
        let configuration = try parser.parse(link)

        XCTAssert(configuration.protocolType == .wireguard)
        XCTAssert(configuration.remarks == "Link WG")
        XCTAssert(configuration.wireguard?.secretKey == Self.wireGuardSecretKey)
        XCTAssert(configuration.wireguard?.peerPublicKey == Self.wireGuardPeerKey)
        XCTAssert(configuration.wireguard?.reserved == [1, 2, 3])
        // Absent AllowedIPs means the peer takes everything the tunnel offers.
        XCTAssert(configuration.wireguard?.allowedIPs == ["0.0.0.0/0", "::/0"])
        let reparsedConfiguration = try parser.parse(configuration.rawLink)
        XCTAssert(reparsedConfiguration == configuration)

        let payload = try JSONSerialization.jsonObject(with: try XrayConfigurationWriter(proxyEndpoint: .default)
            .tunnelConfigData(for: configuration, interfaceName: "utun9")) as? [String: Any]
        let settings = ((payload?["outbounds"] as? [[String: Any]])?
            .first { $0["tag"] as? String == "proxy" })?["settings"] as? [String: Any]
        XCTAssert(settings?["reserved"] as? [Int] == [1, 2, 3])
        // Without an MTU the config still pins WireGuard's own default rather
        // than leaving the choice to Xray.
        XCTAssert(settings?["mtu"] as? Int == WireGuardParameters.defaultMTU)
        // An IPv6 endpoint literal has to reach Xray bracketed.
        let ipv6Configuration = try parser.parse(wireGuardConfigurationFile(endpoint: "[2001:db8::1]:51820"))
        XCTAssert(ipv6Configuration.host == "2001:db8::1")
        let ipv6Payload = try JSONSerialization.jsonObject(with: try XrayConfigurationWriter(proxyEndpoint: .default)
            .tunnelConfigData(for: ipv6Configuration, interfaceName: "utun9")) as? [String: Any]
        let ipv6Settings = ((ipv6Payload?["outbounds"] as? [[String: Any]])?
            .first { $0["tag"] as? String == "proxy" })?["settings"] as? [String: Any]
        let ipv6Peer = (ipv6Settings?["peers"] as? [[String: Any]])?.first
        XCTAssert(ipv6Peer?["endpoint"] as? String == "[2001:db8::1]:51820")
    }

    func testMalformedAndUnsupportedWireGuardInput() throws {
        let parser = ConnectionLinkParser()

        do {
            _ = try parser.parse(wireGuardConfigurationFile(privateKey: "not-base64"))
            XCTFail("Expected invalidWireGuardKey")
        } catch let error as ConfigurationError {
            if case .invalidWireGuardKey("PrivateKey") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try parser.parse(wireGuardConfigurationFile(privateKey: nil))
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("PrivateKey") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try parser.parse(wireGuardConfigurationFile(endpoint: "example.com"))
            XCTFail("Expected invalidPort")
        } catch let error as ConfigurationError {
            XCTAssert(error == .invalidPort)
        }

        // Xray supports several peers per outbound; this release deliberately
        // rejects them instead of silently using only the first.
        do {
            _ = try parser.parse(wireGuardConfigurationFile(extraPeer: true))
            XCTFail("Expected multipleWireGuardPeers")
        } catch let error as ConfigurationError {
            XCTAssert(error == .multipleWireGuardPeers)
        }

        do {
            _ = try parser.parse("wireguard://\(Self.wireGuardSecretKey)@example.com:51820?address=172.16.0.2/32")
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("PublicKey") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    /// A name is stored inside the raw link, which the app re-parses on every
    /// launch, so renaming must produce something that still parses to the same
    /// connection. A WireGuard configuration is not a URL: writing the name into a
    /// "#" fragment would cut the file off at its first comment.
    func testRenamingSurvivesReparsing() throws {
        let parser = ConnectionLinkParser()

        let link = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com#Old")
        let renamedLink = link.withDisplayName("Work VLESS")
        let reparsedLink = try parser.parse(renamedLink.rawLink)
        XCTAssert(reparsedLink.remarks == "Work VLESS")
        XCTAssert(reparsedLink.host == link.host && reparsedLink.vlessUserID == link.vlessUserID)

        // Replacing an existing name comment.
        let named = try parser.parse(wireGuardConfigurationFile())
        XCTAssert(named.remarks == "Frankfurt WG")
        let renamedNamed = named.withDisplayName("wg")
        let reparsedNamed = try parser.parse(renamedNamed.rawLink)
        XCTAssert(reparsedNamed.remarks == "wg")
        XCTAssert(reparsedNamed.wireguard == named.wireguard, "renaming must not disturb the peer material")
        XCTAssert(reparsedNamed.host == named.host && reparsedNamed.port == named.port)

        // A configuration with no name comment gains one.
        let anonymous = try parser.parse(
            wireGuardConfigurationFile().replacingOccurrences(of: "# Frankfurt WG\n", with: "")
        )
        XCTAssert(anonymous.remarks == nil)
        XCTAssert(anonymous.displayName == "example.com:51820")
        let renamedAnonymous = anonymous.withDisplayName("wg")
        let reparsedAnonymous = try parser.parse(renamedAnonymous.rawLink)
        XCTAssert(reparsedAnonymous.remarks == "wg")
        XCTAssert(reparsedAnonymous.wireguard == anonymous.wireguard)
    }

    func testMalformedAndUnsupportedLinks() throws {
        let parser = ConnectionLinkParser()

        do {
            _ = try parser.parse("https://example.com")
            XCTFail("Expected invalidScheme")
        } catch let error as ConfigurationError {
            XCTAssert(error == .invalidScheme)
        }

        do {
            _ = try parser.parse("vless://not-a-uuid@example.com:443?security=tls&type=tcp")
            XCTFail("Expected invalidUUID")
        } catch let error as ConfigurationError {
            XCTAssert(error == .invalidUUID)
        }

        do {
            _ = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=grpc")
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("serviceName") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=reality&type=tcp")
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("pbk") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let tlsVision = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&flow=xtls-rprx-vision&sni=example.com")
        XCTAssert(tlsVision.transport == .tcp)
        XCTAssert(tlsVision.security == .tls)
        XCTAssert(tlsVision.vlessFlow == "xtls-rprx-vision")

        do {
            _ = try parser.parse("trojan://@example.com:443?security=tls&type=tcp")
            XCTFail("Expected missingPassword")
        } catch let error as ConfigurationError {
            XCTAssert(error == .missingPassword)
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=reality&type=tcp")
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("pbk") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=reality&type=ws&sni=example.com&pbk=abc123")
            XCTFail("Expected unsupportedTransport")
        } catch let error as ConfigurationError {
            if case .unsupportedTransport("ws") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try parser.parse("trojan://secret@example.com:443?security=tls&type=grpc&sni=example.com")
            XCTFail("Expected missingParameter")
        } catch let error as ConfigurationError {
            if case .missingParameter("serviceName") = error {
            } else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testRuntimeStartupFailureWithoutBundledBinary() throws {
        let parser = ConnectionLinkParser()
        let configuration = try parser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?security=tls&type=tcp&sni=example.com")
        let configURL = try XrayConfigurationWriter(proxyEndpoint: .default).writeConfig(for: configuration, to: temporaryConfigURL())
        let runtimeManager = XrayRuntimeManager(bundle: .main)

        do {
            try runtimeManager.start(configURL: configURL)
            XCTFail("Expected binaryNotFound")
        } catch let error as XrayRuntimeManager.RuntimeError {
            switch error {
            case .binaryNotFound:
                break
            case .startupTimedOut:
                XCTFail("Expected binaryNotFound")
            }
        }
    }

    func testBundledArtifactVerifierAcceptsExpectedHash() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-empty-artifact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL)

        let policy = BundledArtifactPolicy(
            xraySHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        try BundledArtifactVerifier(policy: policy).verifyXrayHash(fileURL)
    }

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

}
