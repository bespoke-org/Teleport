import CoreFoundation
import Foundation

nonisolated struct XraySubscriptionProfileError: Error {
    let reason: String
}

/// Imports server settings, not the provider's runtime configuration. Teleport
/// owns inbounds, DNS and routing. Only representable outbound settings may pass;
/// routing dependencies, balancers and unknown transport options cannot be lost.
nonisolated struct XraySubscriptionProfileParser {
    func parse(_ value: Any) throws -> String {
        let profile = try object(value)
        if profile["observatory"] != nil || profile["burstObservatory"] != nil {
            throw unsupported("Balancer/observatory profiles are not supported")
        }
        try checkKeys(profile, allowed: ["remarks", "outbounds", "inbounds", "dns", "log", "routing"], section: "profile")
        guard let outbounds = profile["outbounds"] as? [[String: Any]] else { throw invalid() }
        let routing = try optionalObject(profile, "routing")
        if let balancers = routing["balancers"] {
            guard let array = balancers as? [Any] else { throw invalid() }
            if !array.isEmpty { throw unsupported("Balancer/observatory profiles are not supported") }
        }
        let proxies = try outbounds.filter { outbound in
            let name = try string(outbound, "protocol", required: true)
            return name != "freedom" && name != "blackhole"
        }
        guard proxies.count == 1 else {
            throw unsupported(proxies.isEmpty ? "No proxy outbound in Xray profile" : "Multiple proxy outbounds are not supported")
        }
        let outbound = proxies[0]
        let proto = try string(outbound, "protocol", required: true)!
        switch proto {
        case "vless", "trojan": break
        case "hysteria": throw unsupported("Hysteria is not supported")
        case "shadowsocks": throw unsupported("Shadowsocks is not supported")
        default: throw unsupported("Unsupported Xray outbound protocol")
        }
        try validateRouting(routing, outbounds: outbounds)
        try checkKeys(outbound, allowed: ["tag", "protocol", "settings", "streamSettings", "mux"], section: "outbound (including chaining)")
        if outbound["mux"] != nil {
            let mux = try optionalObject(outbound, "mux")
            guard try boolean(mux, "enabled") == false else {
                throw unsupported("Outbound multiplexing is not supported")
            }
            // Other mux options are inactive when enabled is explicitly false.
        }

        let settings = try object(outbound["settings"])
        let endpoint: [String: Any]
        let credential: String
        var query: [String: String] = [:]
        if proto == "vless" {
            try checkKeys(settings, allowed: ["vnext"], section: "VLESS settings")
            endpoint = try singleObject(settings["vnext"])
            try checkKeys(endpoint, allowed: ["address", "port", "users"], section: "VLESS endpoint")
            let user = try singleObject(endpoint["users"])
            try checkKeys(user, allowed: ["id", "encryption", "flow", "email", "level"], section: "VLESS user")
            try validateUserMetadata(user)
            credential = try string(user, "id", required: true)!
            guard UUID(uuidString: credential) != nil else { throw invalid() }
            let encryption = try string(user, "encryption") ?? "none"
            guard encryption == "none" else { throw unsupported("VLESS encryption settings are not supported") }
            query["encryption"] = "none"
            query["flow"] = try string(user, "flow")
        } else {
            try checkKeys(settings, allowed: ["servers"], section: "Trojan settings")
            endpoint = try singleObject(settings["servers"])
            try checkKeys(endpoint, allowed: ["address", "port", "password", "email", "level"], section: "Trojan endpoint")
            try validateUserMetadata(endpoint)
            credential = try string(endpoint, "password", required: true)!
        }
        let host = try string(endpoint, "address", required: true)!
        guard let port = endpoint["port"] as? NSNumber,
            CFGetTypeID(port) != CFBooleanGetTypeID(),
            port.doubleValue == Double(port.intValue), (1...65535).contains(port.intValue)
        else { throw invalid() }
        let stream = try optionalObject(outbound, "streamSettings")
        let network = try string(stream, "network") ?? "tcp"
        let security = try string(stream, "security") ?? "none"
        guard ["tcp", "raw", "ws", "grpc", "xhttp"].contains(network) else {
            throw unsupported("Unsupported Xray transport")
        }
        guard ["none", "tls", "reality"].contains(security) else {
            throw unsupported("Unsupported Xray security")
        }
        let transportKey = network + "Settings"
        let securityKey = security + "Settings"
        try checkKeys(stream, allowed: ["network", "security", transportKey, securityKey], section: "stream settings")
        query["type"] = network
        query["security"] = security
        let transport = try optionalObject(stream, transportKey)
        switch network {
        case "tcp", "raw":
            try checkKeys(transport, allowed: ["header"], section: "TCP transport")
            let header = try optionalObject(transport, "header")
            try checkKeys(header, allowed: ["type"], section: "TCP header")
            if let type = try string(header, "type"), type != "none" {
                throw unsupported("TCP header obfuscation is not supported")
            }
        case "ws":
            try checkKeys(transport, allowed: ["path", "headers"], section: "WebSocket transport")
            query["path"] = try string(transport, "path")
            let headers = try optionalObject(transport, "headers")
            try checkKeys(headers, allowed: ["Host"], section: "WebSocket headers")
            query["host"] = try string(headers, "Host")
        case "grpc":
            try checkKeys(transport, allowed: ["serviceName"], section: "gRPC transport")
            query["serviceName"] = try string(transport, "serviceName", required: true)
        case "xhttp":
            try checkKeys(transport, allowed: ["path", "host", "mode"], section: "XHTTP transport (including extra)")
            query["path"] = try string(transport, "path")
            query["host"] = try string(transport, "host")
            query["mode"] = try string(transport, "mode")
        default: break
        }
        let tls = try optionalObject(stream, securityKey)
        if security == "tls" {
            try checkKeys(tls, allowed: ["serverName", "fingerprint", "alpn", "allowInsecure"], section: "TLS settings")
            if let alpn = tls["alpn"] {
                guard let values = alpn as? [String], values.allSatisfy({ !$0.isEmpty && !$0.contains(",") }) else { throw invalid() }
                query["alpn"] = values.joined(separator: ",")
            }
            if let insecure = try boolean(tls, "allowInsecure") { query["allowInsecure"] = insecure ? "1" : "0" }
        } else if security == "reality" {
            try checkKeys(tls, allowed: ["serverName", "fingerprint", "publicKey", "shortId", "spiderX"], section: "REALITY settings")
            query["pbk"] = try string(tls, "publicKey", required: true)
            query["sid"] = try string(tls, "shortId")
            query["spx"] = try string(tls, "spiderX")
        } else if !tls.isEmpty {
            throw unsupported("Unsupported settings for unencrypted transport")
        }
        query["sni"] = try string(tls, "serverName", required: security == "reality")
        query["fp"] = try string(tls, "fingerprint")

        var components = URLComponents()
        components.scheme = proto
        components.user = credential
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port.intValue
        // Ordering is independent of JSON key order. The generated link also
        // serves as the refresh identity, just like an ordinary subscription URI.
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        components.fragment = try string(profile, "remarks")
        guard let link = components.string else { throw invalid() }
        return link
    }

    private func validateRouting(_ routing: [String: Any], outbounds: [[String: Any]]) throws {
        try checkKeys(routing, allowed: ["domainStrategy", "domainMatcher", "rules", "balancers"], section: "routing")
        guard let value = routing["rules"] else { return }
        guard let rules = value as? [[String: Any]] else { throw invalid() }
        let tags = Set(outbounds.compactMap { $0["tag"] as? String })
        for rule in rules {
            if rule["balancerTag"] != nil { throw unsupported("Balancer/observatory profiles are not supported") }
            if let tag = try string(rule, "outboundTag"), !tags.contains(tag) {
                throw unsupported("Unresolved outbound references in routing")
            }
        }
    }

    private func validateUserMetadata(_ user: [String: Any]) throws {
        _ = try string(user, "email")  // Labels do not affect the remote connection.
        if let level = user["level"] {
            guard let number = level as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 0 else {
                throw unsupported("Custom user policy levels are not supported")
            }
        }
    }

    private func checkKeys(_ value: [String: Any], allowed: Set<String>, section: String) throws {
        guard Set(value.keys).isSubset(of: allowed) else {
            // Never include provider-controlled field names or values in errors.
            throw unsupported("Unsupported settings in Xray \(section)")
        }
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw invalid() }
        return result
    }

    private func optionalObject(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        guard let nested = value[key] else { return [:] }
        return try object(nested)
    }

    private func singleObject(_ value: Any?) throws -> [String: Any] {
        guard let array = value as? [[String: Any]], !array.isEmpty else { throw invalid() }
        guard array.count == 1 else { throw unsupported("Multiple endpoints or users in an outbound are not supported") }
        return array[0]
    }

    private func string(_ value: [String: Any], _ key: String, required: Bool = false) throws -> String? {
        guard let item = value[key] else {
            if required { throw invalid() }
            return nil
        }
        guard let result = item as? String, !required || !result.isEmpty else { throw invalid() }
        return result
    }

    private func boolean(_ value: [String: Any], _ key: String) throws -> Bool? {
        guard let item = value[key] else { return nil }
        guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
        return number.boolValue
    }

    private func invalid() -> XraySubscriptionProfileError { unsupported("Invalid Xray profile fields") }
    private func unsupported(_ reason: String) -> XraySubscriptionProfileError { XraySubscriptionProfileError(reason: reason) }
}
