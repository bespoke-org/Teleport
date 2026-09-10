import Foundation

enum ConnectionPhase: String, Codable {
    case unconfigured
    case ready
    case starting
    case running
    case stopping
    case stopped
    case failed
}

enum ProxyPhase: String, Codable {
    case disabled
    case enabling
    case enabled
    case disabling
    case failed
}

enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    case systemProxy
    case vpn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemProxy:
            return "System Proxy"
        case .vpn:
            return "VPN"
        }
    }

    var description: String {
        switch self {
        case .systemProxy:
            return "Routes apps that respect macOS proxy settings through Xray."
        case .vpn:
            return "Full-device Xray TUN tunnel. Requires administrator approval to start and stop."
        }
    }
}

enum SubscriptionConnectionSort: String, Codable, CaseIterable, Identifiable {
    case name
    case latency

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            return "Name"
        case .latency:
            return "Latency"
        }
    }
}

enum ConnectionHealthState: String, Codable {
    case unknown
    case queued
    case checking
    case reachable
    case unreachable
}

enum ConnectionHealthLatencyKind: String, Codable {
    case tcpConnect
    case proxyRequest
    /// Measured from the peer's answer to a WireGuard handshake, which is what a
    /// peer carrying only part of the traffic can be asked.
    case wireGuardHandshake
}

nonisolated struct ConnectionHealthCheck: Codable, Equatable {
    var state: ConnectionHealthState
    var checkedAt: Date?
    var latencyMilliseconds: Int?
    var latencyKind: ConnectionHealthLatencyKind?
    var failureSummary: String?

    static let unknown = ConnectionHealthCheck(
        state: .unknown,
        checkedAt: nil,
        latencyMilliseconds: nil,
        latencyKind: nil,
        failureSummary: nil
    )

    var normalizedForPersistence: ConnectionHealthCheck {
        guard state == .queued || state == .checking else { return self }
        return ConnectionHealthCheck(
            state: checkedAt == nil ? .unknown : .unknown,
            checkedAt: checkedAt,
            latencyMilliseconds: latencyMilliseconds,
            latencyKind: latencyKind,
            failureSummary: failureSummary
        )
    }

}

nonisolated struct ProxyEndpoint: Codable, Equatable {
    let host: String
    let httpPort: Int
    let socksPort: Int

    static let `default` = ProxyEndpoint(host: "127.0.0.1", httpPort: 8080, socksPort: 1080)
}

nonisolated enum ConnectionProtocolType: String, Codable, CaseIterable {
    case vless
    case trojan
    case wireguard

    var displayName: String {
        switch self {
        case .wireguard:
            return "WireGuard"
        case .vless, .trojan:
            return rawValue.uppercased()
        }
    }
}

