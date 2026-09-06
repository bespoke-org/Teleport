import Foundation

/// Parses the two shapes a WireGuard peer arrives in: the canonical `wg-quick`
/// `[Interface]`/`[Peer]` file that servers hand out, and the `wireguard://`
/// link some subscription providers emit. Both produce the same
/// `ConnectionConfiguration`, whose `rawLink` keeps the original text verbatim
/// because `AppViewModel` re-parses every stored `rawLink` on launch.
///
/// The peer endpoint becomes `host`/`port` so the VPN backend's protected-route
/// derivation, the health probe and duplicate filtering stay protocol-neutral.
/// The stream-layer fields (`security`, `transport`) are unused placeholders:
/// Xray's WireGuard outbound carries its own transport and encryption.
nonisolated struct WireGuardConfigurationParser {
    static let scheme = "wireguard"

    /// A configuration file carries no URL scheme, so it is recognised by its
    /// mandatory interface section rather than by a prefix of the whole text.
    static func looksLikeConfigurationFile(_ value: String) -> Bool {
        value.range(of: #"(?m)^\s*\[Interface\]\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func parseConfigurationFile(_ rawText: String) throws -> ConnectionConfiguration {
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        var peerCount = 0
        var section = ""
        var remarks: String?

        for line in rawText.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if let commentIndex = text.firstIndex(of: "#") {
                let comment = text[text.index(after: commentIndex)...].trimmingCharacters(in: .whitespaces)
                // The format has no name field, so the first comment doubles as one.
                if remarks == nil, !comment.isEmpty {
                    remarks = comment
                }
                text = String(text[..<commentIndex])
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if text.hasPrefix("["), text.hasSuffix("]") {
                section = text.lowercased()
                if section == "[peer]" {
                    peerCount += 1
                    guard peerCount == 1 else {
                        throw ConfigurationError.multipleWireGuardPeers
                    }
                }
                continue
            }

            guard let separator = text.firstIndex(of: "=") else { continue }
            let key = text[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[interface]":
                interface[key] = value
            case "[peer]":
                peer[key] = value
            default:
                continue
            }
        }

        guard peerCount > 0 else {
            throw ConfigurationError.missingParameter("[Peer]")
        }

        let endpoint = try Self.parseEndpoint(peer["endpoint"])

        return try makeConfiguration(
            rawLink: rawText,
            host: endpoint.host,
            port: endpoint.port,
            remarks: remarks,
            secretKey: interface["privatekey"],
            peerPublicKey: peer["publickey"],
            presharedKey: peer["presharedkey"],
            addresses: interface["address"],
            allowedIPs: peer["allowedips"],
            mtu: interface["mtu"],
            reserved: peer["reserved"],
            keepAlive: peer["persistentkeepalive"]
        )
    }

    /// `wireguard://<secret key>@<endpoint>?publickey=…`. The scheme is not
    /// standardised, so the aliases accepted here mirror what the common
    /// generators emit rather than a specification.
    func parseLink(
        _ rawLink: String,
        host: String,
        port: Int,
        remarks: String?,
        secretKey: String?,
        query: [String: String]
    ) throws -> ConnectionConfiguration {
        try makeConfiguration(
            rawLink: rawLink,
            host: host,
            port: port,
            remarks: remarks,
            secretKey: secretKey,
            peerPublicKey: query["publickey"] ?? query["pbk"],
            presharedKey: query["presharedkey"] ?? query["psk"],
            addresses: query["address"] ?? query["ip"],
            allowedIPs: query["allowedips"],
            mtu: query["mtu"],
            reserved: query["reserved"],
            keepAlive: query["keepalive"] ?? query["persistentkeepalive"]
        )
    }

    private func makeConfiguration(
        rawLink: String,
        host: String,
        port: Int,
        remarks: String?,
        secretKey: String?,
        peerPublicKey: String?,
        presharedKey: String?,
        addresses: String?,
        allowedIPs: String?,
        mtu: String?,
        reserved: String?,
        keepAlive: String?
    ) throws -> ConnectionConfiguration {
        let parsedAddresses = Self.commaSeparatedValues(addresses)
        guard !parsedAddresses.isEmpty else {
            throw ConfigurationError.missingParameter("Address")
        }

        let parsedAllowedIPs = Self.commaSeparatedValues(allowedIPs)

        return ConnectionConfiguration(
            rawLink: rawLink,
            protocolType: .wireguard,
            host: host,
            port: port,
            remarks: remarks,
            security: .none,
            transport: .tcp,
            path: nil,
            hostHeader: nil,
            serverName: nil,
            alpn: [],
            fingerprint: nil,
            publicKey: nil,
            shortID: nil,
            spiderX: nil,
            vlessUserID: nil,
            vlessFlow: nil,
            trojanPassword: nil,
            wireguard: WireGuardParameters(
                secretKey: try Self.normalizedKey(secretKey, name: "PrivateKey"),
                peerPublicKey: try Self.normalizedKey(peerPublicKey, name: "PublicKey"),
                presharedKey: try presharedKey.flatMap { $0.isEmpty ? nil : $0 }
                    .map { try Self.normalizedKey($0, name: "PresharedKey") },
                addresses: parsedAddresses,
                allowedIPs: parsedAllowedIPs.isEmpty ? WireGuardParameters.defaultAllowedIPs : parsedAllowedIPs,
                mtu: Self.positiveInteger(mtu),
                reserved: Self.parseReserved(reserved),
                persistentKeepalive: Self.positiveInteger(keepAlive)
            )
        )
    }

    /// Accepts base64url as well as standard base64 and always returns the
    /// padded standard form, which is what Xray's key parser expects.
    static func normalizedKey(_ value: String?, name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigurationError.missingParameter(name)
        }
        var base64 = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: base64), decoded.count == 32 else {
            throw ConfigurationError.invalidWireGuardKey(name)
        }
        return base64
    }

    static func parseEndpoint(_ value: String?) throws -> (host: String, port: Int) {
        guard let value, !value.isEmpty else {
            throw ConfigurationError.missingParameter("Endpoint")
        }

        if value.hasPrefix("["), let closingBracket = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex) ..< closingBracket])
            let rest = value[value.index(after: closingBracket)...]
            guard host.isEmpty == false else { throw ConfigurationError.missingHost }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1 ... 65535).contains(port) else {
                throw ConfigurationError.invalidPort
            }
            return (host, port)
        }

        guard let separator = value.lastIndex(of: ":") else {
            throw ConfigurationError.invalidPort
        }
        let host = String(value[..<separator])
        guard !host.isEmpty else { throw ConfigurationError.missingHost }
        guard let port = Int(value[value.index(after: separator)...]), (1 ... 65535).contains(port) else {
            throw ConfigurationError.invalidPort
        }
        return (host, port)
    }

    /// Xray expects three bytes. Generators write them either as decimal numbers
    /// or, for WARP-style profiles, as a base64 client identifier.
    static func parseReserved(_ value: String?) -> [Int]? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }

        let numbers = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count == 3, numbers.allSatisfy({ (0 ... 255).contains($0) }) {
            return numbers
        }

        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        if let decoded = Data(base64Encoded: base64), decoded.count == 3 {
            return decoded.map(Int.init)
        }

        return nil
    }

    static func commaSeparatedValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func positiveInteger(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value.trimmingCharacters(in: .whitespaces)), parsed > 0 else {
            return nil
        }
        return parsed
    }
}
