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
        try verifyLeakGuardRoundTripAndBounds()
        print("test_xpc_protocol: all checks passed")
    }

    private static func verifyExactRevisionAndStartRoundTrip() throws {
        let requestID = UUID()
        let sessionID = UUID()
        let request = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                assetDirectoryPath: "/Users/test/Library/Application Support/teleport/geodata-resolved",
                configData: Data("{}".utf8),
                protectedHosts: ["example.com"],
                tunnelInterfaceName: "utun9",
                outboundInterface: "en0"
            )
        )
        let encoded = try TUNHelperCodec.encodeRequest(request)
        let decoded: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(encoded)
        precondition(decoded == request)
    }

    /// The guard spans the teardown and rebuild a session change consists of, so it
    /// carries no session identifier, and its lease is bounded so a client cannot
    /// ask for one it never has to renew.
    private static func verifyLeakGuardRoundTripAndBounds() throws {
        let request = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: EngageLeakGuardRequest(
                tunnelInterfaceName: "utun9",
                protectedHosts: ["203.0.113.7"],
                leaseSeconds: 180
            )
        )
        let encoded = try TUNHelperCodec.encodeRequest(request)
        let decoded: TUNHelperRequestEnvelope<EngageLeakGuardRequest> = try TUNHelperCodec.decodeRequest(encoded)
        precondition(decoded == request)

        // A standby guard has no tunnel yet, which is the state it exists for.
        let standby = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: EngageLeakGuardRequest(tunnelInterfaceName: nil, protectedHosts: [], leaseSeconds: 60)
        )
        precondition((try? TUNHelperCodec.encodeRequest(standby)) != nil, "a standby guard request must encode")

        let sessionScoped = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: EngageLeakGuardRequest(tunnelInterfaceName: "utun9", protectedHosts: [], leaseSeconds: 60)
        )
        precondition((try? TUNHelperCodec.encodeRequest(sessionScoped)) == nil, "a guard request must not carry a session identifier")

        let unbounded = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: EngageLeakGuardRequest(
                tunnelInterfaceName: nil,
                protectedHosts: [],
                leaseSeconds: TUNHelperProtocol.maximumLeakGuardLeaseSeconds + 1
            )
        )
        precondition((try? TUNHelperCodec.encodeRequest(unbounded)) == nil, "a lease beyond the protocol limit must be rejected")
    }

    private static func verifyAllResponseRoundTrips() throws {
        let requestID = UUID()
        let sessionID = UUID()

        try roundTrip(TUNHelperResponseEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StatusResponse(helperVersion: "8", phase: .running, summary: "Running", details: nil),
            failure: nil
        ))
        try roundTrip(TUNHelperResponseEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionResponse(phase: .running, summary: "Started", details: nil),
            failure: nil
        ))
        try roundTrip(TUNHelperResponseEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StopSessionResponse(phase: .idle, summary: "Stopped", details: nil),
            failure: nil
        ))
        try roundTrip(TUNHelperResponseEnvelope(
            revision: TUNHelperProtocol.revision,
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
        let failure = TUNHelperProtocolFailure(
            code: .commandFailed,
            summary: "Command failed",
            details: "Xray exited",
            retryDisposition: .never
        )
        try roundTrip(TUNHelperResponseEnvelope<StartSessionResponse>(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: nil,
            failure: failure
        ))
        try roundTrip(TUNHelperResponseEnvelope<StopSessionResponse>(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: nil,
            failure: failure
        ))
    }

    private static func verifyRevisionRejection() throws {
        let request = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision + 1,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        )
        let rawData = try JSONEncoder().encode(request)
        expectFailure(.incompatibleService) {
            let _: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(rawData)
        }
    }

    private static func verifyRequestSessionValidation() throws {
        expectRequestSessionFailure(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                assetDirectoryPath: "/Users/test/Library/Application Support/teleport/geodata-resolved",
                configData: Data("{}".utf8),
                protectedHosts: ["example.com"],
                tunnelInterfaceName: "utun1",
                outboundInterface: "en0"
            )
        ))
        expectRequestSessionFailure(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StopSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                protectedHosts: ["example.com"],
                outboundInterface: "en0"
            )
        ))
        expectRequestSessionFailure(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: StatusRequest()
        ))
        expectRequestSessionFailure(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: ReadDiagnosticsRequest(log: .xray, maximumBytes: 1_024)
        ))
    }

    private static func verifyConfigurationBounds() throws {
        let accepted = startRequest(configData: Data(repeating: 0x61, count: TUNHelperProtocol.maximumConfigurationBytes))
        _ = try TUNHelperCodec.encodeRequest(accepted)

        let rejected = startRequest(configData: Data(repeating: 0x61, count: TUNHelperProtocol.maximumConfigurationBytes + 1))
        expectFailure(.payloadTooLarge) {
            _ = try TUNHelperCodec.encodeRequest(rejected)
        }
    }

    private static func verifyDiagnosticsBounds() throws {
        let accepted = diagnosticsResponse(textBytes: TUNHelperProtocol.maximumDiagnosticsBytes)
        _ = try TUNHelperCodec.encodeResponse(accepted)

        let rejected = diagnosticsResponse(textBytes: TUNHelperProtocol.maximumDiagnosticsBytes + 1)
        expectFailure(.payloadTooLarge) {
            _ = try TUNHelperCodec.encodeResponse(rejected)
        }
    }

    private static func startRequest(configData: Data) -> TUNHelperRequestEnvelope<StartSessionRequest> {
        TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: UUID(),
            payload: StartSessionRequest(
                stateDirectoryPath: "/var/db/dev.x.teleport",
                assetDirectoryPath: "/Users/test/Library/Application Support/teleport/geodata-resolved",
                configData: configData,
                protectedHosts: ["example.com"],
                tunnelInterfaceName: "utun1",
                outboundInterface: "en0"
            )
        )
    }

    private static func diagnosticsResponse(textBytes: Int) -> TUNHelperResponseEnvelope<DiagnosticsResponse> {
        TUNHelperResponseEnvelope(
            revision: TUNHelperProtocol.revision,
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

    private static func roundTrip<Payload>(_ response: TUNHelperResponseEnvelope<Payload>) throws
    where Payload: Codable & Sendable & Equatable {
        let encoded = try TUNHelperCodec.encodeResponse(response)
        let decoded: TUNHelperResponseEnvelope<Payload> = try TUNHelperCodec.decodeResponse(encoded)
        precondition(decoded == response)
    }

    private static func expectRequestSessionFailure<Payload>(
        _ request: TUNHelperRequestEnvelope<Payload>
    ) where Payload: Codable & Sendable & Equatable {
        expectFailure(.malformedPayload) {
            _ = try TUNHelperCodec.encodeRequest(request)
        }

        let rawData: Data
        do {
            rawData = try JSONEncoder().encode(request)
        } catch {
            preconditionFailure("Could not create malformed request fixture: \(error)")
        }
        expectFailure(.malformedPayload) {
            let _: TUNHelperRequestEnvelope<Payload> = try TUNHelperCodec.decodeRequest(rawData)
        }
    }

    private static func expectFailure(
        _ code: TUNHelperFailureCode,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            preconditionFailure("Expected protocol failure \(code.rawValue)")
        } catch let failure as TUNHelperProtocolFailure {
            precondition(failure.code == code)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }
}