/// Peer material for Xray's userspace WireGuard outbound. Xray owns the
/// handshake and the interface addresses live inside it, so these fields map
/// onto the outbound's `settings` object rather than onto a utun of their own.
/// The peer endpoint is kept in `ConnectionConfiguration.host`/`port` so route
/// protection, health probing and duplicate filtering stay protocol-neutral.
nonisolated struct WireGuardParameters: Codable, Equatable, Sendable {
    static let defaultAllowedIPs = ["0.0.0.0/0", "::/0"]
    static let defaultMTU = 1420

    /// True when the peer accepts every destination. A peer scoped to a few
    /// subnets cannot carry a request to a public address, so a probe that asks it
    /// to would be measuring the scope, not the peer.
    var carriesDefaultRoute: Bool {
        // "0.0.0.0/1, 128.0.0.0/1" is a common way of writing a default route that
        // wg-quick does not have to install as one.
        let normalized = Set(allowedIPs.map { $0.trimmingCharacters(in: .whitespaces) })
        if normalized.contains("0.0.0.0/0") || normalized.contains("::/0") {
            return true
        }
        return normalized.contains("0.0.0.0/1") && normalized.contains("128.0.0.0/1")
    }

    let secretKey: String
    let peerPublicKey: String
    let presharedKey: String?
    let addresses: [String]
    let allowedIPs: [String]
    let mtu: Int?
    let reserved: [Int]?
    let persistentKeepalive: Int?
    /// Resolvers the peer publishes (`DNS =`). They usually live inside the peer's
    /// network, so they are only reachable through this connection's outbound and
    /// are used for the names routed through it.
    let dnsServers: [String]

    private enum CodingKeys: String, CodingKey {
        case secretKey
        case peerPublicKey
        case presharedKey
        case addresses
        case allowedIPs
        case mtu
        case reserved
        case persistentKeepalive
        case dnsServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        secretKey = try container.decode(String.self, forKey: .secretKey)
        peerPublicKey = try container.decode(String.self, forKey: .peerPublicKey)
        presharedKey = try container.decodeIfPresent(String.self, forKey: .presharedKey)
        addresses = try container.decode([String].self, forKey: .addresses)
        allowedIPs = try container.decodeIfPresent([String].self, forKey: .allowedIPs) ?? WireGuardParameters.defaultAllowedIPs
        mtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        reserved = try container.decodeIfPresent([Int].self, forKey: .reserved)
        persistentKeepalive = try container.decodeIfPresent(Int.self, forKey: .persistentKeepalive)
        dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
    }

    init(
        secretKey: String,
        peerPublicKey: String,
        presharedKey: String? = nil,
        addresses: [String],
        allowedIPs: [String] = WireGuardParameters.defaultAllowedIPs,
        mtu: Int? = nil,
        reserved: [Int]? = nil,
        persistentKeepalive: Int? = nil,
        dnsServers: [String] = []
    ) {
        self.secretKey = secretKey
        self.peerPublicKey = peerPublicKey
        self.presharedKey = presharedKey
        self.addresses = addresses
        self.allowedIPs = allowedIPs
        self.mtu = mtu
        self.reserved = reserved
        self.persistentKeepalive = persistentKeepalive
        self.dnsServers = dnsServers
    }
}

nonisolated enum ConnectionTransport: String, Codable, CaseIterable {
    case tcp
    case ws
    case grpc
    case xhttp
    case raw
}

nonisolated enum ConnectionSecurity: String, Codable, CaseIterable {
    case none
    case tls
    case reality
}

