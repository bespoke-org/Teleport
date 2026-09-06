import Darwin
import Foundation

/// Builds Xray JSON for two distinct execution models: an unprivileged local
/// SOCKS/HTTP proxy and a root-owned TUN process. Dynamic dictionaries mirror
/// Xray's external schema, then `JSONSerialization` turns them into bytes.
/// How the tunnel resolves names. Xray's DNS module owns every query: proxied
/// domains are resolved by `remoteResolver` through the proxy outbound, so a
/// hostile local resolver cannot poison them; direct domains use the system's
/// resolvers through the interface-bound direct outbound. Unmatched domains
/// follow the profile's default action.
nonisolated struct TunnelDNSPolicy: Sendable, Equatable {
    static let defaultRemoteResolver = "https://1.1.1.1/dns-query"

    var localResolvers: [String]
    var remoteResolver: String = TunnelDNSPolicy.defaultRemoteResolver
    /// False when the physical uplink has no globally routable IPv6 address. The
    /// module then answers A records only and the TUN claims no IPv6 route, so
    /// applications never attempt IPv6 connections the tunnel could not deliver.
    var ipv6Enabled: Bool = true
}

nonisolated struct XrayConfigurationWriter {
    let proxyEndpoint: ProxyEndpoint
    static let dnsQueryTag = "dns-internal"

    func writeConfig(for configuration: ConnectionConfiguration) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try writeConfig(
            for: configuration,
            to: directory.appendingPathComponent("xray-config.json")
        )
    }

    func writeConfig(for configuration: ConnectionConfiguration, to outputURL: URL) throws -> URL {
        try writePayload(makePayload(configuration: configuration), to: outputURL)
    }

    func writeTunnelConfig(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", directSendThrough: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try writeTunnelConfig(
            for: configuration,
            interfaceName: interfaceName,
            outboundInterface: outboundInterface,
            directSendThrough: directSendThrough,
            splitTunnelRules: splitTunnelRules,
            defaultAction: defaultAction,
            to: directory.appendingPathComponent("xray-tun-config.json")
        )
    }

    func writeTunnelConfig(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", directSendThrough: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, to outputURL: URL) throws -> URL {
        try writePayload(makeTunnelPayload(configuration: configuration, interfaceName: interfaceName, outboundInterface: outboundInterface, directSendThrough: directSendThrough, splitTunnelRules: splitTunnelRules, defaultAction: defaultAction), to: outputURL)
    }

    func tunnelConfigData(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", directSendThrough: String? = nil, proxyServerAddress: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, dnsPolicy: TunnelDNSPolicy? = nil) throws -> Data {
        try encodePayload(makeTunnelPayload(configuration: configuration, interfaceName: interfaceName, outboundInterface: outboundInterface, directSendThrough: directSendThrough, proxyServerAddress: proxyServerAddress, splitTunnelRules: splitTunnelRules, defaultAction: defaultAction, dnsPolicy: dnsPolicy))
    }

    /// Writes atomically so Xray never observes a partially serialized config and
    /// restricts the credential-bearing file to the current user.
    private func writePayload(_ payload: [String: Any], to outputURL: URL) throws -> URL {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try encodePayload(payload)
        try data.write(to: outputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        return outputURL
    }

    private func encodePayload(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func makePayload(configuration: ConnectionConfiguration) -> [String: Any] {
        let streamSettings = makeStreamSettings(configuration: configuration)

        return [
            "log": [
                "loglevel": "warning"
            ],
            "inbounds": [
                [
                    "tag": "socks-in",
                    "listen": proxyEndpoint.host,
                    "port": proxyEndpoint.socksPort,
                    "protocol": "socks",
                    "settings": ["udp": true]
                ],
                [
                    "tag": "http-in",
                    "listen": proxyEndpoint.host,
                    "port": proxyEndpoint.httpPort,
                    "protocol": "http",
                    "settings": [:]
                ]
            ],
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": configuration.protocolType.rawValue,
                    "settings": makeOutboundSettings(configuration: configuration),
                    "streamSettings": streamSettings
                ],
                [
                    "tag": "direct",
                    "protocol": "freedom",
                    "settings": [:]
                ]
            ],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [
                    [
                        "type": "field",
                        "outboundTag": "proxy",
                        "network": "tcp,udp"
                    ]
                ]
            ]
        ]
    }

    private func makeTunnelPayload(configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String, directSendThrough: String? = nil, proxyServerAddress: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, dnsPolicy: TunnelDNSPolicy? = nil) -> [String: Any] {
        let streamSettings = makeStreamSettings(configuration: configuration)
        var proxyStreamSettings = streamSettings
        if outboundInterface != "auto", !outboundInterface.isEmpty {
            proxyStreamSettings["sockopt"] = ["interface": outboundInterface]
        }
        let enabledSplitTunnelRules = splitTunnelRules.filter { $0.isEnabled }
        let splitTunnelRoutingRules = enabledSplitTunnelRules.map { makeSplitTunnelRoutingRule(for: $0) }
        let localProxyRoutingRules: [[String: Any]] = [[
            "type": "field",
            "inboundTag": ["socks-in", "http-in"],
            "network": "tcp,udp",
            "outboundTag": "proxy"
        ]]
        // Every DNS query from the device is hijacked into Xray's DNS module, and
        // the module's own upstream traffic is tagged so routing can send local
        // resolvers out the direct outbound and the remote resolver through the
        // proxy. Xray never touches the OS resolver, so no query can loop back
        // into the TUN. Without a policy (tests, legacy callers) DNS is left alone.
        let dnsSection = dnsPolicy.map { makeDNSSection(policy: $0, rules: enabledSplitTunnelRules, defaultAction: defaultAction) }
        let dnsOutbounds: [[String: Any]] = dnsSection == nil ? [] : [[
            "tag": "dns-out",
            "protocol": "dns",
            "settings": [:]
        ]]
        let dnsRoutingRules: [[String: Any]] = dnsPolicy.map { policy in
            var rules: [[String: Any]] = [[
                "type": "field",
                "inboundTag": ["tun"],
                "network": "tcp,udp",
                "port": 53,
                "outboundTag": "dns-out"
            ]]
            let localResolverAddresses = Self.resolverAddresses(policy.localResolvers)
            if !localResolverAddresses.isEmpty {
                rules.append([
                    "type": "field",
                    "inboundTag": [Self.dnsQueryTag],
                    "ip": localResolverAddresses,
                    "outboundTag": "direct"
                ])
            }
            rules.append([
                "type": "field",
                "inboundTag": [Self.dnsQueryTag],
                "outboundTag": "proxy"
            ])
            return rules
        } ?? []

        // The default routes point every destination at the TUN, so a plain freedom
        // outbound would loop split-tunnel "direct" traffic straight back into Xray.
        // Bind it to the physical interface so those sockets egress outside the tunnel.
        // When Xray owns DNS, sniffed domains replace the destination so the proxy
        // receives names and resolves them remotely, and the direct outbound
        // resolves through Xray's module ("UseIP") rather than the OS resolver.
        // Without the module the original IP must be kept, otherwise freedom would
        // fall back to the system resolver whose packets loop into the TUN.
        let ownsDNS = dnsPolicy != nil
        let ipv6Enabled = dnsPolicy?.ipv6Enabled ?? true
        var directOutbound: [String: Any] = [
            "tag": "direct",
            "protocol": "freedom",
            "settings": ownsDNS ? ["domainStrategy": "UseIP"] : [:]
        ]
        if outboundInterface != "auto", !outboundInterface.isEmpty {
            directOutbound["streamSettings"] = [
                "sockopt": ["interface": outboundInterface]
            ]
        }
        if let directSendThrough, !directSendThrough.isEmpty {
            directOutbound["sendThrough"] = directSendThrough
        }

        var payload: [String: Any] = [
            "log": [
                "loglevel": "warning"
            ],
            "inbounds": [
                [
                    "tag": "tun",
                    "protocol": "tun",
                    "settings": [
                        "name": interfaceName,
                        "MTU": 9000,
                        "gateway": ipv6Enabled
                            ? ["172.18.0.1/30", "fdfe:dcba:9876::1/126"]
                            : ["172.18.0.1/30"],
                        "autoSystemRoutingTable": ipv6Enabled
                            ? ["0.0.0.0/0", "::/0"]
                            : ["0.0.0.0/0"],
                        "autoOutboundsInterface": outboundInterface
                    ],
                    "sniffing": [
                        "enabled": true,
                        // Include "quic" so HTTP/3 (UDP/443) flows have their SNI
                        // sniffed too. Without it, QUIC packets carry no recovered
                        // domain, so domain/geosite split-tunnel rules silently skip
                        // them and modern browser traffic bypasses split routing.
                        "destOverride": [
                            "http",
                            "tls",
                            "quic"
                        ],
                        // See `ownsDNS` above: destinations are overridden only when
                        // Xray's own DNS module can resolve them safely.
                        "routeOnly": !ownsDNS
                    ]
                ],
                // VPN mode already routes all device traffic through the TUN, but
                // also exposing local SOCKS/HTTP ports lets tools that expect an
                // explicit proxy (rather than relying on the default route) point
                // at Teleport directly, same as System Proxy mode's inbounds.
                [
                    "tag": "socks-in",
                    "listen": proxyEndpoint.host,
                    "port": proxyEndpoint.socksPort,
                    "protocol": "socks",
                    "settings": ["udp": true]
                ],
                [
                    "tag": "http-in",
                    "listen": proxyEndpoint.host,
                    "port": proxyEndpoint.httpPort,
                    "protocol": "http",
                    "settings": [:]
                ]
            ],
            // Deliberately no "mux" on the proxy outbound: multiplexing defeats
            // Vision's traffic shaping and is itself a recognizable pattern.
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": configuration.protocolType.rawValue,
                    "settings": makeOutboundSettings(configuration: configuration, addressOverride: proxyServerAddress),
                    "streamSettings": proxyStreamSettings
                ],
                directOutbound,
                [
                    "tag": "block",
                    "protocol": "blackhole",
                    "settings": [:]
                ]
            ] + dnsOutbounds,
            "routing": [
                "domainStrategy": "AsIs",
                "rules": localProxyRoutingRules + dnsRoutingRules + [
                    [
                        "type": "field",
                        "network": "udp",
                        "port": "135,137-139,5353",
                        "outboundTag": "block"
                    ],
                    [
                        "type": "field",
                        "ip": [
                            "224.0.0.0/3"
                        ],
                        "outboundTag": "block"
                    ]
                ] + splitTunnelRoutingRules + [
                    // Catch-all for everything no rule matched. Its outbound is the
                    // profile's default action: "proxy" keeps the classic
                    // full-tunnel-with-exceptions behavior, "direct" makes the
                    // profile a whitelist without a hand-written 0.0.0.0/0 rule.
                    [
                        "type": "field",
                        "outboundTag": defaultAction.rawValue,
                        "network": "tcp,udp"
                    ]
                ]
            ]
        ]

        // Xray falls back to the first outbound whenever no routing rule is
        // selected. Keep that implicit fallback aligned with the explicit final
        // catch-all rule; relying on the latter alone is not sufficient for TUN
        // flows that the router declines to classify.
        if var outbounds = payload["outbounds"] as? [[String: Any]],
           let defaultOutboundIndex = outbounds.firstIndex(where: { $0["tag"] as? String == defaultAction.rawValue }),
           defaultOutboundIndex != 0 {
            let defaultOutbound = outbounds.remove(at: defaultOutboundIndex)
            outbounds.insert(defaultOutbound, at: 0)
            payload["outbounds"] = outbounds
        }
        if let dnsSection {
            payload["dns"] = dnsSection
        }

        return payload
    }

    /// Server order matters to Xray: servers carrying `domains` are consulted first
    /// for matching names and, with `skipFallback`, never for anything else. The
    /// default-action resolver goes first so every unmatched name lands there.
    private func makeDNSSection(policy: TunnelDNSPolicy, rules: [SplitTunnelRule], defaultAction: SplitTunnelRuleAction) -> [String: Any] {
        let localResolverAddresses = Self.resolverAddresses(policy.localResolvers)
        let proxyDomains = rules.filter { $0.action == .proxy }.flatMap { dnsDomains(for: $0) }
        let directDomains = rules.filter { $0.action == .direct }.flatMap { dnsDomains(for: $0) }

        func remoteServer(domains: [String]) -> Any {
            guard !domains.isEmpty else { return policy.remoteResolver }
            return ["address": policy.remoteResolver, "domains": domains, "skipFallback": true] as [String: Any]
        }
        func localServers(domains: [String]) -> [Any] {
            localResolverAddresses.map { address -> Any in
                guard !domains.isEmpty else { return address }
                return ["address": address, "domains": domains, "skipFallback": true] as [String: Any]
            }
        }

        var servers: [Any] = []
        // Without any usable system resolver every name goes to the remote one;
        // that keeps resolution working instead of failing every direct domain.
        if defaultAction == .direct, !localResolverAddresses.isEmpty {
            servers.append(contentsOf: localServers(domains: []))
            servers.append(remoteServer(domains: proxyDomains))
        } else {
            servers.append(remoteServer(domains: []))
            servers.append(contentsOf: localServers(domains: directDomains))
        }
        return [
            "tag": Self.dnsQueryTag,
            "queryStrategy": policy.ipv6Enabled ? "UseIP" : "UseIPv4",
            "servers": servers
        ]
    }

    private func dnsDomains(for rule: SplitTunnelRule) -> [String] {
        makeSplitTunnelRoutingRule(for: rule)["domain"] as? [String] ?? []
    }

    /// Keeps only plain IPv4/IPv6 literals; scoped or malformed entries would make
    /// Xray reject the whole config at startup.
    static func resolverAddresses(_ candidates: [String]) -> [String] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            // Darwin's inet_pton accepts zone suffixes ("fe80::1%en0"); Xray does not.
            guard !candidate.contains("%") else { return false }
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            let isLiteral = candidate.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
                || candidate.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
            return isLiteral && seen.insert(candidate).inserted
        }
    }

    private func makeSplitTunnelRoutingRule(for rule: SplitTunnelRule) -> [String: Any] {
        var routingRule: [String: Any] = [
            "type": "field",
            "outboundTag": rule.action.rawValue
        ]

        switch rule.kind {
        case .domain:
            // A bare value in Xray's `domain` array is a *substring* matcher, so
            // `example.com` would also match `notexample.com`/`example.com.evil.net`.
            // The rule tester (SplitTunnelRuleMatcher) instead treats a bare value
            // as a subdomain (suffix) match and a `full:`-prefixed value as exact.
            // Emit the explicit `domain:` prefix so Xray uses subdomain semantics
            // that agree with the tester; `full:` values already carry Xray's own
            // exact-match prefix and pass through unchanged.
            if rule.value.hasPrefix("full:") {
                routingRule["domain"] = [rule.value]
            } else {
                routingRule["domain"] = ["domain:" + rule.value]
            }
        case .geosite:
            // Xray accepts `geosite:<category>` entries inside the domain array.
            routingRule["domain"] = [rule.value]
        case .geoip:
            // Xray accepts `geoip:<category>` entries inside the ip array.
            routingRule["ip"] = [rule.value]
        case .ip:
            routingRule["ip"] = [rule.value]
        }

        return routingRule
    }

    private func makeOutboundSettings(configuration: ConnectionConfiguration, addressOverride: String? = nil) -> [String: Any] {
        let serverAddress = addressOverride ?? configuration.host
        switch configuration.protocolType {
        case .vless:
            var user: [String: Any] = [
                "id": configuration.vlessUserID ?? "",
                "encryption": "none"
            ]

            if let flow = configuration.vlessFlow, !flow.isEmpty {
                user["flow"] = flow
            }

            return [
                "vnext": [[
                    "address": serverAddress,
                    "port": configuration.port,
                    "users": [user]
                ]]
            ]

        case .trojan:
            return [
                "servers": [[
                    "address": serverAddress,
                    "port": configuration.port,
                    "password": configuration.trojanPassword ?? ""
                ]]
            ]
        }
    }

    private func makeStreamSettings(configuration: ConnectionConfiguration) -> [String: Any] {
        var streamSettings: [String: Any] = [
            "network": configuration.transport.rawValue,
            "security": configuration.security.rawValue
        ]

        if configuration.transport == .ws {
            var wsSettings: [String: Any] = [
                "path": configuration.path ?? "/"
            ]

            if let hostHeader = configuration.hostHeader, !hostHeader.isEmpty {
                wsSettings["headers"] = ["Host": hostHeader]
            }

            streamSettings["wsSettings"] = wsSettings
        }

        if configuration.transport == .grpc {
            streamSettings["grpcSettings"] = [
                "serviceName": configuration.grpcServiceName ?? ""
            ]
        }

        if configuration.transport == .xhttp {
            var xhttpSettings: [String: Any] = [
                "path": configuration.path ?? "/"
            ]

            if let hostHeader = configuration.hostHeader, !hostHeader.isEmpty {
                xhttpSettings["host"] = hostHeader
            }

            if let mode = configuration.transportMode, !mode.isEmpty {
                xhttpSettings["mode"] = mode
            }

            streamSettings["xhttpSettings"] = xhttpSettings
        }

        if configuration.security == .tls {
            // Without an explicit fingerprint Xray speaks TLS with Go's own stack,
            // whose ClientHello is a well-known DPI signature for proxy tooling.
            // Mimic a browser by default, exactly as the REALITY branch does.
            var tlsSettings: [String: Any] = [
                "serverName": configuration.serverName ?? configuration.host,
                "fingerprint": configuration.fingerprint ?? "chrome"
            ]

            if !configuration.alpn.isEmpty {
                tlsSettings["alpn"] = configuration.alpn
            }

            if configuration.allowsInsecureTLS {
                tlsSettings["allowInsecure"] = true
            }

            streamSettings["tlsSettings"] = tlsSettings
        }

        if configuration.security == .reality {
            streamSettings["realitySettings"] = [
                "serverName": configuration.serverName ?? configuration.host,
                "fingerprint": configuration.fingerprint ?? "chrome",
                "publicKey": configuration.publicKey ?? "",
                "shortId": configuration.shortID ?? "",
                "spiderX": configuration.spiderX ?? ""
            ]
        }

        return streamSettings
    }
}
