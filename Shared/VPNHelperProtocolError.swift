import Foundation

nonisolated protocol VPNHelperClientPresentableError: Error, Sendable {
    var clientSummary: String { get }
}

nonisolated enum VPNHelperFailureCode: String, Codable, Sendable {
    case incompatibleService
    case malformedPayload
    case payloadTooLarge
    case requestConflict
    case inProgress
    case commandFailed
    case unavailable
    case interrupted
    case invalidated
    case deadlineExceeded
    case indeterminate
}

nonisolated enum VPNHelperRetryDisposition: String, Codable, Sendable {
    case never
    case reconnectAndQueryStatus
    case reinstallService
}

nonisolated struct VPNHelperProtocolFailure: Codable, Sendable, Equatable, Error {
    let code: VPNHelperFailureCode
    let summary: String
    let details: String?
    let retryDisposition: VPNHelperRetryDisposition
}

private nonisolated enum VPNHelperSessionRequirement {
    case absent
    case required
    case optional
}

private nonisolated protocol VPNHelperPayloadValidating {
    static var sessionRequirement: VPNHelperSessionRequirement { get }
    func validate() throws
}

extension StatusRequest: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .absent
    fileprivate func validate() throws {}
}

extension StartSessionRequest: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .required

    fileprivate func validate() throws {
        try validateStateDirectoryPath(stateDirectoryPath)
        try validateNonEmpty(assetDirectoryPath, field: "assetDirectoryPath")
        guard assetDirectoryPath.hasPrefix("/"),
              assetDirectoryPath == URL(fileURLWithPath: assetDirectoryPath).standardizedFileURL.path else {
            throw protocolFailure(.malformedPayload, "The asset directory path is not a normalized absolute path")
        }
        guard !configData.isEmpty else {
            throw protocolFailure(.malformedPayload, "The Xray configuration is empty")
        }
        guard configData.count <= VPNHelperProtocol.maximumConfigurationBytes else {
            throw protocolFailure(.payloadTooLarge, "The Xray configuration exceeds the protocol limit")
        }
        guard !protectedHosts.isEmpty else {
            throw protocolFailure(.malformedPayload, "The session has no protected hosts")
        }
        guard protectedHosts.count <= VPNHelperProtocol.maximumProtectedHosts else {
            throw protocolFailure(.payloadTooLarge, "The session exceeds the protected host limit")
        }
        for protectedHost in protectedHosts {
            try validateNonEmpty(protectedHost, field: "protectedHosts")
        }
        try validateNonEmpty(tunnelInterfaceName, field: "tunnelInterfaceName")
        try validateNonEmpty(outboundInterface, field: "outboundInterface")
    }
}

extension StopSessionRequest: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .required

    fileprivate func validate() throws {
        try validateStateDirectoryPath(stateDirectoryPath)
        if let protectedHosts {
            guard protectedHosts.count <= VPNHelperProtocol.maximumProtectedHosts else {
                throw protocolFailure(.payloadTooLarge, "The session exceeds the protected host limit")
            }
            for protectedHost in protectedHosts {
                try validateNonEmpty(protectedHost, field: "protectedHosts")
            }
        }
        if let outboundInterface {
            try validateNonEmpty(outboundInterface, field: "outboundInterface")
        }
    }
}

extension ReadDiagnosticsRequest: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .absent

    fileprivate func validate() throws {
        guard maximumBytes > 0 else {
            throw protocolFailure(.malformedPayload, "The diagnostics byte limit must be positive")
        }
        guard maximumBytes <= VPNHelperProtocol.maximumDiagnosticsBytes else {
            throw protocolFailure(.payloadTooLarge, "The diagnostics byte limit exceeds the protocol limit")
        }
    }
}

extension StatusResponse: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .optional

    fileprivate func validate() throws {
        try validateNonEmpty(helperVersion, field: "helperVersion")
        try validateDiagnosticText(summary)
        try validateDiagnosticText(details)
    }
}

extension StartSessionResponse: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .required

    fileprivate func validate() throws {
        try validateDiagnosticText(summary)
        try validateDiagnosticText(details)
    }
}

extension StopSessionResponse: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .required

    fileprivate func validate() throws {
        try validateDiagnosticText(summary)
        try validateDiagnosticText(details)
    }
}

extension DiagnosticsResponse: VPNHelperPayloadValidating {
    fileprivate static let sessionRequirement: VPNHelperSessionRequirement = .absent

    fileprivate func validate() throws {
        guard text.lengthOfBytes(using: .utf8) <= VPNHelperProtocol.maximumDiagnosticsBytes else {
            throw protocolFailure(.payloadTooLarge, "The diagnostics response exceeds the protocol limit")
        }
        try validateDiagnosticText(metadata)
    }
}