nonisolated struct ConnectionConfiguration: Codable, Equatable {
    let rawLink: String
    let protocolType: ConnectionProtocolType
    let host: String
    let port: Int
    let remarks: String?
    let security: ConnectionSecurity
    let transport: ConnectionTransport
    let path: String?
    let hostHeader: String?
    let serverName: String?
    let alpn: [String]
    let fingerprint: String?
    let publicKey: String?
    let shortID: String?
    let spiderX: String?
    let vlessUserID: String?
    let vlessFlow: String?
    let trojanPassword: String?
    let allowsInsecureTLS: Bool
    let grpcServiceName: String?
    let transportMode: String?
    /// Present exactly when `protocolType` is `.wireguard`; the stream-layer
    /// fields above are unused placeholders for that protocol.
    let wireguard: WireGuardParameters?

    nonisolated var displayName: String {
        if let remarks, !remarks.isEmpty {
            return remarks
        }
        return "\(host):\(port)"
    }

    var endpointSummary: String {
        "\(host):\(port)"
    }

    var descriptiveSummary: String {
        // WireGuard carries its own transport and encryption, so the stream-layer
        // summary would only describe unused placeholder fields.
        if protocolType == .wireguard {
            guard let mtu = wireguard?.mtu else { return protocolType.displayName }
            return "\(protocolType.displayName) • MTU \(mtu)"
        }

        var parts = [protocolType.displayName, securitySummary, transportSummary]

        if let vlessFlow, !vlessFlow.isEmpty, vlessFlow == "xtls-rprx-vision" {
            parts.append("Vision")
        }

        if allowsInsecureTLS {
            parts.append("Insecure TLS")
        }

        return parts.joined(separator: " • ")
    }

    var securityWarningText: String? {
        // WireGuard always encrypts; its `.none` security is a placeholder for the
        // stream layer Xray does not use for this outbound.
        if protocolType == .wireguard {
            return nil
        }

        if security == .none {
            return "Traffic is not encrypted"
        }

        if allowsInsecureTLS {
            return "TLS certificate verification is disabled"
        }

        return nil
    }

    private var securitySummary: String {
        switch security {
        case .none:
            return "No encryption"
        case .tls:
            return "TLS"
        case .reality:
            return "Reality"
        }
    }

    nonisolated var duplicateFilterIdentity: String {
        let components: [String] = [
            protocolType.rawValue,
            host.lowercased(),
            String(port),
            security.rawValue,
            transport.rawValue,
            path ?? "",
            hostHeader?.lowercased() ?? "",
            serverName?.lowercased() ?? "",
            alpn.map { $0.lowercased() }.joined(separator: ","),
            fingerprint?.lowercased() ?? "",
            publicKey ?? "",
            shortID ?? "",
            spiderX ?? "",
            vlessUserID?.lowercased() ?? "",
            vlessFlow?.lowercased() ?? "",
            trojanPassword ?? "",
            allowsInsecureTLS ? "1" : "0",
            grpcServiceName ?? "",
            transportMode?.lowercased() ?? "",
            wireguard?.peerPublicKey ?? "",
            wireguard?.addresses.joined(separator: ",") ?? ""
        ]
        return components.joined(separator: "|")
    }

    /// The name has to live inside `rawLink`, because the app re-parses every
    /// stored link on launch and rebuilds the configuration from it.
    nonisolated func withDisplayName(_ displayName: String) -> ConnectionConfiguration {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionConfiguration(
            rawLink: rawLink.withConnectionName(trimmedDisplayName),
            protocolType: protocolType,
            host: host,
            port: port,
            remarks: trimmedDisplayName,
            security: security,
            transport: transport,
            path: path,
            hostHeader: hostHeader,
            serverName: serverName,
            alpn: alpn,
            fingerprint: fingerprint,
            publicKey: publicKey,
            shortID: shortID,
            spiderX: spiderX,
            vlessUserID: vlessUserID,
            vlessFlow: vlessFlow,
            trojanPassword: trojanPassword,
            allowsInsecureTLS: allowsInsecureTLS,
            grpcServiceName: grpcServiceName,
            transportMode: transportMode,
            wireguard: wireguard
        )
    }

    private var transportSummary: String {
        switch transport {
        case .tcp:
            return "TCP"
        case .ws:
            return "WebSocket"
        case .grpc:
            return "gRPC"
        case .xhttp:
            return "xHTTP"
        case .raw:
            return "RAW"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rawLink
        case protocolType
        case host
        case port
        case remarks
        case security
        case transport
        case path
        case hostHeader
        case serverName
        case alpn
        case fingerprint
        case publicKey
        case shortID
        case spiderX
        case vlessUserID
        case vlessFlow
        case trojanPassword
        case allowsInsecureTLS
        case grpcServiceName
        case transportMode
        case wireguard
    }

    nonisolated init(
        rawLink: String,
        protocolType: ConnectionProtocolType,
        host: String,
        port: Int,
        remarks: String?,
        security: ConnectionSecurity,
        transport: ConnectionTransport,
        path: String?,
        hostHeader: String?,
        serverName: String?,
        alpn: [String],
        fingerprint: String?,
        publicKey: String?,
        shortID: String?,
        spiderX: String?,
        vlessUserID: String?,
        vlessFlow: String?,
        trojanPassword: String?,
        allowsInsecureTLS: Bool = false,
        grpcServiceName: String? = nil,
        transportMode: String? = nil,
        wireguard: WireGuardParameters? = nil
    ) {
        self.rawLink = rawLink
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.remarks = remarks
        self.security = security
        self.transport = transport
        self.path = path
        self.hostHeader = hostHeader
        self.serverName = serverName
        self.alpn = alpn
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.shortID = shortID
        self.spiderX = spiderX
        self.vlessUserID = vlessUserID
        self.vlessFlow = vlessFlow
        self.trojanPassword = trojanPassword
        self.allowsInsecureTLS = allowsInsecureTLS
        self.grpcServiceName = grpcServiceName
        self.transportMode = transportMode
        self.wireguard = wireguard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawLink = try container.decode(String.self, forKey: .rawLink)
        protocolType = try container.decode(ConnectionProtocolType.self, forKey: .protocolType)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        remarks = try container.decodeIfPresent(String.self, forKey: .remarks)
        security = try container.decode(ConnectionSecurity.self, forKey: .security)
        transport = try container.decode(ConnectionTransport.self, forKey: .transport)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        hostHeader = try container.decodeIfPresent(String.self, forKey: .hostHeader)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        alpn = try container.decodeIfPresent([String].self, forKey: .alpn) ?? []
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        shortID = try container.decodeIfPresent(String.self, forKey: .shortID)
        spiderX = try container.decodeIfPresent(String.self, forKey: .spiderX)
        vlessUserID = try container.decodeIfPresent(String.self, forKey: .vlessUserID)
        vlessFlow = try container.decodeIfPresent(String.self, forKey: .vlessFlow)
        trojanPassword = try container.decodeIfPresent(String.self, forKey: .trojanPassword)
        allowsInsecureTLS = try container.decodeIfPresent(Bool.self, forKey: .allowsInsecureTLS) ?? false
        grpcServiceName = try container.decodeIfPresent(String.self, forKey: .grpcServiceName)
        transportMode = try container.decodeIfPresent(String.self, forKey: .transportMode)
        wireguard = try container.decodeIfPresent(WireGuardParameters.self, forKey: .wireguard)
    }
}

private extension String {
    /// A URL link carries its name in the fragment. A WireGuard configuration file
    /// is not a URL: its name is the leading comment, and splitting it on the first
    /// "#" would cut the file off at that comment.
    nonisolated func withConnectionName(_ name: String) -> String {
        guard WireGuardConfigurationParser.looksLikeConfigurationFile(self) else {
            return withFragment(name)
        }

        var lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nameLine = "# " + name
        if let firstMeaningfulIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstMeaningfulIndex].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            lines[firstMeaningfulIndex] = nameLine
        } else {
            lines.insert(nameLine, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    nonisolated func withFragment(_ fragment: String) -> String {
        let base = split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? self
        guard let encodedFragment = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return "\(base)#\(fragment)"
        }
        return "\(base)#\(encodedFragment)"
    }
}

nonisolated struct ConnectionSourceMetadata: Codable, Equatable {
    let subscriptionSourceID: UUID
    let subscriptionEntryID: String
}

nonisolated struct SavedConnection: Codable, Equatable, Identifiable {
    let id: UUID
    /// Mutable so a caller can refresh the parsed configuration on a copy of the
    /// connection instead of rebuilding one, which silently drops every field the
    /// rebuild forgets to carry over.
    var configuration: ConnectionConfiguration
    let savedAt: Date
    let source: ConnectionSourceMetadata?
    var healthCheck: ConnectionHealthCheck?
    /// A name the user gave this connection. It is stored next to the connection
    /// rather than inside the link, because a subscription refresh rebuilds the
    /// configuration from the source and would drop anything written into it.
    var customName: String?

    var isImported: Bool {
        source != nil
    }

    /// What the connection is called everywhere in the app.
    var displayName: String {
        guard let customName, !customName.isEmpty else { return configuration.displayName }
        return customName
    }

    /// The link to share: the user's name is applied to it here, so a shared link
    /// carries the visible name without the stored link ever being rewritten.
    var shareableLink: String {
        guard let customName, !customName.isEmpty else { return configuration.rawLink }
        return configuration.withDisplayName(customName).rawLink
    }

    init(
        id: UUID,
        configuration: ConnectionConfiguration,
        savedAt: Date,
        source: ConnectionSourceMetadata? = nil,
        healthCheck: ConnectionHealthCheck? = nil,
        customName: String? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.savedAt = savedAt
        self.source = source
        self.healthCheck = healthCheck
        self.customName = customName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case savedAt
        case source
        case healthCheck
        case customName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        configuration = try container.decode(ConnectionConfiguration.self, forKey: .configuration)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        source = try container.decodeIfPresent(ConnectionSourceMetadata.self, forKey: .source)
        healthCheck = try container.decodeIfPresent(ConnectionHealthCheck.self, forKey: .healthCheck)?.normalizedForPersistence
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
    }
}

nonisolated struct SubscriptionSource: Codable, Equatable, Identifiable {
    let id: UUID
    var urlString: String
    var title: String
    let savedAt: Date
    var autoUpdateIntervalMinutes: Int?
    var filterDuplicateImports: Bool
    var lastRefreshedAt: Date?
    var lastError: String?
    var lastSkippedCount: Int

    var displayName: String {
        if !title.isEmpty {
            return title
        }

        if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
            return host
        }

        return urlString
    }

    init(
        id: UUID,
        urlString: String,
        title: String,
        savedAt: Date,
        autoUpdateIntervalMinutes: Int? = nil,
        filterDuplicateImports: Bool = true,
        lastRefreshedAt: Date? = nil,
        lastError: String? = nil,
        lastSkippedCount: Int = 0
    ) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.savedAt = savedAt
        self.autoUpdateIntervalMinutes = autoUpdateIntervalMinutes
        self.filterDuplicateImports = filterDuplicateImports
        self.lastRefreshedAt = lastRefreshedAt
        self.lastError = lastError
        self.lastSkippedCount = lastSkippedCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case urlString
        case title
        case savedAt
        case autoUpdateIntervalMinutes
        case filterDuplicateImports
        case lastRefreshedAt
        case lastError
        case lastSkippedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        urlString = try container.decode(String.self, forKey: .urlString)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        autoUpdateIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .autoUpdateIntervalMinutes)
        filterDuplicateImports = try container.decodeIfPresent(Bool.self, forKey: .filterDuplicateImports) ?? true
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastSkippedCount = try container.decodeIfPresent(Int.self, forKey: .lastSkippedCount) ?? 0
    }
}

