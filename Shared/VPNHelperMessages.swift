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