nonisolated enum VPNHelperCodec {
    static func encodeRequest<Payload>(_ envelope: VPNHelperRequestEnvelope<Payload>) throws -> Data
    where Payload: Codable & Sendable & Equatable {
        try validateRevision(envelope.revision)
        try validateSessionID(envelope.sessionID, payloadType: Payload.self)
        try validatePayload(envelope.payload)
        return try encode(envelope, maximumBytes: VPNHelperProtocol.maximumRequestBytes)
    }

    static func decodeRequest<Payload>(_ data: Data) throws -> VPNHelperRequestEnvelope<Payload>
    where Payload: Codable & Sendable & Equatable {
        try validateEncodedSize(data, maximumBytes: VPNHelperProtocol.maximumRequestBytes)
        let envelope: VPNHelperRequestEnvelope<Payload> = try decode(data)
        try validateRevision(envelope.revision)
        try validateSessionID(envelope.sessionID, payloadType: Payload.self)
        try validatePayload(envelope.payload)
        return envelope
    }

    static func encodeResponse<Payload>(_ envelope: VPNHelperResponseEnvelope<Payload>) throws -> Data
    where Payload: Codable & Sendable & Equatable {
        try validateRevision(envelope.revision)
        try validateResponseShape(payload: envelope.payload, failure: envelope.failure)
        if let payload = envelope.payload {
            try validateSessionID(envelope.sessionID, payloadType: Payload.self)
            try validatePayload(payload)
        }
        if let failure = envelope.failure {
            try validateFailure(failure)
        }
        return try encode(envelope, maximumBytes: VPNHelperProtocol.maximumResponseBytes)
    }

    static func decodeResponse<Payload>(_ data: Data) throws -> VPNHelperResponseEnvelope<Payload>
    where Payload: Codable & Sendable & Equatable {
        try validateEncodedSize(data, maximumBytes: VPNHelperProtocol.maximumResponseBytes)
        let envelope: VPNHelperResponseEnvelope<Payload> = try decode(data)
        try validateRevision(envelope.revision)
        try validateResponseShape(payload: envelope.payload, failure: envelope.failure)
        if let payload = envelope.payload {
            try validateSessionID(envelope.sessionID, payloadType: Payload.self)
            try validatePayload(payload)
        }
        if let failure = envelope.failure {
            try validateFailure(failure)
        }
        return envelope
    }

    private static func encode<Value: Encodable>(_ value: Value, maximumBytes: Int) throws -> Data {
        do {
            let data = try JSONEncoder().encode(value)
            try validateEncodedSize(data, maximumBytes: maximumBytes)
            return data
        } catch let failure as VPNHelperProtocolFailure {
            throw failure
        } catch {
            throw protocolFailure(.malformedPayload, "The protocol value could not be encoded", details: String(describing: error))
        }
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let failure as VPNHelperProtocolFailure {
            throw failure
        } catch {
            throw protocolFailure(.malformedPayload, "The protocol payload could not be decoded", details: String(describing: error))
        }
    }

    private static func validateEncodedSize(_ data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty else {
            throw protocolFailure(.malformedPayload, "The protocol payload is empty")
        }
        guard data.count <= maximumBytes else {
            throw protocolFailure(.payloadTooLarge, "The encoded protocol payload exceeds the protocol limit")
        }
    }

    private static func validateRevision(_ revision: UInt) throws {
        guard revision == VPNHelperProtocol.revision else {
            throw protocolFailure(
                .incompatibleService,
                "The privileged helper protocol revision is incompatible",
                retryDisposition: .reinstallService
            )
        }
    }

    private static func validatePayload<Payload>(_ payload: Payload) throws {
        if let payload = payload as? any VPNHelperPayloadValidating {
            try payload.validate()
        }
    }

    private static func validateSessionID<Payload>(_ sessionID: UUID?, payloadType: Payload.Type) throws {
        guard let payloadType = payloadType as? any VPNHelperPayloadValidating.Type else { return }
        switch payloadType.sessionRequirement {
        case .absent:
            guard sessionID == nil else {
                throw protocolFailure(.malformedPayload, "This command must not include a session identifier")
            }
        case .required:
            guard sessionID != nil else {
                throw protocolFailure(.malformedPayload, "This command requires a session identifier")
            }
        case .optional:
            break
        }
    }

    private static func validateResponseShape<Payload>(
        payload: Payload?,
        failure: VPNHelperProtocolFailure?
    ) throws {
        guard (payload == nil) != (failure == nil) else {
            throw protocolFailure(.malformedPayload, "A response must contain either a payload or a failure")
        }
    }

    private static func validateFailure(_ failure: VPNHelperProtocolFailure) throws {
        try validateNonEmpty(failure.summary, field: "failure.summary")
        try validateDiagnosticText(failure.summary)
        try validateDiagnosticText(failure.details)
    }
}

private nonisolated func validateStateDirectoryPath(_ path: String) throws {
    try validateNonEmpty(path, field: "stateDirectoryPath")
    guard path.hasPrefix("/"), path == URL(fileURLWithPath: path).standardizedFileURL.path else {
        throw protocolFailure(.malformedPayload, "The state directory path is not a normalized absolute path")
    }

    if path == PrivilegedHelperConstants.helperStateDirectoryPath {
        return
    }

    let prefix = "/Users/"
    let suffix = "/Library/Application Support/teleport"
    guard path.hasPrefix(prefix), path.hasSuffix(suffix) else {
        throw protocolFailure(.malformedPayload, "The state directory path is outside the allowlisted root")
    }
    let username = path.dropFirst(prefix.count).dropLast(suffix.count)
    guard !username.isEmpty, !username.contains("/") else {
        throw protocolFailure(.malformedPayload, "The state directory path is outside the allowlisted root")
    }
}

private nonisolated func validateNonEmpty(_ value: String, field: String) throws {
    guard !value.isEmpty,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw protocolFailure(.malformedPayload, "The \(field) field is empty or contains surrounding whitespace")
    }
}

private nonisolated func validateDiagnosticText(_ value: String?) throws {
    guard let value else { return }
    guard value.lengthOfBytes(using: .utf8) <= 4_096 else {
        throw protocolFailure(.payloadTooLarge, "Protocol diagnostic metadata exceeds the protocol limit")
    }
}

private nonisolated func protocolFailure(
    _ code: VPNHelperFailureCode,
    _ summary: String,
    details: String? = nil,
    retryDisposition: VPNHelperRetryDisposition = .never
) -> VPNHelperProtocolFailure {
    VPNHelperProtocolFailure(
        code: code,
        summary: summary,
        details: details,
        retryDisposition: retryDisposition
    )
}
