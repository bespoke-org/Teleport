import Foundation
import Network

nonisolated struct ShadowsocksParameters: Codable, Equatable, Sendable {
    let method: String
    let password: String

    init(method: String, password: String) throws {
        let aliases = [
            "chacha20-poly1305": "chacha20-ietf-poly1305", "aead_chacha20_poly1305": "chacha20-ietf-poly1305",
            "xchacha20-poly1305": "xchacha20-ietf-poly1305", "aead_xchacha20_poly1305": "xchacha20-ietf-poly1305",
            "aead_aes_128_gcm": "aes-128-gcm", "aead_aes_256_gcm": "aes-256-gcm",
        ]
        let normalized = aliases[method.lowercased()] ?? method.lowercased()
        let methods = [
            "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        ]
        guard methods.contains(normalized) else {
            throw ConfigurationError.invalidShadowsocks("Unsupported Shadowsocks cipher; use an AEAD or AEAD-2022 method")
        }
        guard !password.isEmpty else { throw ConfigurationError.invalidShadowsocks("Shadowsocks password is missing") }
        if normalized.hasPrefix("2022-") {
            let keys = password.split(separator: ":", omittingEmptySubsequences: false)
            let length = normalized == "2022-blake3-aes-128-gcm" ? 16 : 32
            guard
                keys.allSatisfy({ key in
                    guard let data = Data(base64Encoded: String(key)), data.count == length else { return false }
                    return data.base64EncodedString() == key
                })
            else {
                throw ConfigurationError.invalidShadowsocks("Shadowsocks 2022 requires base64 keys of \(length) bytes, separated by colons for AES key chains")
            }
            if normalized == "2022-blake3-chacha20-poly1305", keys.count != 1 {
                throw ConfigurationError.invalidShadowsocks("Shadowsocks 2022 ChaCha20 supports one key only")
            }
        }
        self.method = normalized
        self.password = password
    }
}

/// Native TCP/UDP Shadowsocks only. Unsupported stream wrappers and plugins
/// must fail import rather than produce a connection with different behavior.
nonisolated struct ShadowsocksConfigurationParser {
    private typealias V = XrayProfileValidation

    func parseLink(_ link: String) throws -> ConnectionConfiguration {
        let body = String(link.dropFirst("ss://".count))
        let authority = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        // Older clients encode the complete authority. Convert it to SIP002
        // before URL parsing; the base64 payload itself can contain '/'.
        if !authority.contains("@") {
            guard !authority.contains("?"), let decoded = decodeBase64(String(authority)),
                let at = decoded.lastIndex(of: "@")
            else { throw invalid("Invalid Shadowsocks link credentials") }
            let credentials = try splitCredentials(String(decoded[..<at]))
            guard !credentials.0.lowercased().hasPrefix("2022-") else {
                throw invalid("Shadowsocks 2022 links require percent-encoded credentials")
            }
            let endpoint = String(decoded[decoded.index(after: at)...])
            let fragment = body.firstIndex(of: "#").map { String(body[$0...]) } ?? ""
            return try parseLink("ss://\(encode(credentials.0)):\(encode(credentials.1))@\(endpoint)\(fragment)")
        }
        // Some clients use standard base64 here. Escape its '/' before asking
        // URLComponents to distinguish the authority from a path.
        var normalizedLink = link
        if let at = body.firstIndex(of: "@") {
            let user = String(body[..<at])
            if !user.contains(":"), let decoded = user.removingPercentEncoding {
                normalizedLink = "ss://\(encode(decoded))@" + body[body.index(after: at)...]
            }
        }
        guard let url = URLComponents(string: normalizedLink, encodingInvalidCharacters: false), url.scheme?.lowercased() == "ss",
            url.path.isEmpty || url.path == "/", let encodedUser = url.percentEncodedUser
        else {
            throw invalid("Invalid Shadowsocks link")
        }
        var queryNames = Set<String>()
        for item in url.queryItems ?? [] {
            guard queryNames.insert(item.name).inserted else { throw invalid("Duplicate Shadowsocks link option") }
            guard item.name == "plugin", item.value?.isEmpty != false else {
                throw invalid("Shadowsocks plugins and extra link options are not supported")
            }
        }
        let credentials: (String, String)
        if let encodedPassword = url.percentEncodedPassword {
            guard let method = encodedUser.removingPercentEncoding, let password = encodedPassword.removingPercentEncoding else {
                throw invalid("Invalid Shadowsocks link credentials")
            }
            credentials = (method, password)
        } else {
            guard let user = encodedUser.removingPercentEncoding, let decoded = decodeBase64(user) else {
                throw invalid("Invalid Shadowsocks base64 credentials")
            }
            credentials = try splitCredentials(decoded)
            guard !credentials.0.lowercased().hasPrefix("2022-") else {
                throw invalid("Shadowsocks 2022 links require percent-encoded credentials")
            }
        }
        guard let host = url.host, let port = url.port else { throw invalid("Shadowsocks server address and port are required") }
        return try configuration(
            host: host, port: port, method: credentials.0, password: credentials.1,
            remarks: url.percentEncodedFragment?.removingPercentEncoding)
    }

    func parseOutbound(_ outbound: [String: Any], remarks: String?) throws -> ConnectionConfiguration {
        let settings = try V.object(outbound["settings"], "Shadowsocks settings")
        let endpoint: [String: Any]
        if let servers = settings["servers"] {
            try V.keys(settings, ["servers"], "Shadowsocks settings")
            guard let servers = servers as? [[String: Any]], servers.count == 1 else {
                throw invalid("Shadowsocks outbounds require exactly one server")
            }
            endpoint = servers[0]
        } else {
            endpoint = settings
        }
        try V.keys(endpoint, ["address", "port", "method", "password", "email", "level"], "Shadowsocks endpoint")
        if let email = endpoint["email"], !(email is String) { throw invalid("Invalid Shadowsocks email metadata") }
        if let level = endpoint["level"] { _ = try V.number(level, "Shadowsocks user level", max: 255) }
        let stream = try V.object(outbound["streamSettings"] ?? [:], "Shadowsocks stream settings")
        let network = try optionalString(stream, "network") ?? "tcp"
        guard ["tcp", "raw"].contains(network), try optionalString(stream, "security") ?? "none" == "none" else {
            throw invalid("Shadowsocks supports native TCP/UDP only; transport wrappers are not supported")
        }
        try V.keys(stream, ["network", "security", "tcpSettings", "rawSettings", "sockopt"], "Shadowsocks stream settings")
        for key in ["tcpSettings", "rawSettings"] {
            let transport = try V.object(stream[key] ?? [:], "Shadowsocks TCP settings")
            try V.keys(transport, ["header"], "Shadowsocks TCP settings")
            let header = try V.object(transport["header"] ?? [:], "Shadowsocks TCP header")
            try V.keys(header, ["type"], "Shadowsocks TCP header")
            guard try optionalString(header, "type") ?? "none" == "none" else {
                throw invalid("Shadowsocks TCP header obfuscation is not supported")
            }
        }
        try V.keys(V.object(stream["sockopt"] ?? [:], "Shadowsocks socket options"), [], "Shadowsocks socket options")
        let port = try V.number(endpoint["port"], "Shadowsocks port", max: 65535)
        return try configuration(
            host: V.string(endpoint["address"], "Shadowsocks server address"), port: Int(port),
            method: V.string(endpoint["method"], "Shadowsocks cipher"), password: V.string(endpoint["password"], "Shadowsocks password"),
            remarks: remarks
        )
    }

    private func configuration(host: String, port: Int, method: String, password: String, remarks: String?) throws -> ConnectionConfiguration {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0.isNewline }),
            host.rangeOfCharacter(from: .controlCharacters) == nil,
            host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@%[]")) == nil,
            !host.contains(":") || IPv6Address(host) != nil
        else { throw invalid("Invalid Shadowsocks server address") }
        guard (1...65535).contains(port) else { throw invalid("Invalid Shadowsocks server port") }
        let parameters = try ShadowsocksParameters(method: method, password: password)
        var url = URLComponents()
        url.scheme = "ss"
        url.percentEncodedUser = encode(parameters.method)
        url.percentEncodedPassword = encode(parameters.password)
        url.host = host.contains(":") ? "[\(host)]" : host
        url.port = port
        // Always include the fragment so rename/reparse uses the same canonical form.
        url.percentEncodedFragment = (remarks ?? "").addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        guard let canonical = url.string else { throw invalid("Invalid Shadowsocks link") }
        return ConnectionConfiguration(
            rawLink: canonical, protocolType: .shadowsocks, host: host, port: port, remarks: remarks ?? "",
            security: .none, transport: .tcp, path: nil, hostHeader: nil, serverName: nil, alpn: [], fingerprint: nil,
            publicKey: nil, shortID: nil, spiderX: nil, vlessUserID: nil, vlessFlow: nil, trojanPassword: nil, shadowsocks: parameters
        )
    }

    private func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value as? String else { throw invalid("Invalid Shadowsocks transport settings") }
        return string
    }

    private func splitCredentials(_ text: String) throws -> (String, String) {
        guard let colon = text.firstIndex(of: ":") else { throw invalid("Shadowsocks credentials require a cipher and password") }
        return (String(text[..<colon]), String(text[text.index(after: colon)...]))
    }

    private func decodeBase64(_ text: String) -> String? {
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    private func invalid(_ reason: String) -> ConfigurationError { .invalidShadowsocks(reason) }
}
