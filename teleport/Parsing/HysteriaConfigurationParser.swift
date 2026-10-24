import CoreFoundation
import Foundation

/// Fields supported by the bundled Xray 26.10.21 Hysteria 2 transport. The saved
/// representation is canonical Xray JSON: standard share links cannot carry all
/// the QUIC settings, and saved configurations are reparsed on launch.
nonisolated struct HysteriaParameters: Codable, Equatable, Sendable {
    let auth: String
    let udpIdleTimeout: Int?
    let obfuscation: HysteriaObfuscation?
    let quic: HysteriaQUICParameters?
    let pinnedPeerCertSHA256: String?

    var transportSettings: [String: Any] {
        var result: [String: Any] = ["version": 2, "auth": auth]
        result["udpIdleTimeout"] = udpIdleTimeout
        return result
    }

    var finalMask: [String: Any] {
        var result: [String: Any] = [:]
        var masks: [[String: Any]] = []
        if let obfuscation {
            var settings: [String: Any] = ["password": obfuscation.password]
            settings["packetSize"] = obfuscation.packetSize
            masks.append(["type": "salamander", "settings": settings])
        }
        // Xray reverses the array before wrapping sockets. The mask that owns
        // dialing must be last, underneath Salamander/Gecko on every hop.
        if let hop = quic?.udpHop { masks.append(["type": "udphop", "settings": hop.settings]) }
        if !masks.isEmpty { result["udp"] = masks }
        if let quic, !quic.settings.isEmpty { result["quicParams"] = quic.settings }
        return result
    }

    func streamSettings(serverName: String, alpn: [String], fingerprint: String?) -> [String: Any] {
        var tls: [String: Any] = ["serverName": serverName, "alpn": alpn]
        tls["pinnedPeerCertSha256"] = pinnedPeerCertSHA256
        tls["fingerprint"] = fingerprint
        var result: [String: Any] = [
            "network": "hysteria", "security": "tls", "tlsSettings": tls,
            "hysteriaSettings": transportSettings,
        ]
        if !finalMask.isEmpty { result["finalmask"] = finalMask }
        return result
    }
}

nonisolated struct HysteriaObfuscation: Codable, Equatable, Sendable {
    // The Hysteria URI has no packet-size field; Gecko links use these upstream
    // defaults. Custom JSON ranges must stay JSON when shared.
    static let geckoDefaultPacketSize = "512-1200"
    let password: String
    /// A nonempty packet size enables Xray's Gecko variant of Salamander.
    let packetSize: String?
}

nonisolated struct HysteriaPortHop: Codable, Equatable, Sendable {
    let ports: String
    let interval: String?

    var settings: [String: Any] {
        var result: [String: Any] = ["mode": "intervalremote", "remotePorts": ports]
        result["interval"] = interval
        return result
    }
}

nonisolated struct HysteriaQUICParameters: Codable, Equatable, Sendable {
    var congestion: String?
    var bbrProfile: String?
    var brutalUp: String?
    var brutalDown: String?
    // Retain the original Codable location so installed snapshots still decode.
    // Runtime and canonical JSON serialize this as a finalmask.udp mask instead.
    var udpHop: HysteriaPortHop?
    var initStreamReceiveWindow: Int?
    var maxStreamReceiveWindow: Int?
    var initConnectionReceiveWindow: Int?
    var maxConnectionReceiveWindow: Int?
    var maxIdleTimeout: Int?
    var keepAlivePeriod: Int?
    var disablePathMTUDiscovery: Bool?
    var maxIncomingStreams: Int?

    var settings: [String: Any] {
        var result: [String: Any] = [:]
        result["congestion"] = congestion
        result["bbrProfile"] = bbrProfile
        result["brutalUp"] = brutalUp
        result["brutalDown"] = brutalDown
        result["initStreamReceiveWindow"] = initStreamReceiveWindow
        result["maxStreamReceiveWindow"] = maxStreamReceiveWindow
        result["initConnectionReceiveWindow"] = initConnectionReceiveWindow
        result["maxConnectionReceiveWindow"] = maxConnectionReceiveWindow
        result["maxIdleTimeout"] = maxIdleTimeout
        result["keepAlivePeriod"] = keepAlivePeriod
        result["disablePathMTUDiscovery"] = disablePathMTUDiscovery
        result["maxIncomingStreams"] = maxIncomingStreams
        return result
    }
}

