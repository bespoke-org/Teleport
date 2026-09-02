import Foundation

@main
struct XPCProtocolVerification {
    static func main() throws {
        try verifyExactRevisionAndStartRoundTrip()
        try verifyAllResponseRoundTrips()
        try verifyStructuredFailureRoundTripsWithoutSessionIDs()
        try verifyRevisionRejection()
        try verifyRequestSessionValidation()
        try verifyConfigurationBounds()
        try verifyDiagnosticsBounds()
        print("verify_xpc_protocol: all checks passed")
    }

    private static func verifyExactRevisionAndStartRoundTrip() throws {
        precondition(VPNHelperProtocol.revision == 8)

        let requestID = UUID()
        let sessionID = UUID()
        let request = VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                configData: Data("{}".utf8),
                protectedHost: "example.com",
                tunnelInterfaceName: "utun9",
                outboundInterface: "en0"
            )
        )
        let encoded = try VPNHelperCodec.encodeRequest(request)
        let decoded: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(encoded)
        precondition(decoded == request)
    }

    private static func verifyAllResponseRoundTrips() throws {
        let requestID = UUID()
        let sessionID = UUID()

        try roundTrip(VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StatusResponse(helperVersion: "8", phase: .running, summary: "Running", details: nil),
            failure: nil
        ))
        try roundTrip(VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionResponse(phase: .running, summary: "Started", details: nil),
            failure: nil
        ))
        try roundTrip(VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StopSessionResponse(phase: .idle, summary: "Stopped", details: nil),
            failure: nil
        ))
        try roundTrip(VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: nil,
            payload: DiagnosticsResponse(
                log: .control,
                text: "diagnostic",
                metadata: "9 bytes",
                wasTruncated: false
            ),
            failure: nil
        ))
    }

    private static func verifyStructuredFailureRoundTripsWithoutSessionIDs() throws {
        let failure = VPNHelperProtocolFailure(
            code: .commandFailed,
            summary: "Command failed",
            details: "Xray exited",
            retryDisposition: .never
        )
        try roundTrip(VPNHelperResponseEnvelope<StartSessionResponse>(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: nil,
            failure: failure
        ))
        try roundTrip(VPNHelperResponseEnvelope<StopSessionResponse>(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: nil,
            failure: failure
        ))
    }

    private static func verifyRevisionRejection() throws {
        let request = VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision + 1,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        )
        let rawData = try JSONEncoder().encode(request)
        expectFailure(.incompatibleService) {
            let _: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(rawData)
        }
    }

    private static func verifyRequestSessionValidation() throws {
        expectRequestSessionFailure(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                configData: Data("{}".utf8),
                protectedHost: "example.com",
                tunnelInterfaceName: "utun1",
                outboundInterface: "en0"
            )
        ))
        expectRequestSessionFailure(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StopSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                protectedHost: "example.com",
                outboundInterface: "en0"
            )
        ))
        expectRequestSessionFailure(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: StatusRequest()
        ))
        expectRequestSessionFailure(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: ReadDiagnosticsRequest(log: .xray, maximumBytes: 1_024)
        ))
    }

    private static func verifyConfigurationBounds() throws {
        let accepted = startRequest(configData: Data(repeating: 0x61, count: VPNHelperProtocol.maximumConfigurationBytes))
        _ = try VPNHelperCodec.encodeRequest(accepted)

        let rejected = startRequest(configData: Data(repeating: 0x61, count: VPNHelperProtocol.maximumConfigurationBytes + 1))
        expectFailure(.payloadTooLarge) {
            _ = try VPNHelperCodec.encodeRequest(rejected)
        }
    }

    private static func verifyDiagnosticsBounds() throws {
        let accepted = diagnosticsResponse(textBytes: VPNHelperProtocol.maximumDiagnosticsBytes)
        _ = try VPNHelperCodec.encodeResponse(accepted)

        let rejected = diagnosticsResponse(textBytes: VPNHelperProtocol.maximumDiagnosticsBytes + 1)
        expectFailure(.payloadTooLarge) {
            _ = try VPNHelperCodec.encodeResponse(rejected)
        }
    }

    private static func startRequest(configData: Data) -> VPNHelperRequestEnvelope<StartSessionRequest> {
        VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                configData: configData,
                protectedHost: "example.com",
                tunnelInterfaceName: "utun1",
                outboundInterface: "en0"
            )
        )
    }

    private static func diagnosticsResponse(textBytes: Int) -> VPNHelperResponseEnvelope<DiagnosticsResponse> {
        VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: DiagnosticsResponse(
                log: .xray,
                text: String(repeating: "x", count: textBytes),
                metadata: "test",
                wasTruncated: false
            ),
            failure: nil
        )
    }

    private static func roundTrip<Payload>(_ response: VPNHelperResponseEnvelope<Payload>) throws
    where Payload: Codable & Sendable & Equatable {
        let encoded = try VPNHelperCodec.encodeResponse(response)
        let decoded: VPNHelperResponseEnvelope<Payload> = try VPNHelperCodec.decodeResponse(encoded)
        precondition(decoded == response)
    }

    private static func expectRequestSessionFailure<Payload>(
        _ request: VPNHelperRequestEnvelope<Payload>
    ) where Payload: Codable & Sendable & Equatable {
        expectFailure(.malformedPayload) {
            _ = try VPNHelperCodec.encodeRequest(request)
        }

        let rawData: Data
        do {
            rawData = try JSONEncoder().encode(request)
        } catch {
            preconditionFailure("Could not create malformed request fixture: \(error)")
        }
        expectFailure(.malformedPayload) {
            let _: VPNHelperRequestEnvelope<Payload> = try VPNHelperCodec.decodeRequest(rawData)
        }
    }

    private static func expectFailure(
        _ code: VPNHelperFailureCode,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            preconditionFailure("Expected protocol failure \(code.rawValue)")
        } catch let failure as VPNHelperProtocolFailure {
            precondition(failure.code == code)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }
}
