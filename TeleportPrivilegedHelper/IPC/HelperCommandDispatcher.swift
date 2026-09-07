import Foundation

actor HelperCommandDispatcher {
    private struct RequestMetadata: Decodable {
        let revision: UInt
        let requestID: UUID
        let sessionID: UUID?
    }

    private let executor: any HelperCommandExecuting
    private var ledger: HelperRequestLedger
    private var executionTail: Task<Void, Never>?
    /// Same-daemon correlation only. PID/process evidence remains owned by the executor,
    /// and a helper restart intentionally loses this observation.
    private var observedSessionID: UUID?
    private var queuedSessionID: UUID?
    private var queuedPhase: VPNHelperSessionPhase?
    private var observedFailureSummary: String?
    private var correlationGeneration: UInt64 = 0
    private let onRequestAdmitted: @Sendable (VPNHelperCommand) -> Void

    init(
        executor: any HelperCommandExecuting,
        ledger: HelperRequestLedger = HelperRequestLedger(
            maximumEntries: 128,
            maximumAge: 10 * 60
        ),
        onRequestAdmitted: @escaping @Sendable (VPNHelperCommand) -> Void = { _ in }
    ) {
        self.executor = executor
        self.ledger = ledger
        self.onRequestAdmitted = onRequestAdmitted
    }

    func dispatch(command: VPNHelperCommand, requestData: Data) async -> Data {
        guard requestData.count <= VPNHelperProtocol.maximumRequestBytes else {
            return failureResponse(
                command: command,
                metadata: nil,
                failure: failure(
                    code: .payloadTooLarge,
                    summary: "The encoded privileged-helper request exceeds the protocol limit"
                )
            )
        }

        let metadata: RequestMetadata
        do {
            metadata = try JSONDecoder().decode(RequestMetadata.self, from: requestData)
        } catch {
            return failureResponse(
                command: command,
                metadata: nil,
                failure: failure(
                    code: .malformedPayload,
                    summary: "The privileged-helper request metadata could not be decoded"
                )
            )
        }

        do {
            try Self.validateRequestShape(command: command, requestData: requestData)
        } catch let protocolFailure as VPNHelperProtocolFailure {
            return failureResponse(command: command, metadata: metadata, failure: protocolFailure)
        } catch {
            return failureResponse(
                command: command,
                metadata: metadata,
                failure: failure(
                    code: .malformedPayload,
                    summary: "The privileged-helper request shape is invalid"
                )
            )
        }

        let fingerprint = HelperRequestFingerprint(command: command, payload: requestData)
        switch ledger.lookup(requestID: metadata.requestID, fingerprint: fingerprint) {
        case let .completed(responseData):
            return responseData
        case .inProgress:
            return failureResponse(
                command: command,
                metadata: metadata,
                failure: failure(
                    code: .inProgress,
                    summary: "The privileged-helper request is already in progress",
                    retryDisposition: .reconnectAndQueryStatus
                )
            )
        case .conflict:
            return failureResponse(
                command: command,
                metadata: metadata,
                failure: failure(
                    code: .requestConflict,
                    summary: "The privileged-helper request identifier was reused with different contents"
                )
            )
        case .unknown:
            break
        }

        do {
            switch command {
            case .status:
                let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(requestData)
                let projectedSessionID = queuedSessionID ?? observedSessionID
                let projectedPhase = queuedPhase ?? (observedFailureSummary == nil ? nil : .failed)
                let projectedFailureSummary = observedFailureSummary
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    responseSessionID: projectedSessionID,
                    usesObservedSessionID: false,
                    successfulSessionID: nil,
                    fingerprint: fingerprint,
                    waitsForPrecedingExecution: false
                ) { [executor] in
                    if let projectedPhase {
                        return StatusResponse(
                            helperVersion: PrivilegedHelperConstants.version,
                            phase: projectedPhase,
                            summary: projectedFailureSummary,
                            details: nil
                        )
                    }
                    return try executor.status(request: request.payload)
                }
            case .startSession:
                let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(requestData)
                guard let sessionID = request.sessionID else {
                    throw failure(code: .malformedPayload, summary: "The start request requires a session identifier")
                }
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    responseSessionID: sessionID,
                    usesObservedSessionID: false,
                    successfulSessionID: sessionID,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.start(request: request.payload, sessionID: sessionID)
                }
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(requestData)
                guard let sessionID = request.sessionID else {
                    throw failure(code: .malformedPayload, summary: "The stop request requires a session identifier")
                }
                if let expectedSessionID = queuedSessionID ?? observedSessionID,
                   expectedSessionID != sessionID {
                    throw failure(
                        code: .requestConflict,
                        summary: "The stop request does not match the observed privileged-helper session"
                    )
                }
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    responseSessionID: sessionID,
                    usesObservedSessionID: false,
                    successfulSessionID: sessionID,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.stop(request: request.payload, sessionID: sessionID)
                }
            case .readDiagnostics:
                let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(requestData)
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    responseSessionID: nil,
                    usesObservedSessionID: false,
                    successfulSessionID: nil,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.readDiagnostics(request: request.payload)
                }
            }
        } catch let protocolFailure as VPNHelperProtocolFailure {
            return failureResponse(command: command, metadata: metadata, failure: protocolFailure)
        } catch {
            return failureResponse(
                command: command,
                metadata: metadata,
                failure: failure(
                    code: .malformedPayload,
                    summary: "The privileged-helper request could not be decoded"
                )
            )
        }
    }

    private func execute<Response>(
        command: VPNHelperCommand,
        requestID: UUID,
        responseSessionID: UUID?,
        usesObservedSessionID: Bool,
        successfulSessionID: UUID?,
        fingerprint: HelperRequestFingerprint,
        waitsForPrecedingExecution: Bool = true,
        operation: @escaping @Sendable () throws -> Response
    ) async throws -> Data where Response: Codable & Sendable & Equatable {
        do {
            try ledger.begin(requestID: requestID, fingerprint: fingerprint)
        } catch HelperRequestLedgerError.capacityExceeded {
            return failureResponse(
                command: command,
                metadata: RequestMetadata(
                    revision: VPNHelperProtocol.revision,
                    requestID: requestID,
                    sessionID: responseSessionID
                ),
                failure: failure(
                    code: .inProgress,
                    summary: "The privileged-helper request ledger is at capacity",
                    retryDisposition: .reconnectAndQueryStatus
                )
            )
        }

        var reservedCorrelationGeneration: UInt64?
        if let successfulSessionID {
            correlationGeneration &+= 1
            reservedCorrelationGeneration = correlationGeneration
            queuedSessionID = successfulSessionID
            queuedPhase = command == .startSession ? .starting : .stopping
            observedFailureSummary = nil
        }
        let effectiveResponseSessionID = usesObservedSessionID
            ? (queuedSessionID ?? observedSessionID)
            : responseSessionID
        onRequestAdmitted(command)

        let precedingExecution = waitsForPrecedingExecution ? executionTail : nil
        let execution = Task.detached { () -> (data: Data, succeeded: Bool, failureSummary: String?) in
            await precedingExecution?.value
            do {
                let payload = try operation()
                let response = VPNHelperResponseEnvelope(
                    revision: VPNHelperProtocol.revision,
                    requestID: requestID,
                    sessionID: effectiveResponseSessionID,
                    payload: payload,
                    failure: nil
                )
                return (try VPNHelperCodec.encodeResponse(response), true, nil)
            } catch let protocolFailure as VPNHelperProtocolFailure {
                return (
                    Self.encodeFailure(
                        requestID: requestID,
                        sessionID: effectiveResponseSessionID,
                        payloadType: Response.self,
                        failure: protocolFailure
                    ),
                    false,
                    protocolFailure.summary
                )
            } catch let presentableError as any VPNHelperClientPresentableError {
                let summary = presentableError.clientSummary
                return (
                    Self.encodeFailure(
                        requestID: requestID,
                        sessionID: effectiveResponseSessionID,
                        payloadType: Response.self,
                        failure: Self.failure(code: .commandFailed, summary: summary)
                    ),
                    false,
                    summary
                )
            } catch {
                let summary = "The privileged helper command failed"
                return (
                    Self.encodeFailure(
                        requestID: requestID,
                        sessionID: effectiveResponseSessionID,
                        payloadType: Response.self,
                        failure: Self.failure(code: .commandFailed, summary: summary)
                    ),
                    false,
                    summary
                )
            }
        }
        if waitsForPrecedingExecution {
            executionTail = Task {
                _ = await execution.value
            }
        }

        let result = await execution.value
        if let successfulSessionID {
            // A failed mutation may already have changed root-side process or route
            // state. Correlate it with the admitted session so a matching stop can
            // still clean up instead of being rejected against an older session.
            // A successful stop, however, completes and clears that correlation.
            observedSessionID = result.succeeded && command == .stopSession
                ? nil
                : successfulSessionID
            observedFailureSummary = result.failureSummary
        }
        if reservedCorrelationGeneration == correlationGeneration {
            queuedSessionID = nil
            queuedPhase = nil
        }
        ledger.complete(
            requestID: requestID,
            fingerprint: fingerprint,
            responseData: result.data
        )
        return result.data
    }

    private func failureResponse(
        command: VPNHelperCommand,
        metadata: RequestMetadata?,
        failure: VPNHelperProtocolFailure
    ) -> Data {
        let requestID = metadata?.requestID ?? UUID()
        let sessionID = metadata?.sessionID
        switch command {
        case .status:
            return Self.encodeFailure(requestID: requestID, sessionID: sessionID, payloadType: StatusResponse.self, failure: failure)
        case .startSession:
            return Self.encodeFailure(requestID: requestID, sessionID: sessionID, payloadType: StartSessionResponse.self, failure: failure)
        case .stopSession:
            return Self.encodeFailure(requestID: requestID, sessionID: sessionID, payloadType: StopSessionResponse.self, failure: failure)
        case .readDiagnostics:
            return Self.encodeFailure(requestID: requestID, sessionID: sessionID, payloadType: DiagnosticsResponse.self, failure: failure)
        }
    }

    private nonisolated static func encodeFailure<Response>(
        requestID: UUID,
        sessionID: UUID?,
        payloadType: Response.Type,
        failure: VPNHelperProtocolFailure
    ) -> Data where Response: Codable & Sendable & Equatable {
        let response = VPNHelperResponseEnvelope<Response>(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: nil,
            failure: failure
        )
        if let data = try? VPNHelperCodec.encodeResponse(response) {
            return data
        }

        let fallback = VPNHelperResponseEnvelope<Response>(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: nil,
            failure: Self.failure(code: .commandFailed, summary: "The privileged helper could not encode its response")
        )
        return (try? JSONEncoder().encode(fallback)) ?? Data()
    }

    private nonisolated static func validateRequestShape(
        command: VPNHelperCommand,
        requestData: Data
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            throw failure(
                code: .malformedPayload,
                summary: "The privileged-helper request shape is invalid"
            )
        }

        let topLevelKeys = Set(object.keys)
        let requiredTopLevelKeys: Set<String> = ["revision", "requestID", "payload"]
        let allowedTopLevelKeys = requiredTopLevelKeys.union(["sessionID"])
        guard requiredTopLevelKeys.isSubset(of: topLevelKeys),
              topLevelKeys.isSubset(of: allowedTopLevelKeys) else {
            throw failure(
                code: .malformedPayload,
                summary: "The privileged-helper request contains unexpected envelope fields"
            )
        }

        let allowedPayloadKeys: Set<String>
        switch command {
        case .status:
            allowedPayloadKeys = []
        case .startSession:
            allowedPayloadKeys = [
                "stateDirectoryPath",
                "assetDirectoryPath",
                "configData",
                "protectedHosts",
                "tunnelInterfaceName",
                "outboundInterface",
                "dumpsSystemState"
            ]
        case .stopSession:
            allowedPayloadKeys = ["stateDirectoryPath", "protectedHosts", "outboundInterface"]
        case .readDiagnostics:
            allowedPayloadKeys = ["log", "maximumBytes"]
        }

        guard Set(payload.keys).isSubset(of: allowedPayloadKeys) else {
            throw failure(
                code: .malformedPayload,
                summary: "The privileged-helper request payload does not match the selected command"
            )
        }
    }

    private nonisolated static func failure(
        code: VPNHelperFailureCode,
        summary: String,
        retryDisposition: VPNHelperRetryDisposition = .never
    ) -> VPNHelperProtocolFailure {
        VPNHelperProtocolFailure(
            code: code,
            summary: summary,
            details: nil,
            retryDisposition: retryDisposition
        )
    }

    private func failure(
        code: VPNHelperFailureCode,
        summary: String,
        retryDisposition: VPNHelperRetryDisposition = .never
    ) -> VPNHelperProtocolFailure {
        Self.failure(code: code, summary: summary, retryDisposition: retryDisposition)
    }
}