nonisolated extension ConnectionConfiguration {
    var hysteriaStreamSettings: [String: Any] {
        guard let hysteria else { return [:] }
        return hysteria.streamSettings(serverName: serverName ?? host, alpn: alpn, fingerprint: fingerprint)
    }

    var hysteriaShareLink: String? {
        guard let hysteria, hysteria.udpIdleTimeout == nil, fingerprint == nil,
            hysteria.obfuscation?.packetSize == nil || hysteria.obfuscation?.packetSize == HysteriaObfuscation.geckoDefaultPacketSize,
            alpn == ["h3"]
        else { return nil }
        var quic = hysteria.quic
        let ports = quic?.udpHop?.ports
        // A lone numeric URI port means no hopping on reimport. Keep an explicit
        // single-port hopping mask in JSON even when it matches the base port.
        if let ports, !ports.contains(","), !ports.contains("-") { return nil }
        if let ports, Int(ports.split(whereSeparator: { $0 == "," || $0 == "-" }).first ?? "") != port {
            // A URI has only one authority. Do not change the saved base port
            // when the JSON profile lists a different first hopping port.
            return nil
        }
        guard quic?.udpHop?.interval == nil else { return nil }
        quic?.udpHop = nil
        guard quic?.settings.isEmpty != false else { return nil }

        var components = URLComponents()
        components.scheme = "hysteria2"
        var userCharacters = CharacterSet.urlUserAllowed
        userCharacters.remove(charactersIn: ":@/?#[]%")
        components.percentEncodedUser = hysteria.auth.isEmpty ? nil : hysteria.auth.addingPercentEncoding(withAllowedCharacters: userCharacters)
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = "/"
        var query: [URLQueryItem] = []
        if let serverName { query.append(URLQueryItem(name: "sni", value: serverName)) }
        if let pin = hysteria.pinnedPeerCertSHA256 {
            guard !pin.contains(",") else { return nil }
            query.append(URLQueryItem(name: "pinSHA256", value: pin))
        }
        if let obfuscation = hysteria.obfuscation {
            query.append(URLQueryItem(name: "obfs", value: obfuscation.packetSize == nil ? "salamander" : "gecko"))
            query.append(URLQueryItem(name: "obfs-password", value: obfuscation.password))
        }
        if !query.isEmpty { components.queryItems = query.sorted { $0.name < $1.name } }
        components.percentEncodedFragment = remarks?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        guard let link = components.string else { return nil }
        // URLComponents requires a single numeric port. Hysteria's URI grammar
        // also permits a port list; replace only the authority's port suffix.
        guard let ports else { return link }
        guard let end = link.range(of: "/", range: link.index(link.startIndex, offsetBy: "hysteria2://".count)..<link.endIndex),
            let colon = link[..<end.lowerBound].lastIndex(of: ":")
        else { return nil }
        return String(link[..<link.index(after: colon)]) + ports + String(link[end.lowerBound...])
    }

    var shareExportNote: String? {
        guard protocolType == .hysteria, hysteriaShareLink == nil else { return nil }
        return "These settings cannot be preserved in a Hysteria 2 share link. Copy the Xray configuration instead."
    }
}

