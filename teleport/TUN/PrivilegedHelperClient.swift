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

    private let transport: any TUNHelperTransport

    init(transport: any TUNHelperTransport = XPCTUNHelperTransport()) {
        self.transport = transport
    }

    func readProxyPreferences() async throws -> ProxyPreferencesSnapshot {
        do {
            let response: TUNHelperResponseEnvelope<ProxyPreferencesSnapshot> = try await exchange(
                command: .readProxyPreferences, requestID: UUID(), sessionID: nil,
                payload: ReadProxyPreferencesRequest(), timeout: 15, responseSessionRule: .absent)
            guard let inventory = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The helper returned no proxy inventory")
            }
            return inventory
        } catch { throw mapClientError(error) }
    }

    func applyProxyPreferences(_ request: ApplyProxyPreferencesRequest) async throws {
        do {
            let response: TUNHelperResponseEnvelope<ApplyProxyPreferencesResponse> = try await exchange(
                command: .applyProxyPreferences, requestID: UUID(), sessionID: nil,
                payload: request, timeout: 15, responseSessionRule: .absent)
            guard let payload = response.payload else {
                throw PrivilegedHelperClientError.invalidResponse("The helper returned no proxy update result")
            }
            guard payload.applied else {
                throw ConnectionFailure(summary: "System proxy settings changed outside Teleport",
                                        details: SystemProxyError.preferencesChanged.localizedDescription,
                                        requiresExplicitReconnect: true)
            }
        } catch {
            // Do not replay an uncertain write. The journal remains on disk and
            // recovery starts with a serialized helper read, behind that write.
            throw mapClientError(error)
        }
    }

    func status() async throws -> PrivilegedHelperStatus {
        let requestID = UUID()
        do {
            let response: TUNHelperResponseEnvelope<StatusResponse> = try await exchange(
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
        assetDirectoryURL: URL? = nil,
        sessionID: UUID
    ) async throws -> pid_t? {
        let requestID = UUID()
        let payload = StartSessionRequest(
            stateDirectoryPath: paths.stateDirectoryURL.path,
            assetDirectoryPath: (assetDirectoryURL ?? paths.stateDirectoryURL.appendingPathComponent("geodata-resolved", isDirectory: true)).path,
            configData: session.configData,
            protectedHosts: session.protectedHosts,
            tunnelInterfaceName: session.tunnelInterfaceName,
            outboundInterface: session.outboundInterface,
            dumpsSystemState: SystemStateDump.isEnabled
        )

        do {
            let response: TUNHelperResponseEnvelope<StartSessionResponse> = try await exchange(
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
        } catch let error as TUNHelperTransportError where error.requiresMutationReconciliation {
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
        protectedHosts: [String]?,
        outboundInterface: String?,
        sessionID: UUID
    ) async throws {
        let requestID = UUID()
        let payload = StopSessionRequest(
            stateDirectoryPath: paths.stateDirectoryURL.path,
            protectedHosts: protectedHosts,
            outboundInterface: outboundInterface
        )

        do {
            let response: TUNHelperResponseEnvelope<StopSessionResponse> = try await exchange(
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
        } catch let error as TUNHelperTransportError where error.requiresMutationReconciliation {
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

    /// Engages or renews the leak guard. Idempotent: the caller repeats it on a
    /// timer, and each call resets the lease that would otherwise release it.
    func engageLeakGuard(
        tunnelInterfaceName: String?,
        protectedHosts: [String],
        leaseSeconds: TimeInterval
    ) async throws {
        do {
            let response: TUNHelperResponseEnvelope<LeakGuardResponse> = try await exchange(
                command: .engageLeakGuard,
                requestID: UUID(),
                sessionID: nil,
                payload: EngageLeakGuardRequest(
                    tunnelInterfaceName: tunnelInterfaceName,
                    protectedHosts: protectedHosts,
                    leaseSeconds: min(leaseSeconds, TUNHelperProtocol.maximumLeakGuardLeaseSeconds)
                ),
                timeout: 10,
                responseSessionRule: .absent
            )
            guard response.payload?.isEngaged == true else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper did not engage the leak guard")
            }
        } catch {
            throw mapClientError(error)
        }
    }

    func releaseLeakGuard() async throws {
        do {
            let response: TUNHelperResponseEnvelope<LeakGuardResponse> = try await exchange(
                command: .releaseLeakGuard,
                requestID: UUID(),
                sessionID: nil,
                payload: ReleaseLeakGuardRequest(),
                timeout: 10,
                responseSessionRule: .absent
            )
            guard response.payload?.isEngaged == false else {
                throw PrivilegedHelperClientError.invalidResponse("The privileged helper did not release the leak guard")
            }
        } catch {
            throw mapClientError(error)
        }
    }

    func readLog(logName: String, maxBytes: Int) async throws -> PrivilegedHelperDiagnostics {
        let log: TUNHelperLog
        switch logName {
        case "config", "xray-tun-config.json":
            log = .config
        case "xray", "xray-tun.log":
            log = .xray
        case "control", "xray-tun-control.log":
            log = .control
        case "helper", "helper.log":
            log = .helper
        default:
            throw PrivilegedHelperClientError.invalidResponse("Unsupported privileged helper log selector")
        }

        let requestID = UUID()
        let maximumBytes = max(1, min(maxBytes, TUNHelperProtocol.maximumDiagnosticsBytes))
        do {
            let response: TUNHelperResponseEnvelope<DiagnosticsResponse> = try await exchange(
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
        command: TUNHelperCommand,
        requestID: UUID,
        sessionID: UUID,
        successfulPhase: TUNHelperSessionPhase
    ) async throws {
        transport.invalidate()
        // A clock that stops with the machine: a sleep in the middle of this loop
        // must not count against the helper.
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(60)
        var lastErrorSummary = "The privileged helper result is indeterminate"

        while clock.now < deadline {
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
                if status.phase != .starting && status.phase != .stopping {
                    throw PrivilegedHelperClientError.indeterminate(
                        requestID: requestID,
                        sessionID: sessionID,
                        summary: "The privileged helper reported \(status.phase.rawValue) while reconciling \(command.rawValue)"
                    )
                }
                lastErrorSummary = "The privileged helper is still \(status.phase.rawValue)"
            } catch let error as PrivilegedHelperClientError {
                switch error {
                case .incompatibleService, .commandFailed, .indeterminate:
                    throw error
                default:
                    throw PrivilegedHelperClientError.indeterminate(
                        requestID: requestID,
                        sessionID: sessionID,
                        summary: [error.errorDescription ?? lastErrorSummary, error.failureReason]
                            .compactMap { $0 }.joined(separator: "\n")
                    )
                }
            } catch {
                throw PrivilegedHelperClientError.indeterminate(
                    requestID: requestID,
                    sessionID: sessionID,
                    summary: error.localizedDescription
                )
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        throw PrivilegedHelperClientError.indeterminate(
            requestID: requestID,
            sessionID: sessionID,
            summary: lastErrorSummary
        )
    }

    private func exchange<Request, Response>(
        command: TUNHelperCommand,
        requestID: UUID,
        sessionID: UUID?,
        payload: Request,
        timeout: TimeInterval,
        responseSessionRule: ResponseSessionRule
    ) async throws -> TUNHelperResponseEnvelope<Response>
    where Request: Codable & Sendable & Equatable,
          Response: Codable & Sendable & Equatable {
        let request = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: payload
        )
        let requestData = try TUNHelperCodec.encodeRequest(request)
        let responseData = try await transport.send(command: command, requestData: requestData, timeout: timeout)

        let response: TUNHelperResponseEnvelope<Response>
        do {
            response = try TUNHelperCodec.decodeResponse(responseData)
        } catch let failure as TUNHelperProtocolFailure {
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

    private func mapProtocolFailure(_ failure: TUNHelperProtocolFailure) -> PrivilegedHelperClientError {
        switch failure.code {
        case .incompatibleService:
            return .incompatibleService(failure.summary, failure.details)
        case .commandFailed:
            return .commandFailed(failure.summary, failure.details)
        case .inProgress:
            return .inProgress(failure.summary, failure.details)
        case .unavailable:
            return .unavailable([failure.summary, failure.details].compactMap { $0 }.joined(separator: "\n"))
        case .malformedPayload, .payloadTooLarge, .requestConflict, .interrupted,
             .invalidated, .deadlineExceeded, .indeterminate:
            return .protocolFailure(failure)
        }
    }

    private func mapClientError(_ error: Error) -> Error {
        if error is PrivilegedHelperClientError {
            return error
        }
        if let transportError = error as? TUNHelperTransportError {
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
        if let failure = error as? TUNHelperProtocolFailure {
            return mapProtocolFailure(failure)
        }
        if error is CancellationError { return error }
        return PrivilegedHelperClientError.unavailable(error.localizedDescription)
    }
}

nonisolated struct PrivilegedHelperStatus: Sendable, Equatable {
    let version: String?
    let phase: TUNHelperSessionPhase
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
    case protocolFailure(TUNHelperProtocolFailure)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Teleport could not contact its privileged helper. Try connecting again so Teleport can repair the helper installation."
        case .invalidResponse:
            return "Teleport received an invalid reply from its privileged helper. Try again; if this repeats, update or reinstall Teleport."
        case .incompatibleService:
            return "Teleport and its privileged helper use incompatible versions. Reinstall Teleport, then connect again to update the helper."
        case let .commandFailed(summary, _):
            let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty || summary == "The privileged helper command failed" {
                return "The privileged helper encountered an internal error. Disconnect and connect again; if this repeats, reinstall Teleport."
            }
            let action = #"(?i)\b(try|check|choose|download|reinstall|update|disconnect|reduce|free|close|refresh|edit|correct|restart|restore|replace|approve|sign out)\b"#
            if summary.range(of: action, options: .regularExpression) == nil {
                return summary + (summary.hasSuffix(".") ? " " : ". ") + "Try disconnecting and connecting again."
            }
            return summary
        case .inProgress:
            return "The privileged helper is still processing an earlier request. Wait a moment, then try again."
        case .indeterminate, .indeterminateStatus:
            return "Teleport could not confirm whether the tunnel is running. Try Disconnect to stop the session before connecting again."
        case let .protocolFailure(failure):
            switch failure.code {
            case .payloadTooLarge:
                return "The tunnel configuration is too large for the privileged helper. Reduce the routing rules or additional portals in the Tunnel profile, then try again."
            case .malformedPayload, .requestConflict:
                return "The privileged helper rejected Teleport's tunnel request. Try again; if this repeats, update or reinstall Teleport."
            case .interrupted, .invalidated, .indeterminate:
                return "Communication with the privileged helper was interrupted. The tunnel may still be active. Try Disconnect before connecting again."
            case .deadlineExceeded:
                return "The privileged helper did not reply in time. Try Disconnect to confirm the tunnel has stopped, then connect again."
            case .incompatibleService:
                return PrivilegedHelperClientError.incompatibleService(failure.summary, failure.details).errorDescription
            case .commandFailed:
                return PrivilegedHelperClientError.commandFailed(failure.summary, failure.details).errorDescription
            case .inProgress:
                return PrivilegedHelperClientError.inProgress(failure.summary, failure.details).errorDescription
            case .unavailable:
                return PrivilegedHelperClientError.unavailable(failure.summary).errorDescription
            }
        }
    }

    var failureReason: String? {
        switch self {
        case let .incompatibleService(summary, details), let .commandFailed(summary, details), let .inProgress(summary, details):
            return diagnosticText([summary == errorDescription ? nil : summary, details])
        case let .unavailable(message), let .invalidResponse(message), let .indeterminateStatus(message):
            return diagnosticText([message])
        case let .indeterminate(requestID, sessionID, summary):
            return diagnosticText([summary, "Request: \(requestID)\nSession: \(sessionID)"])
        case let .protocolFailure(failure):
            return diagnosticText(["Helper response: \(failure.code.rawValue)", failure.summary, failure.details])
        }
    }

    private func diagnosticText(_ values: [String?]) -> String? {
        let text = values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

private extension TUNHelperTransportError {
    var requiresMutationReconciliation: Bool {
        switch self {
        case .interrupted, .invalidated, .deadlineExceeded:
            return true
        case .unavailable, .invalidResponse:
            return false
        }
    }
}