enum SplitTunnelRuleKind: String, Codable, Equatable {
    case domain
    case ip
    case geosite
    case geoip
}

enum SplitTunnelRuleAction: String, Codable, CaseIterable, Identifiable, Equatable {
    case direct
    case proxy
    case block

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .proxy: return "Proxy"
        case .block: return "Block"
        }
    }
}

struct SplitTunnelRule: Codable, Equatable, Identifiable {
    let id: UUID
    var value: String
    var kind: SplitTunnelRuleKind
    var action: SplitTunnelRuleAction
    var isEnabled: Bool
    /// Which connection a `.proxy` rule leaves through. `nil` means the session's
    /// default connection, which is what every rule written before several
    /// connections could be active at once means. Ignored for other actions.
    var connectionID: UUID?

    init(
        id: UUID = UUID(),
        value: String,
        kind: SplitTunnelRuleKind,
        action: SplitTunnelRuleAction,
        isEnabled: Bool = true,
        connectionID: UUID? = nil
    ) {
        self.id = id
        self.value = value
        self.kind = kind
        self.action = action
        self.isEnabled = isEnabled
        self.connectionID = connectionID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case value
        case kind
        case action
        case isEnabled
        case connectionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        value = try container.decode(String.self, forKey: .value)
        kind = try container.decode(SplitTunnelRuleKind.self, forKey: .kind)
        action = try container.decodeIfPresent(SplitTunnelRuleAction.self, forKey: .action) ?? .direct
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        connectionID = try container.decodeIfPresent(UUID.self, forKey: .connectionID)
    }
}

