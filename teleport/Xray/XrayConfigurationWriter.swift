import AppKit
import CFNetwork
import Combine
import Darwin
import Foundation
import Network
import SystemConfiguration

struct XrayConfigurationWriter {
    let proxyEndpoint: ProxyEndpoint

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

    func writeTunnelConfig(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", splitTunnelRules: [SplitTunnelRule] = []) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try writeTunnelConfig(
            for: configuration,
            interfaceName: interfaceName,
            outboundInterface: outboundInterface,
            splitTunnelRules: splitTunnelRules,
            to: directory.appendingPathComponent("xray-tun-config.json")
        )
    }

    func writeTunnelConfig(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", splitTunnelRules: [SplitTunnelRule] = [], to outputURL: URL) throws -> URL {
        try writePayload(makeTunnelPayload(configuration: configuration, interfaceName: interfaceName, outboundInterface: outboundInterface, splitTunnelRules: splitTunnelRules), to: outputURL)
    }

    func tunnelConfigData(for configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String = "auto", splitTunnelRules: [SplitTunnelRule] = []) throws -> Data {
        try encodePayload(makeTunnelPayload(configuration: configuration, interfaceName: interfaceName, outboundInterface: outboundInterface, splitTunnelRules: splitTunnelRules))
    }

    private func writePayload(_ payload: [String: Any], to outputURL: URL) throws -> URL {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try encodePayload(payload)
        try data.write(to: outputURL, options: .atomic)
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

    private func makeTunnelPayload(configuration: ConnectionConfiguration, interfaceName: String, outboundInterface: String, splitTunnelRules: [SplitTunnelRule] = []) -> [String: Any] {
        let streamSettings = makeStreamSettings(configuration: configuration)
        let splitTunnelRoutingRules = splitTunnelRules
            .filter { $0.isEnabled }
            .map { makeSplitTunnelRoutingRule(for: $0) }

        // The default routes point every destination at the TUN, so a plain freedom
        // outbound would loop split-tunnel "direct" traffic straight back into Xray.
        // Bind it to the physical interface so those sockets egress outside the tunnel.
        var directOutbound: [String: Any] = [
            "tag": "direct",
            "protocol": "freedom",
            "settings": [:]
        ]
        if outboundInterface != "auto", !outboundInterface.isEmpty {
            directOutbound["streamSettings"] = [
                "sockopt": ["interface": outboundInterface]
            ]
        }

        return [
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
                        "gateway": [
                            "172.18.0.1/30"
                        ],
                        "autoSystemRoutingTable": [
                            "0.0.0.0/0"
                        ],
                        "autoOutboundsInterface": outboundInterface
                    ],
                    "sniffing": [
                        "enabled": true,
                        "destOverride": [
                            "http",
                            "tls"
                        ]
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
            "outbounds": [
                [
                    "tag": "proxy",
                    "protocol": configuration.protocolType.rawValue,
                    "settings": makeOutboundSettings(configuration: configuration),
                    "streamSettings": streamSettings
                ],
                directOutbound,
                [
                    "tag": "block",
                    "protocol": "blackhole",
                    "settings": [:]
                ]
            ],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [
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
                    [
                        "type": "field",
                        "outboundTag": "proxy",
                        "network": "tcp,udp"
                    ]
                ]
            ]
        ]
    }

    private func makeSplitTunnelRoutingRule(for rule: SplitTunnelRule) -> [String: Any] {
        var routingRule: [String: Any] = [
            "type": "field",
            "outboundTag": rule.action.rawValue
        ]

        switch rule.kind {
        case .domain:
            routingRule["domain"] = [rule.value]
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

    private func makeOutboundSettings(configuration: ConnectionConfiguration) -> [String: Any] {
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
                    "address": configuration.host,
                    "port": configuration.port,
                    "users": [user]
                ]]
            ]

        case .trojan:
            return [
                "servers": [[
                    "address": configuration.host,
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
            var tlsSettings: [String: Any] = [
                "serverName": configuration.serverName ?? configuration.host
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
