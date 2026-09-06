import Foundation

/// User-side typed facade for the privileged helper. XPC connection ownership and
/// reply races remain contained in the injected transport.
nonisolated struct PrivilegedHelperClient: Sendable {
    static let expectedVersion = PrivilegedHelperConstants.version
    static let label = PrivilegedHelperConstants.label
    static let installedToolPath = PrivilegedHelperConstants.installedToolPath
    static let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
    static let launchDaemonPlistPath = PrivilegedHelperConstants.launchDaemonPlistPath

    private enum ResponseSessionRule {
        case absent
        case exact(UUID)
        case observed
    }

    private let transport: any VPNHelperTransport

    init(transport: any VPNHelperTransport = XPCVPNHelperTransport()) {
        self.transport = transport
    }

    func status() async throws -> PrivilegedHelperStatus {
        let requestID = UUID()
        do {
            let response: VPNHelperResponseEnvelope<StatusResponse> = try await exchange(
                command: .status,
                requestID: requestID,
                sessionID: nil,
                payload: StatusRequest(),
                timeout: 3,
                responseSessionRule: .observed
            )
            guard let payload = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper status response has no payload")
            }
            return PrivilegedHelperStatus(
                version: payload.helperVersion,
                phase: payload.phase,
                sessionID: response.sessionID,
                summary: payload.summary,
                details: payload.details
            )
        } catch {
            throw mapClientError(error)
        }
    }

    func start(
        session: XrayTunLaunchSession,
        paths: XrayTunRuntimePaths,
        sessionID: UUID
    ) async throws -> pid_t? {
        let requestID = UUID()
        let payload = StartSessionRequest(
            stateDirectoryPath: paths.stateDirectoryURL.path,
            configData: session.configData,
            protectedHost: session.protectedHost,
            tunnelInterfaceName: session.tunnelInterfaceName,
            outboundInterface: session.outboundInterface
        )

        do {
            let response: VPNHelperResponseEnvelope<StartSessionResponse> = try await exchange(
                command: .startSession,
                requestID: requestID,
                sessionID: sessionID,
                payload: payload,
                timeout: 20,
                responseSessionRule: .exact(sessionID)
            )
            guard let responsePayload = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper start response has no payload")
            }
            guard responsePayload.phase == .running else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper start response is not running")
            }
            return nil
        } catch let error as VPNHelperTransportError where error.requiresMutationReconciliation {
            try await reconcileMutation(
                command: .startSession,
                requestID: requestID,
                sessionID: sessionID,
                successfulPhase: .running
            )
            return nil
        } catch {
            throw mapClientError(error)
        }
    }

    func stop(
        paths: XrayTunRuntimePaths,
        protectedHost: String?,
        outboundInterface: String?,
        sessionID: UUID
    ) async throws {
        let requestID = UUID()
        let payload = StopSessionRequest(
            stateDirectoryPath: paths.stateDirectoryURL.path,
            protectedHost: protectedHost,
            outboundInterface: outboundInterface
        )

        do {
            let response: VPNHelperResponseEnvelope<StopSessionResponse> = try await exchange(
                command: .stopSession,
                requestID: requestID,
                sessionID: sessionID,
                payload: payload,
                timeout: 15,
                responseSessionRule: .exact(sessionID)
            )
            guard let responsePayload = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper stop response has no payload")
            }
            guard responsePayload.phase == .idle else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper stop response is not idle")
            }
        } catch let error as VPNHelperTransportError where error.requiresMutationReconciliation {
            try await reconcileMutation(
                command: .stopSession,
                requestID: requestID,
                sessionID: sessionID,
                successfulPhase: .idle
            )
        } catch {
            throw mapClientError(error)
        }
    }

    func readLog(logName: String, maxBytes: Int) async throws -> PrivilegedHelperDiagnostics {
        let log: VPNHelperLog
        switch logName {
        case "xray", "xray-tun.log":
            log = .xray
        case "control", "xray-tun-control.log":
            log = .control
        default:
            throw PrivilegedHelperClientError.invalidResponse("Unsupported privileged helper log selector")
        }

        let requestID = UUID()
        let maximumBytes = max(1, min(maxBytes, VPNHelperProtocol.maximumDiagnosticsBytes))
        do {
            let response: VPNHelperResponseEnvelope<DiagnosticsResponse> = try await exchange(
                command: .readDiagnostics,
                requestID: requestID,
                sessionID: nil,
                payload: ReadDiagnosticsRequest(log: log, maximumBytes: maximumBytes),
                timeout: 5,
                responseSessionRule: .absent
            )
            guard let payload = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper diagnostics response has no payload")
            }
            guard payload.log == log else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper diagnostics response selected a different log")
            }
            return PrivilegedHelperDiagnostics(payload: payload)
        } catch {
            throw mapClientError(error)
        }
    }

    private func reconcileMutation(
        command: VPNHelperCommand,
        requestID: UUID,
        sessionID: UUID,
        successfulPhase: VPNHelperSessionPhase
    ) async throws {
        transport.invalidate()
        do {
            let status = try await status()
            guard status.sessionID == sessionID else {
                throw PrivilegedHelperClientError.indeterminate(
                    requestID: requestID,
                    sessionID: sessionID,
                    summary: "The privileged helper could not correlate the \(command.rawValue) result"
                )
            }
            if status.phase == successfulPhase {
                return
            }
            if status.phase == .failed {
                throw PrivilegedHelperClientError.commandFailed(
                    status.summary?.isEmpty == false ? status.summary! : "The privileged helper command failed",
                    status.details
                )
            }
            throw PrivilegedHelperClientError.indeterminate(
                requestID: requestID,
                sessionID: sessionID,
                summary: "The privileged helper reported \(status.phase.rawValue) while reconciling \(command.rawValue)"
            )
        } catch let error as PrivilegedHelperClientError {
            switch error {
            case .incompatibleService, .commandFailed, .indeterminate:
                throw error
            default:
                throw PrivilegedHelperClientError.indeterminate(
                    requestID: requestID,
                    sessionID: sessionID,
                    summary: error.errorDescription ?? "The privileged helper result is indeterminate"
                )
            }
        } catch {
            throw PrivilegedHelperClientError.indeterminate(
                requestID: requestID,
                sessionID: sessionID,
                summary: error.localizedDescription
            )
        }
    }

    private func exchange<Request, Response>(
        command: VPNHelperCommand,
        requestID: UUID,
        sessionID: UUID?,
        payload: Request,
        timeout: TimeInterval,
        responseSessionRule: ResponseSessionRule
    ) async throws -> VPNHelperResponseEnvelope<Response>
    where Request: Codable & Sendable & Equatable,
          Response: Codable & Sendable & Equatable {
        let request = VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: payload
        )
        let requestData = try VPNHelperCodec.encodeRequest(request)
        let responseData = try await transport.send(command: command, requestData: requestData, timeout: timeout)

        let response: VPNHelperResponseEnvelope<Response>
        do {
            response = try VPNHelperCodec.decodeResponse(responseData)
        } catch let failure as VPNHelperProtocolFailure {
            throw mapProtocolFailure(failure)
        }
        guard response.requestID == requestID else {
            throw PrivilegedHelperClientError.invalidResponse("The privileged helper response request identifier does not match")
        }
        switch responseSessionRule {
        case .absent:
            guard response.sessionID == nil else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper response contains an unexpected session identifier")
            }
        case let .exact(expected):
            guard response.sessionID == expected else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper response session identifier does not match")
            }
        case .observed:
            break
        }
        if let failure = response.failure {
            throw mapProtocolFailure(failure)
        }
        return response
    }

    private func mapProtocolFailure(_ failure: VPNHelperProtocolFailure) -> PrivilegedHelperClientError {
        switch failure.code {
        case .incompatibleService:
            return .incompatibleService(failure.summary, failure.details)
        case .commandFailed:
            return .commandFailed(failure.summary, failure.details)
        case .inProgress:
            return .inProgress(failure.summary, failure.details)
        case .unavailable:
            return .unavailable(failure.summary)
        default:
            return .invalidResponse(failure.details ?? failure.summary)
        }
    }

    private func mapClientError(_ error: Error) -> Error {
        if error is PrivilegedHelperClientError {
            return error
        }
        if let transportError = error as? VPNHelperTransportError {
            switch transportError {
            case let .unavailable(message):
                return PrivilegedHelperClientError.unavailable(message)
            case .interrupted:
                return PrivilegedHelperClientError.unavailable("The privileged helper connection was interrupted")
            case .invalidated:
                return PrivilegedHelperClientError.unavailable("The privileged helper connection was invalidated")
            case .deadlineExceeded:
                return PrivilegedHelperClientError.unavailable("The privileged helper request deadline was exceeded")
            case let .invalidResponse(message):
                return PrivilegedHelperClientError.invalidResponse(message)
            }
        }
        if let failure = error as? VPNHelperProtocolFailure {
            return mapProtocolFailure(failure)
        }
        return error
    }
}

