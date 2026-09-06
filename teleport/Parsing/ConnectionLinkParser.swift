import Foundation

struct ConnectionLinkParser {
    nonisolated func parse(_ rawLink: String) throws -> ConnectionConfiguration {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw ConfigurationError.invalidScheme
        }

        switch scheme {
        case ConnectionProtocolType.vless.rawValue:
            return try parseVLESS(trimmed, components: components)
        case ConnectionProtocolType.trojan.rawValue:
            return try parseTrojan(trimmed, components: components)
        default:
            throw ConfigurationError.invalidScheme
        }
    }

    nonisolated private func parseVLESS(_ rawLink: String, components: URLComponents) throws -> ConnectionConfiguration {
        let base = try parseBase(rawLink, components: components)

        guard let user = components.user, !user.isEmpty else {
            throw ConfigurationError.missingUser
        }

        guard UUID(uuidString: user) != nil else {
            throw ConfigurationError.invalidUUID
        }

        let query = try queryDictionary(from: components)
        let securityRaw = (query["security"] ?? ConnectionSecurity.tls.rawValue).lowercased()
        guard let security = ConnectionSecurity(rawValue: securityRaw) else {
            throw ConfigurationError.unsupportedSecurity(securityRaw)
        }

        switch security {
        case .none, .tls:
            break
        case .reality:
            guard !(query["pbk"] ?? "").isEmpty else {
                throw ConfigurationError.missingParameter("pbk")
            }
            guard !(query["sni"] ?? "").isEmpty else {
                throw ConfigurationError.missingParameter("sni")
            }
        }

        let transport = try parseTransport(query: query)
        if transport == .grpc {
            guard !(query["serviceName"] ?? "").isEmpty else {
                throw ConfigurationError.missingParameter("serviceName")
            }
        }

        let flow = query["flow"]?.lowercased()
        if let flow, !flow.isEmpty {
            let supportsVisionFlow = flow == "xtls-rprx-vision"
                && transport == .tcp
                && (security == .tls || security == .reality)
            guard supportsVisionFlow else {
                throw ConfigurationError.unsupportedFlow(flow)
            }
        }

        return ConnectionConfiguration(
            rawLink: rawLink,
            protocolType: .vless,
            host: base.host,
            port: base.port,
            remarks: base.remarks,
            security: security,
            transport: transport,
            path: query["path"],
            hostHeader: query["host"],
            serverName: query["sni"],
            alpn: parseALPN(query: query),
            fingerprint: query["fp"],
            publicKey: query["pbk"],
            shortID: query["sid"],
            spiderX: query["spx"],
            vlessUserID: user,
            vlessFlow: flow,
            trojanPassword: nil,
            allowsInsecureTLS: parseAllowsInsecureTLS(query: query),
            grpcServiceName: query["serviceName"],
            transportMode: query["mode"]
        )
    }

    nonisolated private func parseTrojan(_ rawLink: String, components: URLComponents) throws -> ConnectionConfiguration {
        let base = try parseBase(rawLink, components: components)
        let query = try queryDictionary(from: components)

        guard let password = components.user?.removingPercentEncoding, !password.isEmpty else {
            throw ConfigurationError.missingPassword
        }

        let securityRaw = (query["security"] ?? ConnectionSecurity.tls.rawValue).lowercased()
        guard let security = ConnectionSecurity(rawValue: securityRaw) else {
            throw ConfigurationError.unsupportedSecurity(securityRaw)
        }

        let transport = try parseTransport(query: query)

        switch security {
        case .tls:
            guard transport == .tcp || transport == .ws || transport == .grpc else {
                throw ConfigurationError.unsupportedTransport(transport.rawValue)
            }
            if transport == .grpc {
                guard !(query["serviceName"] ?? "").isEmpty else {
                    throw ConfigurationError.missingParameter("serviceName")
                }
            }
        case .reality:
            guard transport == .tcp else {
                throw ConfigurationError.unsupportedTransport(transport.rawValue)
            }
            guard !(query["pbk"] ?? "").isEmpty else {
                throw ConfigurationError.missingParameter("pbk")
            }
            guard !(query["sni"] ?? "").isEmpty else {
                throw ConfigurationError.missingParameter("sni")
            }
        case .none:
            throw ConfigurationError.unsupportedSecurity(securityRaw)
        }

        return ConnectionConfiguration(
            rawLink: rawLink,
            protocolType: .trojan,
            host: base.host,
            port: base.port,
            remarks: base.remarks,
            security: security,
            transport: transport,
            path: query["path"],
            hostHeader: query["host"],
            serverName: query["sni"] ?? base.host,
            alpn: parseALPN(query: query),
            fingerprint: query["fp"],
            publicKey: query["pbk"],
            shortID: query["sid"],
            spiderX: query["spx"],
            vlessUserID: nil,
            vlessFlow: nil,
            trojanPassword: password,
            allowsInsecureTLS: parseAllowsInsecureTLS(query: query),
            grpcServiceName: query["serviceName"],
            transportMode: query["mode"]
        )
    }

    nonisolated private func parseBase(_ rawLink: String, components: URLComponents) throws -> (host: String, port: Int, remarks: String?) {
        guard let parsedHost = components.host, !parsedHost.isEmpty else {
            throw ConfigurationError.missingHost
        }

        guard let port = components.port else {
            throw ConfigurationError.invalidPort
        }

        let remarks = components.fragment?.removingPercentEncoding
        let host = rawAuthorityHost(from: rawLink) ?? parsedHost
        return (host, port, remarks)
    }

    nonisolated private func rawAuthorityHost(from rawLink: String) -> String? {
        guard let schemeRange = rawLink.range(of: "://") else { return nil }
        let authorityStart = schemeRange.upperBound
        let authorityEnd = rawLink[authorityStart...]
            .firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            ?? rawLink.endIndex
        var authority = rawLink[authorityStart ..< authorityEnd]
        if let userInfoEnd = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: userInfoEnd)...]
        }

        if authority.first == "[", let closingBracket = authority.firstIndex(of: "]") {
            let host = authority[authority.index(after: authority.startIndex) ..< closingBracket]
            return host.isEmpty ? nil : decodedHost(host)
        }

        let hostEnd = authority.firstIndex(of: ":") ?? authority.endIndex
        let host = authority[..<hostEnd]
        return host.isEmpty ? nil : decodedHost(host)
    }

    /// Percent-decodes the raw authority host so an encoded host (e.g.
    /// `ex%61mple.com`) resolves to its real form, matching what URLComponents.host
    /// would have returned, while still preserving the original case.
    nonisolated private func decodedHost(_ host: Substring) -> String {
        String(host).removingPercentEncoding ?? String(host)
    }

    nonisolated private func queryDictionary(from components: URLComponents) throws -> [String: String] {
        guard let queryItems = components.queryItems else {
            return [:]
        }

        var query: [String: String] = [:]
        for item in queryItems {
            guard query[item.name] == nil else {
                throw ConfigurationError.malformedQuery
            }
            query[item.name] = item.value ?? ""
        }
        return query
    }

    nonisolated private func parseTransport(query: [String: String]) throws -> ConnectionTransport {
        let transportRaw = (query["type"] ?? ConnectionTransport.tcp.rawValue).lowercased()
        guard let transport = ConnectionTransport(rawValue: transportRaw) else {
            throw ConfigurationError.unsupportedTransport(transportRaw)
        }
        return transport
    }

    nonisolated private func parseALPN(query: [String: String]) -> [String] {
        query["alpn"]?.split(separator: ",").map { String($0) } ?? []
    }

    nonisolated private func parseAllowsInsecureTLS(query: [String: String]) -> Bool {
        parseBooleanQueryValue(query["insecure"]) || parseBooleanQueryValue(query["allowInsecure"])
    }

    nonisolated private func parseBooleanQueryValue(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