struct SplitTunnelProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var rules: [SplitTunnelRule]
    /// Outbound for traffic no rule matches. `.proxy` (the default) is the classic
    /// full-tunnel-with-exceptions behavior; `.direct` turns the profile into a
    /// whitelist (only matched destinations use the proxy) without hand-writing a
    /// catch-all rule.
    var defaultAction: SplitTunnelRuleAction

    init(id: UUID = UUID(), name: String, rules: [SplitTunnelRule] = [], defaultAction: SplitTunnelRuleAction = .proxy) {
        self.id = id
        self.name = name
        self.rules = rules
        self.defaultAction = defaultAction
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rules
        case defaultAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        rules = try container.decodeIfPresent([SplitTunnelRule].self, forKey: .rules) ?? []
        defaultAction = try container.decodeIfPresent(SplitTunnelRuleAction.self, forKey: .defaultAction) ?? .proxy
    }
}

struct GeodataSourceSettings: Codable, Equatable {
    var geositeURLString: String?
    var geoipURLString: String?
    var autoUpdateIntervalMinutes: Int?
    var geositeLastUpdatedAt: Date?
    var geoipLastUpdatedAt: Date?
    var geositeLastError: String?
    var geoipLastError: String?

    init(
        geositeURLString: String? = nil,
        geoipURLString: String? = nil,
        autoUpdateIntervalMinutes: Int? = nil,
        geositeLastUpdatedAt: Date? = nil,
        geoipLastUpdatedAt: Date? = nil,
        geositeLastError: String? = nil,
        geoipLastError: String? = nil
    ) {
        self.geositeURLString = geositeURLString
        self.geoipURLString = geoipURLString
        self.autoUpdateIntervalMinutes = autoUpdateIntervalMinutes
        self.geositeLastUpdatedAt = geositeLastUpdatedAt
        self.geoipLastUpdatedAt = geoipLastUpdatedAt
        self.geositeLastError = geositeLastError
        self.geoipLastError = geoipLastError
    }