nonisolated struct HysteriaConfigurationParser {
    func parseOutbound(_ outbound: [String: Any], remarks: String?) throws -> ConnectionConfiguration {
        let settings = try object(outbound["settings"])
        try keys(settings, ["version", "address", "port"], "outbound settings")
        guard try integer(settings, "version") == 2 else { throw invalid("Only Hysteria 2 is supported") }
        let host = try string(settings, "address", required: true)!.lowercased()
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
            host.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#%[]")) == nil
        else {
            throw invalid("Invalid Hysteria server address")
        }
        guard let port = try integer(settings, "port"), (1...65535).contains(port) else { throw invalid("Invalid Hysteria server port") }
        let stream = try object(outbound["streamSettings"])
        try keys(stream, ["network", "security", "tlsSettings", "hysteriaSettings", "finalmask"], "stream settings")
        guard try string(stream, "network") == "hysteria", try string(stream, "security") == "tls" else {
            throw invalid("Hysteria 2 requires the Hysteria transport and TLS")
        }
        let transport = try object(stream["hysteriaSettings"])
        try keys(transport, ["version", "auth", "udpIdleTimeout"], "transport settings")
        guard try integer(transport, "version") == 2 else { throw invalid("Only Hysteria 2 is supported") }
        let tls = try optionalObject(stream, "tlsSettings")
        try keys(tls, ["serverName", "alpn", "allowInsecure", "pinnedPeerCertSha256", "fingerprint"], "TLS settings")
        // Xray validates these presets even though Hysteria uses Go TLS and
        // QUIC's Chrome parroting rather than the TCP uTLS ClientHello. Preserve
        // the configured value through JSON import, storage and export.
        let fingerprint = try string(tls, "fingerprint").flatMap { $0.isEmpty ? nil : $0.lowercased() }
        if let fingerprint,
            !["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized", "randomizednoalpn", "unsafe"].contains(fingerprint)
        {
            throw invalid("Unsupported Hysteria TLS fingerprint")
        }
        let sni = try string(tls, "serverName")
        let serverName = sni.flatMap { $0.isEmpty ? nil : $0 } ?? host
        let alpn: [String]
        if let value = tls["alpn"] {
            guard let items = value as? [String], !items.isEmpty, items.allSatisfy({ !$0.isEmpty }), items.contains("h3") else {
                throw invalid("Hysteria TLS ALPN must include h3")
            }
            alpn = items
        } else {
            alpn = ["h3"]
        }
        let allowsInsecure = try boolean(tls, "allowInsecure") ?? false
        guard !allowsInsecure else {
            throw invalid("The bundled Xray does not support insecure Hysteria TLS; use a trusted certificate or a SHA-256 certificate pin")
        }
        let pin = try certificatePins(tls)
        let finalMask = try optionalObject(stream, "finalmask")
        try keys(finalMask, ["udp", "quicParams"], "FinalMask settings")
        var quic = try parseQUIC(try optionalObject(finalMask, "quicParams"))
        let masks = try parseMasks(finalMask["udp"])
        if let hop = masks.hop {
            guard quic.udpHop == nil else { throw invalid("Duplicate Hysteria port hopping settings") }
            quic.udpHop = hop
        }
        let parameters = HysteriaParameters(
            auth: try string(transport, "auth") ?? "",
            udpIdleTimeout: try boundedInteger(transport, "udpIdleTimeout", 2...600),
            obfuscation: masks.obfuscation, quic: quic.settings.isEmpty && quic.udpHop == nil ? nil : quic,
            pinnedPeerCertSHA256: pin
        )

        let canonicalStream = parameters.streamSettings(serverName: serverName, alpn: alpn, fingerprint: fingerprint)
        var profile: [String: Any] = [
            "outbounds": [
                [
                    "protocol": "hysteria", "settings": ["version": 2, "address": host, "port": port], "streamSettings": canonicalStream,
                ]
            ]
        ]
        if let remarks, !remarks.isEmpty { profile["remarks"] = remarks }
        let data = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys, .withoutEscapingSlashes])
        return ConnectionConfiguration(
            rawLink: String(decoding: data, as: UTF8.self), protocolType: .hysteria, host: host, port: port,
            remarks: remarks?.isEmpty == false ? remarks : nil, security: .tls, transport: .hysteria,
            path: nil, hostHeader: nil, serverName: serverName, alpn: alpn, fingerprint: fingerprint,
            publicKey: nil, shortID: nil, spiderX: nil, vlessUserID: nil, vlessFlow: nil, trojanPassword: nil,
            allowsInsecureTLS: allowsInsecure, hysteria: parameters
        )
    }

    func parseLink(_ link: String) throws -> ConnectionConfiguration {
        // Split the authority first because Foundation rejects multi-port URLs.
        guard let separator = link.range(of: "://") else { throw invalid("Invalid Hysteria 2 link") }
        let authorityStart = separator.upperBound
        let authorityEnd = link[authorityStart...].firstIndex(where: { "/?#".contains($0) }) ?? link.endIndex
        let authority = link[authorityStart..<authorityEnd]
        let endpointStart = authority.lastIndex(of: "@").map { link.index(after: $0) } ?? authorityStart
        let endpoint = link[endpointStart..<authorityEnd]
        let portSeparator: String.Index?
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { throw invalid("Invalid Hysteria server address") }
            let after = link.index(after: close)
            portSeparator = after < authorityEnd && link[after] == ":" ? after : nil
        } else {
            portSeparator = endpoint.lastIndex(of: ":")
        }
        var normalizedLink = link
        var hoppingPorts: String?
        if let portSeparator {
            let ports = String(link[link.index(after: portSeparator)..<authorityEnd])
            guard !ports.isEmpty else { throw invalid("Invalid Hysteria server port") }
            if ports.contains(",") || ports.contains("-") {
                hoppingPorts = try portList(ports)
                let first = hoppingPorts!.split(whereSeparator: { $0 == "," || $0 == "-" })[0]
                normalizedLink = String(link[..<link.index(after: portSeparator)]) + first + String(link[authorityEnd...])
            }
        }
        guard let components = URLComponents(string: normalizedLink),
            ["hy2", "hysteria2"].contains(components.scheme?.lowercased() ?? ""),
            let componentHost = components.host, !componentHost.isEmpty,
            components.path.isEmpty || components.path == "/"
        else { throw invalid("Invalid Hysteria 2 link") }
        let host = componentHost.hasPrefix("[") ? String(componentHost.dropFirst().dropLast()) : componentHost
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw invalid("Malformed Hysteria link parameters") }
            query[item.name] = value
        }
        if query["ech"] != nil { throw invalid("Hysteria ECH links are not supported") }
        if query["upmbps"] != nil || query["downmbps"] != nil {
            throw invalid("Hysteria link bandwidth settings are not supported; use Xray JSON for explicit bandwidth configuration")
        }
        // These common extensions have explicit mappings. Unknown connection
        // settings still fail import instead of silently changing their meaning.
        try keys(query, ["sni", "insecure", "obfs", "obfs-password", "pinSHA256", "mport", "alpn", "fp"], "share-link parameters")
        if let multiPort = query["mport"] {
            let ports = try portList(multiPort)
            guard hoppingPorts == nil || hoppingPorts == ports else { throw invalid("Conflicting Hysteria hopping ports") }
            hoppingPorts = ports
        }
        var tls: [String: Any] = [:]
        tls["serverName"] = query["sni"]
        tls["pinnedPeerCertSha256"] = query["pinSHA256"]
        tls["fingerprint"] = query["fp"]
        if let alpn = query["alpn"] { tls["alpn"] = alpn.components(separatedBy: ",") }
        if let insecure = query["insecure"] {
            guard insecure == "0" || insecure == "1" else { throw invalid("Hysteria insecure must be 0 or 1") }
            tls["allowInsecure"] = insecure == "1"
        }
        var finalMask: [String: Any] = [:]
        if let obfs = query["obfs"] {
            guard ["salamander", "gecko"].contains(obfs) else { throw invalid("Unsupported Hysteria link obfuscation; use salamander or gecko") }
            guard let password = query["obfs-password"], !password.isEmpty else {
                throw invalid("Hysteria link obfuscation requires a password")
            }
            var settings: [String: Any] = ["password": password]
            if obfs == "gecko" { settings["packetSize"] = HysteriaObfuscation.geckoDefaultPacketSize }
            finalMask["udp"] = [["type": "salamander", "settings": settings]]
        } else if query["obfs-password"] != nil {
            throw invalid("Hysteria obfuscation password requires an obfuscation type")
        }
        if let hoppingPorts {
            var masks = finalMask["udp"] as? [[String: Any]] ?? []
            masks.append(["type": "udphop", "settings": HysteriaPortHop(ports: hoppingPorts, interval: nil).settings])
            finalMask["udp"] = masks
        }
        // Decode explicitly, once, across Foundation versions. The decoded
        // user/password/fragment accessors differ between macOS releases.
        var auth = components.percentEncodedUser?.removingPercentEncoding ?? ""
        if let password = components.percentEncodedPassword?.removingPercentEncoding { auth += ":" + password }
        return try parseOutbound(
            [
                "settings": ["version": 2, "address": host, "port": components.port ?? 443],
                "streamSettings": [
                    "network": "hysteria", "security": "tls", "tlsSettings": tls,
                    "hysteriaSettings": ["version": 2, "auth": auth], "finalmask": finalMask,
                ],
            ], remarks: components.percentEncodedFragment?.removingPercentEncoding)
    }

    private func parseMasks(_ value: Any?) throws -> (obfuscation: HysteriaObfuscation?, hop: HysteriaPortHop?) {
        guard let value else { return (nil, nil) }
        guard let masks = value as? [[String: Any]] else { throw invalid("Invalid Hysteria UDP masks") }
        var obfuscation: HysteriaObfuscation?
        var hop: HysteriaPortHop?
        for (index, mask) in masks.enumerated() {
            try keys(mask, ["type", "settings"], "UDP mask")
            let settings = try object(mask["settings"])
            switch try string(mask, "type") {
            case "salamander":
                guard obfuscation == nil else { throw invalid("Duplicate Hysteria obfuscation masks") }
                try keys(settings, ["password", "packetSize"], "Salamander settings")
                obfuscation = HysteriaObfuscation(
                    password: try string(settings, "password", required: true)!,
                    packetSize: try range(settings["packetSize"], bounds: 1...2048)
                )
            case "udphop":
                guard hop == nil else { throw invalid("Duplicate Hysteria port hopping settings") }
                guard index == masks.count - 1 else { throw invalid("Hysteria port hopping must be the last UDP mask") }
                try keys(settings, ["mode", "remotePorts", "interval"], "port hopping mask")
                guard try string(settings, "mode")?.lowercased() == "intervalremote" else {
                    throw invalid("Hysteria port hopping requires intervalremote mode")
                }
                hop = try parseHop(settings, portsKey: "remotePorts")
            default:
                throw invalid("Unsupported Hysteria UDP mask type")
            }
        }
        return (obfuscation, hop)
    }

    private func parseHop(_ settings: [String: Any], portsKey: String) throws -> HysteriaPortHop {
        let ports: String
        if let text = settings[portsKey] as? String {
            ports = try portList(text)
        } else if let port = try integer(settings, portsKey), (1...65535).contains(port) {
            ports = String(port)
        } else {
            throw invalid("Invalid Hysteria hopping ports")
        }
        return HysteriaPortHop(ports: ports, interval: try range(settings["interval"], bounds: 5...Int(Int32.max)))
    }

    private func parseQUIC(_ settings: [String: Any]) throws -> HysteriaQUICParameters {
        try keys(
            settings,
            [
                "congestion", "bbrProfile", "brutalUp", "brutalDown", "udpHop", "initStreamReceiveWindow", "maxStreamReceiveWindow",
                "initConnectionReceiveWindow", "maxConnectionReceiveWindow", "maxIdleTimeout", "keepAlivePeriod",
                "disablePathMTUDiscovery", "maxIncomingStreams", "debug",
            ], "QUIC parameters")
        if try boolean(settings, "debug") == true { throw invalid("Hysteria QUIC debug logging is not supported") }
        let congestion = try string(settings, "congestion")?.lowercased()
        if let congestion, !["", "reno", "bbr", "brutal", "force-brutal"].contains(congestion) {
            throw invalid("Unsupported Hysteria congestion control")
        }
        let bbr = try string(settings, "bbrProfile")?.lowercased()
        if let bbr, !["", "conservative", "standard", "aggressive"].contains(bbr) { throw invalid("Unsupported Hysteria BBR profile") }
        let up = try bandwidth(settings, "brutalUp")
        let down = try bandwidth(settings, "brutalDown")
        if congestion == "force-brutal", up == nil || up == "0" { throw invalid("Hysteria force-brutal requires upload bandwidth") }
        var hop: HysteriaPortHop?
        if let value = settings["udpHop"] {
            // Compatibility with the first Teleport Hysteria build. The pinned
            // core ignores this old field, so never emit it back to Xray.
            let values = try object(value)
            try keys(values, ["ports", "interval"], "port hopping")
            hop = try parseHop(values, portsKey: "ports")
        }
        return HysteriaQUICParameters(
            congestion: congestion?.isEmpty == false ? congestion : nil, bbrProfile: bbr?.isEmpty == false ? bbr : nil,
            brutalUp: up, brutalDown: down, udpHop: hop,
            initStreamReceiveWindow: try boundedInteger(settings, "initStreamReceiveWindow", 16384...Int.max),
            maxStreamReceiveWindow: try boundedInteger(settings, "maxStreamReceiveWindow", 16384...Int.max),
            initConnectionReceiveWindow: try boundedInteger(settings, "initConnectionReceiveWindow", 16384...Int.max),
            maxConnectionReceiveWindow: try boundedInteger(settings, "maxConnectionReceiveWindow", 16384...Int.max),
            maxIdleTimeout: try boundedInteger(settings, "maxIdleTimeout", 4...120),
            keepAlivePeriod: try boundedInteger(settings, "keepAlivePeriod", 2...60),
            disablePathMTUDiscovery: try boolean(settings, "disablePathMTUDiscovery"),
            maxIncomingStreams: try boundedInteger(settings, "maxIncomingStreams", 8...Int.max)
        )
    }

    private func bandwidth(_ settings: [String: Any], _ key: String) throws -> String? {
        guard let value = try string(settings, key), !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
        let number = String(normalized.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") }))
        let unit = normalized.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let multipliers: [String: Double] = [
            "": 1, "b": 1, "bps": 1, "k": 1024, "kb": 1024, "kbps": 1024,
            "m": 1_048_576, "mb": 1_048_576, "mbps": 1_048_576, "g": 1_073_741_824, "gb": 1_073_741_824, "gbps": 1_073_741_824,
            "t": 1_099_511_627_776, "tb": 1_099_511_627_776, "tbps": 1_099_511_627_776,
        ]
        guard let amount = Double(number), let multiplier = multipliers[unit], amount.isFinite, amount >= 0,
            amount * multiplier < Double(UInt64.max), amount == 0 || amount * multiplier / 8 >= 65536
        else {
            throw invalid("Invalid Hysteria bandwidth; use a rate such as 20 mbps")
        }
        return amount == 0 ? "0" : normalized
    }

    private func certificatePins(_ tls: [String: Any]) throws -> String? {
        guard let value = try string(tls, "pinnedPeerCertSha256"), !value.isEmpty else { return nil }
        let pins = try value.split(separator: ",", omittingEmptySubsequences: false).map { item -> String in
            let pin = item.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "").lowercased()
            guard pin.count == 64, pin.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw invalid("Invalid Hysteria SHA-256 certificate pin")
            }
            return pin
        }
        return pins.joined(separator: ",")
    }

    private func portList(_ text: String) throws -> String {
        let items = text.split(separator: ",", omittingEmptySubsequences: false)
        guard !items.isEmpty else { throw invalid("Invalid Hysteria hopping ports") }
        return try items.map { item in
            guard let normalized = try range(String(item), bounds: 1...65535) else { throw invalid("Invalid Hysteria hopping ports") }
            return normalized
        }.joined(separator: ",")
    }

    private func range(_ value: Any?, bounds: ClosedRange<Int>) throws -> String? {
        guard let value else { return nil }
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = try integer(["value": value], "value") {
            text = String(number)
        } else {
            throw invalid("Invalid Hysteria range")
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { throw invalid("Invalid Hysteria range") }
        let numbers = try parts.map { part -> Int in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part), bounds.contains(number) else {
                throw invalid("Invalid Hysteria range")
            }
            return number
        }
        guard numbers.first! <= numbers.last! else { throw invalid("Invalid Hysteria range") }
        return numbers.map(String.init).joined(separator: "-")
    }

    private func boundedInteger(_ value: [String: Any], _ key: String, _ bounds: ClosedRange<Int>) throws -> Int? {
        guard let number = try integer(value, key), number != 0 else { return nil }
        guard bounds.contains(number) else { throw invalid("Invalid Hysteria \(key)") }
        return number
    }

    private func integer(_ value: [String: Any], _ key: String) throws -> Int? {
        guard let item = value[key] else { return nil }
        guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue >= 0, number.doubleValue < Double(Int.max), number.doubleValue == Double(number.intValue)
        else {
            throw invalid("Invalid Hysteria \(key)")
        }
        return number.intValue
    }

    private func boolean(_ value: [String: Any], _ key: String) throws -> Bool? {
        guard let item = value[key] else { return nil }
        guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("Invalid Hysteria \(key)") }
        return number.boolValue
    }

    private func string(_ value: [String: Any], _ key: String, required: Bool = false) throws -> String? {
        guard let item = value[key] else {
            if required { throw invalid("Missing Hysteria \(key)") }
            return nil
        }
        guard let text = item as? String, !required || !text.isEmpty else { throw invalid("Invalid Hysteria \(key)") }
        return text
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw invalid("Invalid Hysteria configuration") }
        return result
    }

    private func optionalObject(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        guard let nested = value[key] else { return [:] }
        return try object(nested)
    }

    private func keys(_ value: [String: Any], _ allowed: Set<String>, _ section: String) throws {
        guard Set(value.keys).isSubset(of: allowed) else { throw invalid("Unsupported Hysteria \(section)") }
    }

    private func invalid(_ reason: String) -> ConfigurationError { .invalidHysteria(reason) }
}
