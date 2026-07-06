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
}

struct ConnectionHealthCheck: Codable, Equatable {
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

struct ProxyEndpoint: Codable, Equatable {
    let host: String
    let httpPort: Int
    let socksPort: Int

    static let `default` = ProxyEndpoint(host: "127.0.0.1", httpPort: 8080, socksPort: 1080)
}

enum ConnectionProtocolType: String, Codable, CaseIterable {
    case vless
    case trojan

    var displayName: String {
        rawValue.uppercased()
    }
}

enum ConnectionTransport: String, Codable, CaseIterable {
    case tcp
    case ws
    case grpc
    case xhttp
    case raw
}

enum ConnectionSecurity: String, Codable, CaseIterable {
    case none
    case tls
    case reality
}

struct ConnectionConfiguration: Codable, Equatable {
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
            transportMode?.lowercased() ?? ""
        ]
        return components.joined(separator: "|")
    }

    nonisolated func withDisplayName(_ displayName: String) -> ConnectionConfiguration {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionConfiguration(
            rawLink: rawLink.withFragment(trimmedDisplayName),
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
            transportMode: transportMode
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
        transportMode: String? = nil
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
    }
}

private extension String {
    nonisolated func withFragment(_ fragment: String) -> String {
        let base = split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? self
        guard let encodedFragment = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return "\(base)#\(fragment)"
        }
        return "\(base)#\(encodedFragment)"
    }
}

struct ConnectionSourceMetadata: Codable, Equatable {
    let subscriptionSourceID: UUID
    let subscriptionEntryID: String
}

struct SavedConnection: Codable, Equatable, Identifiable {
    let id: UUID
    let configuration: ConnectionConfiguration
    let savedAt: Date
    let source: ConnectionSourceMetadata?
    var healthCheck: ConnectionHealthCheck?

    var isImported: Bool {
        source != nil
    }

    init(
        id: UUID,
        configuration: ConnectionConfiguration,
        savedAt: Date,
        source: ConnectionSourceMetadata? = nil,
        healthCheck: ConnectionHealthCheck? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.savedAt = savedAt
        self.source = source
        self.healthCheck = healthCheck
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case savedAt
        case source
        case healthCheck
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        configuration = try container.decode(ConnectionConfiguration.self, forKey: .configuration)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        source = try container.decodeIfPresent(ConnectionSourceMetadata.self, forKey: .source)
        healthCheck = try container.decodeIfPresent(ConnectionHealthCheck.self, forKey: .healthCheck)?.normalizedForPersistence
    }
}

struct SubscriptionSource: Codable, Equatable, Identifiable {
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

    init(
        id: UUID = UUID(),
        value: String,
        kind: SplitTunnelRuleKind,
        action: SplitTunnelRuleAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.value = value
        self.kind = kind
        self.action = action
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case value
        case kind
        case action
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        value = try container.decode(String.self, forKey: .value)
        kind = try container.decode(SplitTunnelRuleKind.self, forKey: .kind)
        action = try container.decodeIfPresent(SplitTunnelRuleAction.self, forKey: .action) ?? .direct
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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
    var splitTunnelRules: [SplitTunnelRule]
    var isSplitTunnelEnabled: Bool

    init(
        savedConnections: [SavedConnection],
        subscriptionSources: [SubscriptionSource] = [],
        selectedConnectionID: UUID?,
        proxyEndpoint: ProxyEndpoint,
        connectionMode: ConnectionMode = .vpn,
        subscriptionConnectionSort: SubscriptionConnectionSort = .name,
        showsLatencyInMenuBarPicker: Bool = true,
        animatesMenuBarIcon: Bool = true,
        splitTunnelRules: [SplitTunnelRule] = [],
        isSplitTunnelEnabled: Bool = false
    ) {
        self.savedConnections = savedConnections
        self.subscriptionSources = subscriptionSources
        self.selectedConnectionID = selectedConnectionID
        self.proxyEndpoint = proxyEndpoint
        self.connectionMode = connectionMode
        self.subscriptionConnectionSort = subscriptionConnectionSort
        self.showsLatencyInMenuBarPicker = showsLatencyInMenuBarPicker
        self.animatesMenuBarIcon = animatesMenuBarIcon
        self.splitTunnelRules = splitTunnelRules
        self.isSplitTunnelEnabled = isSplitTunnelEnabled
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
        case splitTunnelRules
        case isSplitTunnelEnabled
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
        splitTunnelRules = try container.decodeIfPresent([SplitTunnelRule].self, forKey: .splitTunnelRules) ?? []
        isSplitTunnelEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSplitTunnelEnabled) ?? false
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

    var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Connection link must start with vless:// or trojan://"
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

struct LegacyVLESSConfiguration: Codable, Equatable {
    let rawLink: String
    let id: UUID
    let userID: String
    let host: String
    let port: Int
    let remarks: String?
    let security: ConnectionSecurity
    let transport: ConnectionTransport
    let flow: String?
    let path: String?
    let serverName: String?
    let alpn: [String]
    let fingerprint: String?
    let publicKey: String?
    let shortID: String?
    let spiderX: String?
}

struct LegacyPersistedConfiguration: Codable, Equatable {
    let configuration: LegacyVLESSConfiguration
    let savedAt: Date
}

struct LegacyAppSnapshot: Codable, Equatable {
    var persistedConfiguration: LegacyPersistedConfiguration?
    var proxyEndpoint: ProxyEndpoint
}

extension LegacyVLESSConfiguration {
    var asConnectionConfiguration: ConnectionConfiguration {
        ConnectionConfiguration(
            rawLink: rawLink,
            protocolType: .vless,
            host: host,
            port: port,
            remarks: remarks,
            security: security,
            transport: transport,
            path: path,
            hostHeader: nil,
            serverName: serverName,
            alpn: alpn,
            fingerprint: fingerprint,
            publicKey: publicKey,
            shortID: shortID,
            spiderX: spiderX,
            vlessUserID: userID,
            vlessFlow: flow,
            trojanPassword: nil,
            allowsInsecureTLS: false,
            grpcServiceName: nil,
            transportMode: nil
        )
    }
}

extension LegacyAppSnapshot {
    var asAppSnapshot: AppSnapshot {
        let savedConnections = persistedConfiguration.map {
            [
                SavedConnection(
                    id: $0.configuration.id,
                    configuration: $0.configuration.asConnectionConfiguration,
                    savedAt: $0.savedAt,
                    source: nil
                )
            ]
        } ?? []

        return AppSnapshot(
            savedConnections: savedConnections,
            subscriptionSources: [],
            selectedConnectionID: savedConnections.first?.id,
            proxyEndpoint: proxyEndpoint
        )
    }
}
