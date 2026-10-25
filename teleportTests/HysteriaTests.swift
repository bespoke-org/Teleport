import Foundation
import XCTest

final class HysteriaTests: XCTestCase {
    let parser = ConnectionLinkParser()

    func fixture() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/subscriptions/hysteria2.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    func imported(_ data: Data) throws -> SubscriptionImportResult {
        try SubscriptionImportProcessor.importEntries(
            candidates: SubscriptionPayloadDecoder().decode(data), parser: parser, sourceID: UUID(), filterDuplicateImports: true
        )
    }

    func importJSON(_ value: Any) throws -> SubscriptionImportResult {
        try imported(JSONSerialization.data(withJSONObject: value))
    }

    func testLinks() throws {
        for scheme in ["hy2", "hysteria2", "HY2"] {
            let configuration = try parser.parse(
                "\(scheme)://user:pa%25ss%3A%40%2F@example.com/?sni=tls.example.com&insecure=0&obfs=salamander&obfs-password=a%25b%26c#Name%20%23%25")
            XCTAssert(configuration.hysteria?.auth == "user:pa%ss:@/")
            XCTAssert(configuration.port == 443 && configuration.transport == .hysteria && configuration.security == .tls)
            XCTAssert(configuration.hysteria?.obfuscation?.password == "a%b&c")
            XCTAssert(!configuration.allowsInsecureTLS && configuration.remarks == "Name #%")
            let shared = try parser.parse(configuration.hysteriaShareLink!)
            XCTAssert(shared == configuration, "URI credentials and names must be decoded exactly once")
            let renamed = configuration.withDisplayName("My # server %")
            let reparsed = try parser.parse(renamed.rawLink)
            XCTAssert(reparsed.remarks == "My # server %" && reparsed.hysteria == configuration.hysteria)
        }
        for host in ["example.com", "[2001:db8::1]"] {
            let config = try parser.parse("hy2://example-auth@\(host):443,20000-20010/?sni=tls.example.com")
            XCTAssert(config.hysteria?.quic?.udpHop?.ports == "443,20000-20010")
            XCTAssert(config.hysteriaShareLink!.contains(":443,20000-20010/"))
            let roundTrip = try parser.parse(config.hysteriaShareLink!)
            XCTAssert(roundTrip == config)
        }
        let defaultPort = try parser.parse("hy2://example.com")
        XCTAssert(defaultPort.hysteria?.auth == "" && defaultPort.port == 443)
        let pin = String(repeating: "ab", count: 32)
        let pinned = try parser.parse("hy2://auth@example.com?pinSHA256=\(pin)")
        XCTAssert(pinned.hysteria?.pinnedPeerCertSHA256 == pin)
        let pinnedRoundTrip = try parser.parse(pinned.hysteriaShareLink!)
        XCTAssert(pinnedRoundTrip == pinned)
        let differentBasePort = try parser.parse("hy2://auth@example.com:20000-20010")
        var differentProfile = try JSONSerialization.jsonObject(with: Data(differentBasePort.rawLink.utf8)) as! [String: Any]
        var outbounds = differentProfile["outbounds"] as! [[String: Any]]
        var endpoint = outbounds[0]["settings"] as! [String: Any]
        endpoint["port"] = 443
        outbounds[0]["settings"] = endpoint
        differentProfile["outbounds"] = outbounds
        let extended = try importJSON(differentProfile).importedEntries[0].configuration
        XCTAssert(extended.hysteriaShareLink == nil, "Sharing must not change a JSON profile's base port")
        var fingerprintProfile = try JSONSerialization.jsonObject(with: Data(defaultPort.rawLink.utf8)) as! [String: Any]
        var fingerprintOutbounds = fingerprintProfile["outbounds"] as! [[String: Any]]
        var fingerprintStream = fingerprintOutbounds[0]["streamSettings"] as! [String: Any]
        var fingerprintTLS = fingerprintStream["tlsSettings"] as! [String: Any]
        fingerprintTLS["fingerprint"] = "firefox"
        fingerprintStream["tlsSettings"] = fingerprintTLS
        fingerprintOutbounds[0]["streamSettings"] = fingerprintStream
        fingerprintProfile["outbounds"] = fingerprintOutbounds
        let withFingerprint = try importJSON(fingerprintProfile).importedEntries[0].configuration
        XCTAssert(withFingerprint.fingerprint == "firefox" && withFingerprint.hysteriaShareLink == nil)
        let fingerprintRoundTrip = try parser.parse(withFingerprint.rawLink)
        XCTAssert(fingerprintRoundTrip == withFingerprint, "JSON export must retain the fingerprint")
        for invalid in [
            "hysteria://auth@example.com:443", "hy2://", "hy2://example.com:0", "hy2://example.com:65536", "hy2://example.com:",
            "hy2://example.com:10-1", "hy2://example.com:1,,2", "hy2://example.com/path",
            "hy2://example.com?insecure=yes", "hy2://example.com?sni=a&sni=b", "hy2://example.com?pinSHA256=secret",
            "hy2://example.com?insecure=1",
            "hy2://example.com?obfs=unknown&obfs-password=secret", "hy2://example.com?obfs-password=secret",
            "hy2://example.com?upmbps=100", "hy2://example.com?ech=secret", "trojan://secret@example.com:443?type=hysteria",
        ] {
            do {
                _ = try parser.parse(invalid)
                XCTFail("Unsupported link was accepted")
            } catch let error as ConfigurationError {
                XCTAssert(!error.localizedDescription.contains("secret"))
            }
        }
        let links = "hy2://example-auth@example.com#One\nhysteria2://example-auth@example.org#Two"
        let plain = try imported(Data(links.utf8))
        let base64 = try imported(Data(Data(links.utf8).base64EncodedString().utf8))
        XCTAssert(plain.importedEntries.count == 2)
        XCTAssert(base64.importedEntries.map(\.configuration) == plain.importedEntries.map(\.configuration))
    }