nonisolated struct PrivilegedHelperStatus: Sendable, Equatable {
    let version: String?
    let phase: VPNHelperSessionPhase
    let sessionID: UUID?
    let summary: String?
    let details: String?
    var success: Bool { true }
}

nonisolated struct PrivilegedHelperDiagnostics: Sendable, Equatable {
    let payload: DiagnosticsResponse
    var success: Bool { true }
    var summary: String? { payload.metadata }
    var details: String? { payload.text }
    func validate() throws {}
}

nonisolated enum PrivilegedHelperClientError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidResponse(String)
    case incompatibleService(String, String?)
    case commandFailed(String, String?)
    case inProgress(String, String?)
    case indeterminate(requestID: UUID, sessionID: UUID, summary: String)
    case indeterminateStatus(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return "Teleport privileged helper is not running: \(message)"
        case let .invalidResponse(message):
            return message
        case let .incompatibleService(summary, _),
             let .commandFailed(summary, _),
             let .inProgress(summary, _):
            return summary
        case let .indeterminate(_, _, summary),
             let .indeterminateStatus(summary):
            return summary
        }
    }

    var failureReason: String? {
        switch self {
        case let .incompatibleService(_, details),
             let .commandFailed(_, details),
             let .inProgress(_, details):
            return details
        default:
            return nil
        }
    }
}

private extension VPNHelperTransportError {
    var requiresMutationReconciliation: Bool {
        switch self {
        case .interrupted, .invalidated, .deadlineExceeded:
            return true
        case .unavailable, .invalidResponse:
            return false
        }
    }
}
