import Foundation

@main
struct VerifyCore {
    static func main() throws {
        try testValidVLESSParsingAndConfigGeneration()
        try testPunycodeHostParsingPreservesASCIIHost()
        try testPercentEncodedHostIsDecoded()
        try testValidVLESSAdditionalTransports()
        try testValidTrojanParsingAndConfigGeneration()
        try testValidTrojanRealityParsingAndConfigGeneration()
        try testValidTrojanGRPCParsingAndConfigGeneration()
        try testMalformedAndUnsupportedLinks()
        try testRuntimeStartupFailureWithoutBundledBinary()
        try testBundledArtifactVerifierAcceptsExpectedHash()
        print("verify_core: all checks passed")
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
            codeSigningRequirement: "unused-by-hash-test",
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