    func testJSONImportAndRuntime() throws {
        let config = try importJSON(fixture()).importedEntries[0].configuration
        XCTAssert(config.protocolType == .hysteria && config.hysteria?.auth == "sanitized-auth")
        XCTAssert(config.fingerprint == "firefox")
        XCTAssert(config.hysteria?.quic?.brutalDown == "100 mbps")
        XCTAssert(config.hysteria?.obfuscation?.password == "sanitized-obfs")
        XCTAssert(config.hysteriaShareLink == nil && config.shareExportNote != nil)
        let writer = XrayConfigurationWriter(proxyEndpoint: .default)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hysteria-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.json")
        _ = try writer.writeConfig(for: config, to: systemURL)
        let tunnelData = try writer.tunnelConfigData(
            for: config, interfaceName: "utun99", outboundInterface: "en0", proxyServerAddress: "192.0.2.1",
            dnsPolicy: TunnelDNSPolicy(localResolvers: ["192.0.2.53"])
        )
        let tunnelURL = directory.appendingPathComponent("tunnel.json")
        try tunnelData.write(to: tunnelURL)
        for url in [systemURL, tunnelURL] {
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let outbound = (payload["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
            let settings = outbound["settings"] as! [String: Any]
            let stream = outbound["streamSettings"] as! [String: Any]
            XCTAssert(settings["version"] as? Int == 2)
            XCTAssert(settings["address"] as? String == (url == tunnelURL ? "192.0.2.1" : "vpn.example.com"))
            XCTAssert((stream["tlsSettings"] as! [String: Any])["serverName"] as? String == "tls.example.com")
            XCTAssert((stream["tlsSettings"] as! [String: Any])["fingerprint"] as? String == "firefox")
            XCTAssert((stream["hysteriaSettings"] as! [String: Any])["auth"] as? String == "sanitized-auth")
            XCTAssert(NSDictionary(dictionary: stream["finalmask"] as! [String: Any]).isEqual(to: config.hysteria!.finalMask))
            if url == tunnelURL {
                XCTAssert((stream["sockopt"] as! [String: Any])["interface"] as? String == "en0")
                // Client DNS arrives as UDP, but Xray resolves proxied names
                // over HTTPS/TCP. A server disabling UDP relay does not disable
                // this resolver. Its QUIC transport still requires network UDP.
                let dns = payload["dns"] as! [String: Any]
                XCTAssert((dns["servers"] as! [Any])[0] as? String == "https://1.1.1.1/dns-query")
                let rules = (payload["routing"] as! [String: Any])["rules"] as! [[String: Any]]
                let resolverRoute = rules.first { $0["inboundTag"] as? [String] == ["dns-internal"] && $0["ip"] == nil }!
                XCTAssert(resolverRoute["outboundTag"] as? String == "proxy" && resolverRoute["network"] == nil)
            }
            let process = Process()
            process.executableURL = repositoryRoot.appendingPathComponent("teleport/Resources/xray")
            process.arguments = ["run", "-test", "-c", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssert(process.terminationStatus == 0, "Bundled Xray rejected generated Hysteria configuration")
        }
        let mixed = try imported(Data(("hy2://auth@example.com\nhysteria://auth@example.com\nss://unsupported").utf8))
        XCTAssert(mixed.importedEntries.count == 1 && mixed.skippedCount == 2)
    }

    func testURIExtensions() throws {
        let extended = try parser.parse("hy2://auth@example.com:443?mport=20000-20010&alpn=h3,h3-29&fp=Firefox")
        XCTAssert(extended.port == 443 && extended.hysteria?.quic?.udpHop?.ports == "20000-20010")
        XCTAssert(extended.alpn == ["h3", "h3-29"] && extended.fingerprint == "firefox")
        XCTAssert(extended.hysteriaShareLink == nil)
        let exported = try parser.parse(extended.rawLink)
        XCTAssert(exported == extended, "URI extension settings must survive storage and JSON sharing")
        let samePorts = try parser.parse("hy2://auth@example.com:20000-20010?mport=20000-20010")
        XCTAssert(samePorts.hysteria?.quic?.udpHop?.ports == "20000-20010")
        let gecko = try parser.parse("hy2://auth@example.com?obfs=gecko&obfs-password=example")
        XCTAssert(gecko.hysteria?.obfuscation?.packetSize == "512-1200")
        XCTAssert(gecko.hysteriaShareLink!.contains("obfs=gecko"))
        let geckoRoundTrip = try parser.parse(gecko.hysteriaShareLink!)
        XCTAssert(geckoRoundTrip == gecko)
        for (query, reason) in [
            ("ech=secret", "ECH"), ("upmbps=100", "bandwidth"), ("downmbps=100", "bandwidth"),
            ("obfs=secret&obfs-password=secret", "obfuscation"), ("new-option=secret", "share-link"),
            ("mport=0", "range"), ("alpn=h2", "ALPN"), ("fp=secret", "fingerprint"),
        ] {
            do {
                _ = try parser.parse("hy2://auth@example.com?\(query)")
                XCTFail("Unsupported URI settings were accepted")
            } catch let error as ConfigurationError {
                XCTAssert(error.localizedDescription.contains(reason) && !error.localizedDescription.contains("secret"))
            }
        }
        do {
            _ = try parser.parse("hy2://auth@example.com:20000-20010?mport=30000-30010")
            XCTFail("Conflicting hopping ports were accepted")
        } catch let error as ConfigurationError {
            XCTAssert(error.localizedDescription.contains("Conflicting"))
        }
    }

    func testUnsupportedSettings() throws {
        let modifications: [(inout [String: Any]) -> Void] = [
            { $0["settings"] = ["version": 1, "address": "example.com", "port": 443] },
            { $0["settings"] = ["version": 2, "address": "example.com", "port": true] },
            { $0["settings"] = ["version": 2, "address": "example.com", "port": 1.5] },
            { $0["proxySettings"] = ["tag": "secret"] },
            { $0["mux"] = ["enabled": true] },
        ]
        for modify in modifications {
            var profile = try fixture()
            var outbounds = profile["outbounds"] as! [[String: Any]]
            modify(&outbounds[0])
            profile["outbounds"] = outbounds
            try assertSkipped(profile)
        }
        let streamModifications: [(String, [String: Any])] = [
            ("hysteriaSettings", ["version": 2, "auth": "secret", "up": "20 mbps"]),
            ("hysteriaSettings", ["version": 2, "password": "secret"]),
            ("tlsSettings", ["serverName": "example.com", "fingerprint": "unsupported-secret"]),
            ("finalmask", ["udp": [["type": "sudoku", "settings": ["password": "secret"]]]]),
            ("finalmask", ["quicParams": ["secret": "secret"]]),
            ("finalmask", ["quicParams": ["congestion": "force-brutal"]]),
            ("finalmask", ["quicParams": ["brutalUp": "1 bps"]]),
            ("finalmask", ["quicParams": ["brutalUp": 100]]),
            ("finalmask", ["quicParams": ["udpHop": ["ports": "443", "interval": "1-2"]]]),
            ("finalmask", ["quicParams": ["maxIdleTimeout": true]]),
            ("finalmask", ["quicParams": ["maxIdleTimeout": 121]]),
            ("finalmask", ["quicParams": ["debug": true]]),
        ]
        for (key, value) in streamModifications {
            var profile = try fixture()
            var outbounds = profile["outbounds"] as! [[String: Any]]
            var stream = outbounds[0]["streamSettings"] as! [String: Any]
            stream[key] = value
            outbounds[0]["streamSettings"] = stream
            profile["outbounds"] = outbounds
            try assertSkipped(profile)
        }
    }

    func testPortHopping() throws {
        let profile = try fixture()
        let configuration = try importJSON(profile).importedEntries[0].configuration
        let mask = configuration.hysteria!.finalMask
        let masks = mask["udp"] as! [[String: Any]]
        XCTAssert(masks.map { $0["type"] as! String } == ["salamander", "udphop"])
        let hop = masks[1]["settings"] as! [String: Any]
        XCTAssert(hop["remotePorts"] as? String == "20000-20010,443" && hop["interval"] as? String == "5-10")
        XCTAssert(hop["mode"] as? String == "intervalremote")
        XCTAssert((mask["quicParams"] as! [String: Any])["udpHop"] == nil)
        XCTAssert(configuration.port == 443 && configuration.hysteriaShareLink == nil)

        func replacingMask(_ mask: [String: Any]) -> [String: Any] {
            var result = profile
            var outbounds = result["outbounds"] as! [[String: Any]]
            var stream = outbounds[0]["streamSettings"] as! [String: Any]
            stream["finalmask"] = mask
            outbounds[0]["streamSettings"] = stream
            result["outbounds"] = outbounds
            return result
        }

        // Old canonical JSON and Codable snapshots remain readable and migrate
        // to the supported mask schema, including refresh's stored source ID.
        var legacyMask = mask
        legacyMask["udp"] = [masks[0]]
        var legacyQUIC = mask["quicParams"] as! [String: Any]
        legacyQUIC["udpHop"] = ["ports": "20000-20010,443", "interval": "5-10"]
        legacyMask["quicParams"] = legacyQUIC
        var legacyProfile = replacingMask(legacyMask)
        let migrated = try importJSON(legacyProfile).importedEntries[0]
        XCTAssert(migrated.configuration == configuration)
        legacyProfile.removeValue(forKey: "remarks")
        let legacyID = String(
            decoding: try JSONSerialization.data(withJSONObject: legacyProfile, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        var snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        snapshot["rawLink"] = legacyID
        let decoded = try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONSerialization.data(withJSONObject: snapshot))
        XCTAssert(decoded.hysteria == configuration.hysteria)
        let reparsed = try parser.parse(decoded.rawLink)
        XCTAssert(reparsed.hysteria == configuration.hysteria && reparsed.port == configuration.port)
        XCTAssert(NSDictionary(dictionary: reparsed.hysteriaStreamSettings).isEqual(to: configuration.hysteriaStreamSettings))
        let sourceID = UUID()
        let saved = SavedConnection(
            id: UUID(), configuration: decoded, savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: legacyID),
            healthCheck: .unknown, customName: "Z personal name"
        )
        let other = try imported(Data("hy2://another@example.org#A%20other".utf8)).importedEntries[0]
        let replacement = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [saved], sourceID: sourceID, selectedConnectionID: saved.id,
            importedEntries: [other, migrated], fetchedAt: Date(), autoSelectFirstImported: false
        )
        let refreshed = replacement.savedConnections.first { $0.id == saved.id }!
        XCTAssert(replacement.selectedConnectionID == saved.id)
        XCTAssert(refreshed.customName == saved.customName && refreshed.savedAt == saved.savedAt && refreshed.healthCheck == saved.healthCheck)
        XCTAssert(refreshed.source?.subscriptionEntryID == migrated.sourceEntryID)
        let edited = try parser.parse(refreshed.configuration.withDisplayName("Edited").rawLink)
        XCTAssert(edited.hysteria == configuration.hysteria && edited.remarks == "Edited")

        let uri = try parser.parse("hy2://auth@example.com:20000-20010,443?obfs=salamander&obfs-password=example")
        XCTAssert(uri.hysteria?.quic?.udpHop?.interval == nil)
        let uriMasks = uri.hysteria!.finalMask["udp"] as! [[String: Any]]
        XCTAssert(uriMasks.map { $0["type"] as! String } == ["salamander", "udphop"])
        let uriRoundTrip = try parser.parse(uri.hysteriaShareLink!)
        XCTAssert(uriRoundTrip == uri)
        let sole = try importJSON(replacingMask(["udp": [["type": "udphop", "settings": ["mode": "intervalremote", "remotePorts": 20000, "interval": 5]]]]))
            .importedEntries[0].configuration
        XCTAssert(sole.hysteria?.quic?.udpHop == HysteriaPortHop(ports: "20000", interval: "5"))
        XCTAssert(sole.port == 443 && sole.hysteriaShareLink == nil)
        let singleBasePort = try importJSON(replacingMask(["udp": [["type": "udphop", "settings": ["mode": "intervalremote", "remotePorts": 443]]]]))
            .importedEntries[0].configuration
        XCTAssert(singleBasePort.hysteriaShareLink == nil, "A numeric URI port would discard the explicit hopping mask")
        let singleBaseRoundTrip = try parser.parse(singleBasePort.rawLink)
        XCTAssert(singleBaseRoundTrip == singleBasePort)

        var duplicatedLegacy = legacyMask
        duplicatedLegacy["udp"] = masks
        for invalidMask in [
            ["udp": Array(masks.reversed())], ["udp": [masks[0], masks[0]]], ["udp": [masks[1], masks[1]]],
            duplicatedLegacy,
        ] as [[String: Any]] {
            try assertSkipped(replacingMask(invalidMask))
        }
        for invalidSettings in [
            ["mode": "perconnremote", "remotePorts": "443"],
            ["mode": "intervallocal,intervalremote", "remotePorts": "443"],
            ["mode": "intervalremote", "remotePorts": "443", "remoteIPs": ["192.0.2.1"]],
            ["mode": "intervalremote"], ["remotePorts": "443"],
            ["mode": "intervalremote", "remotePorts": "0"],
            ["mode": "intervalremote", "remotePorts": "65536"],
            ["mode": "intervalremote", "remotePorts": true],
            ["mode": "intervalremote", "remotePorts": "10-1"],
            ["mode": "intervalremote", "remotePorts": "443", "interval": 4],
            ["mode": "intervalremote", "remotePorts": "443", "interval": true],
        ] as [[String: Any]] {
            try assertSkipped(replacingMask(["udp": [["type": "udphop", "settings": invalidSettings]]]))
        }
    }

    func assertSkipped(_ profile: [String: Any]) throws {
        let mixed = try importJSON([fixture(), profile])
        XCTAssert(mixed.importedEntries.count == 1 && mixed.skippedCount == 1)
        XCTAssert(!mixed.statusMessage!.contains("secret"), "Provider values must not appear in diagnostics")
        do {
            _ = try importJSON(profile)
            XCTFail("Entirely unsupported subscription must fail without replacing saved entries")
        } catch is SubscriptionError {}
    }

    func testPersistenceAndRefresh() throws {
        var profile = try fixture()
        let first = try importJSON(profile).importedEntries[0]
        profile["remarks"] = "Provider renamed this server"
        let reordered = try JSONSerialization.data(withJSONObject: [profile], options: [.prettyPrinted, .sortedKeys])
        let refreshed = try imported(reordered).importedEntries[0]
        XCTAssert(first.sourceEntryID == refreshed.sourceEntryID)
        let sourceID = UUID()
        let saved = SavedConnection(
            id: UUID(), configuration: first.configuration, savedAt: Date(timeIntervalSince1970: 100),
            source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: first.sourceEntryID), customName: "My server"
        )
        let replacement = SubscriptionConnectionReconciler().reconcile(
            existingConnections: [saved], sourceID: sourceID, selectedConnectionID: saved.id,
            importedEntries: [refreshed], fetchedAt: Date(), autoSelectFirstImported: false
        )
        XCTAssert(replacement.selectedConnectionID == saved.id)
        let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(replacement.savedConnections[0]))
        XCTAssert(restored.id == saved.id && restored.customName == saved.customName && restored.savedAt == saved.savedAt)
        let reparsed = try parser.parse(restored.configuration.rawLink)
        XCTAssert(reparsed == restored.configuration)
        let exported = try parser.parse(restored.shareableLink)
        XCTAssert(exported.remarks == "My server" && exported.hysteria == restored.configuration.hysteria)
        let duplicate = try importJSON([fixture(), fixture()])
        XCTAssert(duplicate.importedEntries.count == 1)
        let basic = try parser.parse("trojan://auth@example.com:443")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(basic)) as! [String: Any]
        legacy.removeValue(forKey: "hysteria")
        let old = try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssert(old == basic, "Existing snapshots must remain readable")
    }
}
