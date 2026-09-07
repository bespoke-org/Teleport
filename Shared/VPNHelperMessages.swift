import Foundation

nonisolated enum VPNHelperCommand: String, Codable, Sendable {
    case status
    case startSession
    case stopSession
    case readDiagnostics
}

nonisolated enum VPNHelperSessionPhase: String, Codable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case failed
    case unknown
}

nonisolated struct VPNHelperRequestEnvelope<Payload>: Codable, Sendable, Equatable
where Payload: Codable & Sendable & Equatable {
    let revision: UInt
    let requestID: UUID
    let sessionID: UUID?
    let payload: Payload
}

nonisolated struct VPNHelperResponseEnvelope<Payload>: Codable, Sendable, Equatable
where Payload: Codable & Sendable & Equatable {
    let revision: UInt
    let requestID: UUID
    let sessionID: UUID?
    let payload: Payload?
    let failure: VPNHelperProtocolFailure?
}

nonisolated struct StatusRequest: Codable, Sendable, Equatable {}

nonisolated struct StartSessionRequest: Codable, Sendable, Equatable {
    let stateDirectoryPath: String
    let assetDirectoryPath: String
    let configData: Data
    /// Every proxy server this session dials. Each one needs a host route pinned
    /// to the physical uplink, or the tunnel would carry its own transport.
    let protectedHosts: [String]
    let tunnelInterfaceName: String
    let outboundInterface: String
    /// The root helper has no user defaults of its own, so the app's diagnostics
    /// choice has to travel with the request that acts on it.
    let dumpsSystemState: Bool

    init(
        stateDirectoryPath: String,
        assetDirectoryPath: String,
        configData: Data,
        protectedHosts: [String],
        tunnelInterfaceName: String,
        outboundInterface: String,
        dumpsSystemState: Bool = false
    ) {
        self.stateDirectoryPath = stateDirectoryPath
        self.assetDirectoryPath = assetDirectoryPath
        self.configData = configData
        self.protectedHosts = protectedHosts
        self.tunnelInterfaceName = tunnelInterfaceName
        self.outboundInterface = outboundInterface
        self.dumpsSystemState = dumpsSystemState
    }

    // Decoded leniently so a helper from this build still accepts a request sent by
    // an older client, which has no such field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateDirectoryPath = try container.decode(String.self, forKey: .stateDirectoryPath)
        assetDirectoryPath = try container.decode(String.self, forKey: .assetDirectoryPath)
        configData = try container.decode(Data.self, forKey: .configData)
        protectedHosts = try container.decode([String].self, forKey: .protectedHosts)
        tunnelInterfaceName = try container.decode(String.self, forKey: .tunnelInterfaceName)
        outboundInterface = try container.decode(String.self, forKey: .outboundInterface)
        dumpsSystemState = try container.decodeIfPresent(Bool.self, forKey: .dumpsSystemState) ?? false
    }
}

nonisolated struct StopSessionRequest: Codable, Sendable, Equatable {
    let stateDirectoryPath: String
    let protectedHosts: [String]?
    let outboundInterface: String?
}

nonisolated enum VPNHelperLog: String, Codable, Sendable {
    case config
    case xray
    case control
    /// The helper's own event log, which unlike the others spans sessions and
    /// survives reboots.
    case helper
}

nonisolated struct ReadDiagnosticsRequest: Codable, Sendable, Equatable {
    let log: VPNHelperLog
    let maximumBytes: Int
}

nonisolated struct StatusResponse: Codable, Sendable, Equatable {
    let helperVersion: String
    let phase: VPNHelperSessionPhase
    let summary: String?
    let details: String?
}

nonisolated struct StartSessionResponse: Codable, Sendable, Equatable {
    let phase: VPNHelperSessionPhase
    let summary: String?
    let details: String?
}

nonisolated struct StopSessionResponse: Codable, Sendable, Equatable {
    let phase: VPNHelperSessionPhase
    let summary: String?
    let details: String?
}

nonisolated struct DiagnosticsResponse: Codable, Sendable, Equatable {
    let log: VPNHelperLog
    let text: String
    let metadata: String
    let wasTruncated: Bool
}
