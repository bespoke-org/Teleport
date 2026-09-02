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

    init(
        executor: any HelperCommandExecuting,
        ledger: HelperRequestLedger = HelperRequestLedger(
            maximumEntries: 128,
            maximumAge: 10 * 60
        )
    ) {
        self.executor = executor
        self.ledger = ledger
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
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    sessionID: request.sessionID,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.status(request: request.payload)
                }
            case .startSession:
                let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(requestData)
                guard let sessionID = request.sessionID else {
                    throw failure(code: .malformedPayload, summary: "The start request requires a session identifier")
                }
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    sessionID: sessionID,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.start(request: request.payload, sessionID: sessionID)
                }
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(requestData)
                guard let sessionID = request.sessionID else {
                    throw failure(code: .malformedPayload, summary: "The stop request requires a session identifier")
                }
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    sessionID: sessionID,
                    fingerprint: fingerprint
                ) { [executor] in
                    try executor.stop(request: request.payload, sessionID: sessionID)
                }
            case .readDiagnostics:
                let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(requestData)
                return try await execute(
                    command: command,
                    requestID: request.requestID,
                    sessionID: request.sessionID,
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
        sessionID: UUID?,
        fingerprint: HelperRequestFingerprint,
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
                    sessionID: sessionID
                ),
                failure: failure(
                    code: .inProgress,
                    summary: "The privileged-helper request ledger is at capacity",
                    retryDisposition: .reconnectAndQueryStatus
                )
            )
        }

        let precedingExecution = executionTail
        let execution = Task.detached { () -> Data in
            await precedingExecution?.value
            do {
                let payload = try operation()
                let response = VPNHelperResponseEnvelope(
                    revision: VPNHelperProtocol.revision,
                    requestID: requestID,
                    sessionID: sessionID,
                    payload: payload,
                    failure: nil
                )
                return try VPNHelperCodec.encodeResponse(response)
            } catch let protocolFailure as VPNHelperProtocolFailure {
                return Self.encodeFailure(
                    requestID: requestID,
                    sessionID: sessionID,
                    payloadType: Response.self,
                    failure: protocolFailure
                )
            } catch {
                return Self.encodeFailure(
                    requestID: requestID,
                    sessionID: sessionID,
                    payloadType: Response.self,
                    failure: Self.failure(
                        code: .commandFailed,
                        summary: Self.commandFailureSummary(error)
                    )
                )
            }
        }
        executionTail = Task {
            _ = await execution.value
        }

        let responseData = await execution.value
        ledger.complete(
            requestID: requestID,
            fingerprint: fingerprint,
            responseData: responseData
        )
        return responseData
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

    private nonisolated static func commandFailureSummary(_ error: Error) -> String {
        let source = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let summary = source.isEmpty ? "The privileged helper command failed" : source
        return String(summary.prefix(1_024))
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
