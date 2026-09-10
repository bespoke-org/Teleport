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

/// The resolvers one connection publishes, and the names they answer for. Both
/// the DNS module and routing need this pairing: the servers are only reachable
/// through that connection's outbound.
private struct TunnelConnectionDNSRoute {
    let tag: String
    let servers: [String]
    let domains: [String]
}

/// One proxy outbound of a session. A session dials one server per selected
/// connection, and split-tunnel rules name the connection they leave through,
/// so every connection needs a stable Xray tag and its own protected address.
nonisolated struct RoutedProxyOutbound: Sendable, Equatable {
    /// The saved connection this outbound came from; what a rule references.
    let connectionID: UUID
    let configuration: ConnectionConfiguration
    /// The numeric address that receives the protected physical host route, so
    /// the outbound dials the same endpoint the route was installed for.
    let serverAddress: String?

    init(connectionID: UUID, configuration: ConnectionConfiguration, serverAddress: String? = nil) {
        self.connectionID = connectionID
        self.configuration = configuration
        self.serverAddress = serverAddress
    }
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

    /// `logLevel` is raised by the health probe: at "debug" Xray reports each
    /// WireGuard handshake, which is the only reachability signal a peer that
    /// carries just a few subnets can give.
    /// `outboundInterface` binds the proxy outbound to a physical interface. The
    /// health probe needs it: while a tunnel holds the default routes, an unbound
    /// probe travels through that tunnel and measures it instead of the server.
    func writeConfig(for configuration: ConnectionConfiguration, to outputURL: URL, logLevel: String = "warning", outboundInterface: String? = nil) throws -> URL {
        try writePayload(
            makePayload(configuration: configuration, logLevel: logLevel, outboundInterface: outboundInterface),
            to: outputURL
        )
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
        try writePayload(makeTunnelPayload(outbounds: [RoutedProxyOutbound(connectionID: UUID(), configuration: configuration)], interfaceName: interfaceName, outboundInterface: outboundInterface, directSendThrough: directSendThrough, splitTunnelRules: splitTunnelRules, defaultAction: defaultAction), to: outputURL)
    }

    func tunnelConfigData(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", directSendThrough: String? = nil, proxyServerAddress: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, dnsPolicy: TunnelDNSPolicy? = nil) throws -> Data {
        try tunnelConfigData(
            for: [RoutedProxyOutbound(connectionID: UUID(), configuration: configuration, serverAddress: proxyServerAddress)],
            interfaceName: interfaceName,
            outboundInterface: outboundInterface,
            directSendThrough: directSendThrough,
            splitTunnelRules: splitTunnelRules,
            defaultAction: defaultAction,
            dnsPolicy: dnsPolicy
        )
    }

    /// The first outbound is the session's default: it keeps the `proxy` tag that
    /// the catch-all rule, the local inbounds and DNS resolution point at.
    func tunnelConfigData(for outbounds: [RoutedProxyOutbound], interfaceName: String, outboundInterface: String = "auto", directSendThrough: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, dnsPolicy: TunnelDNSPolicy? = nil) throws -> Data {
        try encodePayload(makeTunnelPayload(outbounds: outbounds, interfaceName: interfaceName, outboundInterface: outboundInterface, directSendThrough: directSendThrough, splitTunnelRules: splitTunnelRules, defaultAction: defaultAction, dnsPolicy: dnsPolicy))
    }

    /// Tags are positional: `proxy` for the default connection, `proxy-1`, `proxy-2`
    /// and so on for the rest. Rules resolve a connection id to one of these.
    static func proxyTag(at index: Int) -> String {
        index == 0 ? "proxy" : "proxy-\(index)"
    }

    /// A connection that publishes its own resolvers (a WireGuard peer's `DNS =`)
    /// resolves the names routed through it there. Everything else is resolved
    /// through the default connection's outbound, even when a rule sends its
    /// traffic elsewhere: the answer is the same unless a server returns
    /// split-horizon results, and only a peer's own resolvers are known to be
    /// authoritative for that.
    ///
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

    private func makePayload(configuration: ConnectionConfiguration, logLevel: String = "warning", outboundInterface: String? = nil) -> [String: Any] {
        var proxyOutbound: [String: Any] = [
            "tag": "proxy",
            "protocol": configuration.protocolType.rawValue,
            "settings": makeOutboundSettings(configuration: configuration)
        ]
        var streamSettings = makeStreamSettings(configuration: configuration)
        if let outboundInterface, !outboundInterface.isEmpty, outboundInterface != "auto" {
            streamSettings["sockopt"] = ["interface": outboundInterface]
        }
        if !streamSettings.isEmpty {
            proxyOutbound["streamSettings"] = streamSettings
        }

        return [
            "log": [
                "loglevel": logLevel
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
                proxyOutbound,
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

    private func makeTunnelPayload(outbounds: [RoutedProxyOutbound], interfaceName: String, outboundInterface: String, directSendThrough: String? = nil, splitTunnelRules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy, dnsPolicy: TunnelDNSPolicy? = nil) -> [String: Any] {
        // Every proxy outbound is bound to the physical uplink: their transports
        // must leave outside the TUN they feed.
        let proxyOutbounds = outbounds.enumerated().map { index, outbound -> [String: Any] in
            var proxyStreamSettings = makeStreamSettings(configuration: outbound.configuration)
            if outboundInterface != "auto", !outboundInterface.isEmpty {
                proxyStreamSettings["sockopt"] = ["interface": outboundInterface]
            }
            return makeTunnelProxyOutbound(
                tag: Self.proxyTag(at: index),
                configuration: outbound.configuration,
                streamSettings: proxyStreamSettings,
                addressOverride: outbound.serverAddress
            )
        }
        // A rule naming a connection that is not part of this session falls back to
        // the default outbound rather than dropping the rule silently.
        var tagsByConnectionID: [UUID: String] = [:]
        for (index, outbound) in outbounds.enumerated() {
            tagsByConnectionID[outbound.connectionID] = Self.proxyTag(at: index)
        }
        let enabledSplitTunnelRules = splitTunnelRules.filter { $0.isEnabled }
        let splitTunnelRoutingRules = enabledSplitTunnelRules.map {
            makeSplitTunnelRoutingRule(for: $0, tagsByConnectionID: tagsByConnectionID)
        }
        // A WireGuard peer usually publishes resolvers that only exist inside its
        // own network, so they are reachable through that connection's outbound and
        // authoritative for the names routed there.
        let connectionDNSRoutes: [TunnelConnectionDNSRoute] = outbounds.enumerated().compactMap { index, outbound in
            let servers = Self.resolverAddresses(outbound.configuration.wireguard?.dnsServers ?? [])
            guard !servers.isEmpty else { return nil }
            let tag = Self.proxyTag(at: index)
            let domains = enabledSplitTunnelRules
                .filter { outboundTag(for: $0, tagsByConnectionID: tagsByConnectionID) == tag }
                .flatMap { dnsDomains(for: $0) }
            guard !domains.isEmpty else { return nil }
            return TunnelConnectionDNSRoute(tag: tag, servers: servers, domains: domains)
        }
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
        let dnsSection = dnsPolicy.map {
            makeDNSSection(
                policy: $0,
                rules: enabledSplitTunnelRules,
                defaultAction: defaultAction,
                connectionRoutes: connectionDNSRoutes
            )
        }
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
            // A peer's own resolvers are only reachable inside its tunnel, so the
            // module's queries to them must leave through that connection.
            for route in connectionDNSRoutes {
                rules.append([
                    "type": "field",
                    "inboundTag": [Self.dnsQueryTag],
                    "ip": route.servers,
                    "outboundTag": route.tag
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
            "outbounds": proxyOutbounds + [
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
                    ],
                    // QUIC keeps its SNI in an encrypted CRYPTO frame that sniffing
                    // recovers only sometimes: a resumed 0-RTT flow carries no
                    // ClientHello at all. A flow whose name was not recovered matches
                    // no domain rule and lands on the catch-all, which under a
                    // "direct" default sends the very traffic these rules exist to
                    // route through the proxy out over the uplink instead. Blocked
                    // rather than proxied, because applications answer a blocked
                    // UDP/443 by retrying over TCP, where the name is always there
                    // and every rule decides as written.
                    [
                        "type": "field",
                        "network": "udp",
                        "port": "443",
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
    private func makeDNSSection(policy: TunnelDNSPolicy, rules: [SplitTunnelRule], defaultAction: SplitTunnelRuleAction, connectionRoutes: [TunnelConnectionDNSRoute] = []) -> [String: Any] {
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
        // A connection's own resolvers come first and answer only for the names
        // routed through that connection, so an internal zone resolves inside the
        // tunnel that serves it instead of leaking to a public resolver.
        for route in connectionRoutes {
            for server in route.servers {
                servers.append(["address": server, "domains": route.domains, "skipFallback": true] as [String: Any])
            }
        }
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

    /// Only `.proxy` rules can name a connection; every other action keeps the
    /// action's own outbound.
    private func outboundTag(for rule: SplitTunnelRule, tagsByConnectionID: [UUID: String]) -> String {
        guard rule.action == .proxy,
              let connectionID = rule.connectionID,
              let tag = tagsByConnectionID[connectionID] else {
            return rule.action.rawValue
        }
        return tag
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

    /// The proxy outbound for the TUN config. WireGuard gets no stream layer of
    /// its own, but it must keep `sockopt.interface`: that binding is what sends
    /// its UDP handshake out the physical uplink instead of back into the TUN.
    private func makeTunnelProxyOutbound(tag: String, configuration: ConnectionConfiguration, streamSettings: [String: Any], addressOverride: String?) -> [String: Any] {
        var outbound: [String: Any] = [
            "tag": tag,
            "protocol": configuration.protocolType.rawValue,
            "settings": makeOutboundSettings(configuration: configuration, addressOverride: addressOverride)
        ]
        if !streamSettings.isEmpty {
            outbound["streamSettings"] = streamSettings
        }
        return outbound
    }

    private func makeSplitTunnelRoutingRule(for rule: SplitTunnelRule, tagsByConnectionID: [UUID: String] = [:]) -> [String: Any] {
        var routingRule: [String: Any] = [
            "type": "field",
            "outboundTag": outboundTag(for: rule, tagsByConnectionID: tagsByConnectionID)
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

        case .wireguard:
            // Xray owns the handshake in userspace ("kernelMode" is Linux-only and
            // would fail here), so the interface addresses live inside Xray rather
            // than on a utun of their own.
            guard let parameters = configuration.wireguard else { return [:] }

            var peer: [String: Any] = [
                "publicKey": parameters.peerPublicKey,
                "endpoint": Self.endpointLiteral(host: serverAddress, port: configuration.port),
                "allowedIPs": parameters.allowedIPs
            ]
            if let presharedKey = parameters.presharedKey {
                peer["preSharedKey"] = presharedKey
            }
            if let keepAlive = parameters.persistentKeepalive {
                peer["keepAlive"] = keepAlive
            }

            var settings: [String: Any] = [
                "secretKey": parameters.secretKey,
                "address": parameters.addresses,
                "kernelMode": false,
                "peers": [peer]
            ]
            settings["mtu"] = parameters.mtu ?? WireGuardParameters.defaultMTU
            if let reserved = parameters.reserved {
                settings["reserved"] = reserved
            }
            return settings
        }
    }

    /// Xray takes the peer endpoint as one string, so an IPv6 literal has to be
    /// bracketed before the port is appended.
    private static func endpointLiteral(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func makeStreamSettings(configuration: ConnectionConfiguration) -> [String: Any] {
        // WireGuard supplies its own transport and encryption; emitting a
        // network/security pair here would only describe unused placeholder
        // fields. Callers still add `sockopt` on top of the empty result.
        guard configuration.protocolType != .wireguard else { return [:] }

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
