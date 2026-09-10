import Foundation

nonisolated enum VPNHelperCommand: String, Codable, Sendable {
    case status
    case startSession
    case stopSession
    case readDiagnostics
    case engageLeakGuard
    case releaseLeakGuard
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

/// Asks the helper to keep traffic off the physical uplink until it is released
/// or the lease runs out.
///
/// `tunnelInterfaceName` is present only once a session owns one: before that
/// there is no tunnel for traffic to legitimately leave through, and the guard is
/// correspondingly stricter.
nonisolated struct EngageLeakGuardRequest: Codable, Sendable, Equatable {
    let tunnelInterfaceName: String?
    /// The numeric proxy-server addresses whose transport carries everything else
    /// and so cannot itself be blocked.
    let protectedHosts: [String]
    /// How long the helper keeps the guard without hearing from this client again.
    /// A client that stops renewing has stopped running, and the machine must not
    /// stay off the network because of it.
    let leaseSeconds: Double
}

nonisolated struct ReleaseLeakGuardRequest: Codable, Sendable, Equatable {}

nonisolated struct LeakGuardResponse: Codable, Sendable, Equatable {
    let isEngaged: Bool
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