    private enum CodingKeys: String, CodingKey {
        case geositeURLString
        case geoipURLString
        case autoUpdateIntervalMinutes
        case geositeLastUpdatedAt
        case geoipLastUpdatedAt
        case geositeLastError
        case geoipLastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        geositeURLString = try container.decodeIfPresent(String.self, forKey: .geositeURLString)
        geoipURLString = try container.decodeIfPresent(String.self, forKey: .geoipURLString)
        autoUpdateIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .autoUpdateIntervalMinutes)
        geositeLastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .geositeLastUpdatedAt)
        geoipLastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .geoipLastUpdatedAt)
        geositeLastError = try container.decodeIfPresent(String.self, forKey: .geositeLastError)
        geoipLastError = try container.decodeIfPresent(String.self, forKey: .geoipLastError)
    }
}

struct AppSnapshot: Codable, Equatable {
    var savedConnections: [SavedConnection]
    var subscriptionSources: [SubscriptionSource]
    var selectedConnectionID: UUID?
    var proxyEndpoint: ProxyEndpoint
    var connectionMode: ConnectionMode
    var subscriptionConnectionSort: SubscriptionConnectionSort
    var showsLatencyInMenuBarPicker: Bool
    var animatesMenuBarIcon: Bool
    var splitTunnelProfiles: [SplitTunnelProfile]
    var selectedSplitTunnelProfileID: UUID?
    var isSplitTunnelEnabled: Bool
    /// Whether VPN mode refuses to let traffic reach the physical uplink while a
    /// session is meant to be carrying it. On by default: the windows it covers
    /// open without the user doing anything.
    var isLeakGuardEnabled: Bool
    var geodataSettings: GeodataSourceSettings

    init(
        savedConnections: [SavedConnection],
        subscriptionSources: [SubscriptionSource] = [],
        selectedConnectionID: UUID?,
        proxyEndpoint: ProxyEndpoint,
        connectionMode: ConnectionMode = .vpn,
        subscriptionConnectionSort: SubscriptionConnectionSort = .name,
        showsLatencyInMenuBarPicker: Bool = true,
        animatesMenuBarIcon: Bool = true,
        splitTunnelProfiles: [SplitTunnelProfile] = [SplitTunnelProfile(name: "Default")],
        selectedSplitTunnelProfileID: UUID? = nil,
        isSplitTunnelEnabled: Bool = false,
        isLeakGuardEnabled: Bool = true,
        geodataSettings: GeodataSourceSettings = GeodataSourceSettings()
    ) {
        self.savedConnections = savedConnections
        self.subscriptionSources = subscriptionSources
        self.selectedConnectionID = selectedConnectionID
        self.proxyEndpoint = proxyEndpoint
        self.connectionMode = connectionMode
        self.subscriptionConnectionSort = subscriptionConnectionSort
        self.showsLatencyInMenuBarPicker = showsLatencyInMenuBarPicker
        self.animatesMenuBarIcon = animatesMenuBarIcon
        self.splitTunnelProfiles = splitTunnelProfiles
        self.selectedSplitTunnelProfileID = selectedSplitTunnelProfileID ?? splitTunnelProfiles.first?.id
        self.isSplitTunnelEnabled = isSplitTunnelEnabled
        self.isLeakGuardEnabled = isLeakGuardEnabled
        self.geodataSettings = geodataSettings
    }

    private enum CodingKeys: String, CodingKey {
        case savedConnections
        case subscriptionSources
        case selectedConnectionID
        case proxyEndpoint
        case connectionMode
        case subscriptionConnectionSort
        case showsLatencyInMenuBarPicker
        case animatesMenuBarIcon
        case splitTunnelProfiles
        case selectedSplitTunnelProfileID
        case isSplitTunnelEnabled
        case isLeakGuardEnabled
        case geodataSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        savedConnections = try container.decodeIfPresent([SavedConnection].self, forKey: .savedConnections) ?? []
        subscriptionSources = try container.decodeIfPresent([SubscriptionSource].self, forKey: .subscriptionSources) ?? []
        selectedConnectionID = try container.decodeIfPresent(UUID.self, forKey: .selectedConnectionID)
        proxyEndpoint = try container.decodeIfPresent(ProxyEndpoint.self, forKey: .proxyEndpoint) ?? .default
        connectionMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .vpn
        subscriptionConnectionSort = try container.decodeIfPresent(SubscriptionConnectionSort.self, forKey: .subscriptionConnectionSort) ?? .name
        showsLatencyInMenuBarPicker = try container.decodeIfPresent(Bool.self, forKey: .showsLatencyInMenuBarPicker) ?? true
        animatesMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .animatesMenuBarIcon) ?? true

        if let profiles = try container.decodeIfPresent([SplitTunnelProfile].self, forKey: .splitTunnelProfiles), !profiles.isEmpty {
            splitTunnelProfiles = profiles
        } else {
            splitTunnelProfiles = [SplitTunnelProfile(name: "Default")]
        }

        let decodedSelectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedSplitTunnelProfileID)
        let profileIDs = Set(splitTunnelProfiles.map(\.id))
        if let decodedSelectedProfileID, profileIDs.contains(decodedSelectedProfileID) {
            selectedSplitTunnelProfileID = decodedSelectedProfileID
        } else {
            selectedSplitTunnelProfileID = splitTunnelProfiles.first?.id
        }

        isSplitTunnelEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSplitTunnelEnabled) ?? false
        // A snapshot written before the guard existed gets it on, like a fresh one.
        isLeakGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLeakGuardEnabled) ?? true
        geodataSettings = try container.decodeIfPresent(GeodataSourceSettings.self, forKey: .geodataSettings) ?? GeodataSourceSettings()
    }
}

enum ConfigurationError: LocalizedError, Equatable {
    case invalidScheme
    case missingHost
    case invalidPort
    case missingUser
    case missingPassword
    case invalidUUID
    case unsupportedTransport(String)
    case unsupportedSecurity(String)
    case unsupportedFlow(String)
    case missingParameter(String)
    case malformedQuery
    case invalidWireGuardKey(String)
    case multipleWireGuardPeers

    var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Paste a vless://, trojan:// or wireguard:// link, or a WireGuard [Interface] configuration"
        case .missingHost:
            return "Server host is missing"
        case .invalidPort:
            return "Port is missing or invalid"
        case .missingUser:
            return "Required user component is missing"
        case .missingPassword:
            return "Trojan password is missing"
        case .invalidUUID:
            return "VLESS user id must be a valid UUID"
        case let .unsupportedTransport(value):
            return "Unsupported transport for this release: \(value)"
        case let .unsupportedSecurity(value):
            return "Unsupported security for this release: \(value)"
        case let .unsupportedFlow(value):
            return "Unsupported flow for this release: \(value)"
        case let .missingParameter(name):
            return "Missing required parameter: \(name)"
        case .malformedQuery:
            return "The connection link contains malformed query parameters"
        case let .invalidWireGuardKey(name):
            return "WireGuard \(name) must be a base64-encoded 32-byte key"
        case .multipleWireGuardPeers:
            return "WireGuard configurations with more than one peer are not supported"
        }
    }
}

enum SubscriptionError: LocalizedError, Equatable {
    case invalidURL
    case duplicateSource
    case networkFailure(String)
    case invalidResponse
    case emptyPayload
    case noSupportedEntries

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Subscription URL must start with http:// or https://"
        case .duplicateSource:
            return "This subscription has already been added"
        case let .networkFailure(message):
            return message.isEmpty ? "Failed to fetch subscription" : message
        case .invalidResponse:
            return "Subscription server returned an invalid response"
        case .emptyPayload:
            return "Subscription did not contain any links"
        case .noSupportedEntries:
            return "Subscription does not contain any supported VLESS or Trojan links"
        }
    }
}
