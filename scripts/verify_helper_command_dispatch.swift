import Foundation

private struct PresentableFailure: VPNHelperClientPresentableError {
    let clientSummary: String
}

private struct PresentableFailingExecutor: HelperCommandExecuting, Sendable {
    let summary: String

    func status(request: StatusRequest) throws -> StatusResponse { throw PresentableFailure(clientSummary: summary) }
    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse { throw PresentableFailure(clientSummary: summary) }
    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse { throw PresentableFailure(clientSummary: summary) }
    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse { throw PresentableFailure(clientSummary: summary) }
    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse { throw PresentableFailure(clientSummary: summary) }
    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse { throw PresentableFailure(clientSummary: summary) }
}

private struct SecretFailure: LocalizedError, Sendable {
    let secret: String
    var errorDescription: String? { "Shell failed with root output: \(secret)" }
}

private struct SecretFailingExecutor: HelperCommandExecuting, Sendable {
    let secret: String

    func status(request: StatusRequest) throws -> StatusResponse {
        throw SecretFailure(secret: secret)
    }

    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse {
        throw SecretFailure(secret: secret)
    }

    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse {
        throw SecretFailure(secret: secret)
    }

    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse {
        throw SecretFailure(secret: secret)
    }

    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse {
        throw SecretFailure(secret: secret)
    }

    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse {
        throw SecretFailure(secret: secret)
    }
}

private enum DispatchTestError: Error {
    case failedStart
}

private final class RecordingExecutor: HelperCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [VPNHelperCommand] = []
    private var statusPhase: VPNHelperSessionPhase = .idle
    private var startCount = 0
    private let blockStart: Bool
    private let blockStop: Bool
    private let failedStartNumber: Int?
    let startEntered = DispatchSemaphore(value: 0)
    let releaseStart = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    let releaseStop = DispatchSemaphore(value: 0)

    init(blockStart: Bool = false, blockStop: Bool = false, failedStartNumber: Int? = nil) {
        self.blockStart = blockStart
        self.blockStop = blockStop
        self.failedStartNumber = failedStartNumber
    }

    var commands: [VPNHelperCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func status(request: StatusRequest) throws -> StatusResponse {
        lock.lock()
        recordedCommands.append(.status)
        let phase = statusPhase
        lock.unlock()
        return StatusResponse(helperVersion: "8", phase: phase, summary: nil, details: nil)
    }

    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse {
        lock.lock()
        recordedCommands.append(.startSession)
        startCount += 1
        let shouldFail = startCount == failedStartNumber
        if !shouldFail { statusPhase = .running }
        lock.unlock()
        if blockStart {
            startEntered.signal()
            precondition(releaseStart.wait(timeout: .now() + 5) == .success)
        }
        if shouldFail { throw DispatchTestError.failedStart }
        return StartSessionResponse(phase: .running, summary: nil, details: nil)
    }

    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse {
        lock.lock()
        recordedCommands.append(.stopSession)
        statusPhase = .idle
        lock.unlock()
        if blockStop {
            stopEntered.signal()
            precondition(releaseStop.wait(timeout: .now() + 5) == .success)
        }
        return StopSessionResponse(phase: .idle, summary: nil, details: nil)
    }

    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse {
        record(.readDiagnostics)
        return DiagnosticsResponse(log: request.log, text: "log", metadata: "metadata", wasTruncated: false)
    }

    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse {
        record(.engageLeakGuard)
        return LeakGuardResponse(isEngaged: true)
    }

    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse {
        record(.releaseLeakGuard)
        return LeakGuardResponse(isEngaged: false)
    }

    private func record(_ command: VPNHelperCommand) {
        lock.lock()
        recordedCommands.append(command)
        lock.unlock()
    }
}

@main
private enum VerifyHelperCommandDispatch {
    static func main() async throws {
        try await verifyMatchingCommandsDispatchOnlyTheirExecutorMethod()
        try await verifyMalformedOversizedAndMismatchedRequestsNeverExecute()
        try await verifyEveryMismatchedPayloadIsRejected()
        try await verifyRevisionMismatchIsStructured()
        try await verifySameDaemonStatusCorrelation()
        try await verifyStatusAdmittedDuringStartUsesQueuedSessionCorrelation()
        try await verifyStatusAdmittedDuringStopUsesQueuedSessionCorrelation()
        try await verifyMismatchedStopDoesNotExecute()
        try await verifyFailedStartAdvancesStopCorrelation()
        try await verifyPresentableCommandFailurePreservesSafeSummary()
        try await verifyCommandFailureDoesNotExposeSecrets()
        try await verifyCompletedDuplicateReturnsExactBytesOnce()
        try await verifyInProgressDuplicateIsDeterministic()
        try await verifyChangedDuplicateConflicts()
        print("verify_helper_command_dispatch: all checks passed")
    }

    private static func verifyMatchingCommandsDispatchOnlyTheirExecutorMethod() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()

        let statusData = try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        ))
        let statusResponse = await dispatcher.dispatch(command: .status, requestData: statusData)
        let decodedStatus: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(statusResponse)
        precondition(decodedStatus.payload?.phase == .idle)

        let startData = try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        let startResponse = await dispatcher.dispatch(command: .startSession, requestData: startData)
        let decodedStart: VPNHelperResponseEnvelope<StartSessionResponse> = try VPNHelperCodec.decodeResponse(startResponse)
        precondition(decodedStart.payload?.phase == .running)

        let stopData = try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: sessionID,
            payload: StopSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                protectedHosts: ["example.com"],
                outboundInterface: "en0"
            )
        ))
        let stopResponse = await dispatcher.dispatch(command: .stopSession, requestData: stopData)
        let decodedStop: VPNHelperResponseEnvelope<StopSessionResponse> = try VPNHelperCodec.decodeResponse(stopResponse)
        precondition(decodedStop.payload?.phase == .idle)

        let diagnosticsData = try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: ReadDiagnosticsRequest(log: .control, maximumBytes: 1_024)
        ))
        let diagnosticsResponse = await dispatcher.dispatch(command: .readDiagnostics, requestData: diagnosticsData)
        let decodedDiagnostics: VPNHelperResponseEnvelope<DiagnosticsResponse> = try VPNHelperCodec.decodeResponse(diagnosticsResponse)
        precondition(decodedDiagnostics.payload?.log == .control)

        precondition(executor.commands == [.status, .startSession, .stopSession, .readDiagnostics])
    }

    private static func verifyMalformedOversizedAndMismatchedRequestsNeverExecute() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)

        let malformed = await dispatcher.dispatch(command: .status, requestData: Data("{".utf8))
        try assertFailure(malformed, as: StatusResponse.self, code: .malformedPayload)

        let oversized = await dispatcher.dispatch(
            command: .status,
            requestData: Data(repeating: 0, count: VPNHelperProtocol.maximumRequestBytes + 1)
        )
        try assertFailure(oversized, as: StatusResponse.self, code: .payloadTooLarge)

        let statusData = try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        ))
        let mismatched = await dispatcher.dispatch(command: .startSession, requestData: statusData)
        try assertFailure(mismatched, as: StartSessionResponse.self, code: .malformedPayload)

        precondition(executor.commands.isEmpty)
    }

    private static func verifyEveryMismatchedPayloadIsRejected() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()
        let requests: [(VPNHelperCommand, Data)] = [
            (.status, try makeStatusData(requestID: UUID())),
            (.startSession, try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])),
            (.stopSession, try makeStopData(requestID: UUID(), sessionID: sessionID)),
            (.readDiagnostics, try makeDiagnosticsData(requestID: UUID()))
        ]

        for (payloadCommand, requestData) in requests {
            for dispatchedCommand in [VPNHelperCommand.status, .startSession, .stopSession, .readDiagnostics]
            where dispatchedCommand != payloadCommand {
                let response = await dispatcher.dispatch(command: dispatchedCommand, requestData: requestData)
                try assertMalformedFailure(response, command: dispatchedCommand)
            }
        }
        precondition(executor.commands.isEmpty)
    }

    private static func verifyRevisionMismatchIsStructured() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let request = VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision - 1,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        )
        let rawData = try JSONEncoder().encode(request)
        let response = await dispatcher.dispatch(command: .status, requestData: rawData)
        try assertFailure(response, as: StatusResponse.self, code: .incompatibleService)
        precondition(executor.commands.isEmpty)
    }

    private static func verifySameDaemonStatusCorrelation() async throws {
        let freshDispatcher = HelperCommandDispatcher(executor: RecordingExecutor())
        let freshStatus: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(
            await freshDispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        precondition(freshStatus.sessionID == nil)
        precondition(freshStatus.payload?.phase == .idle)

        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()
        _ = await dispatcher.dispatch(
            command: .startSession,
            requestData: try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        )
        let running: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        precondition(running.sessionID == sessionID)
        precondition(running.payload?.phase == .running)

        _ = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: sessionID)
        )
        let idle: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        precondition(idle.sessionID == nil)
        precondition(idle.payload?.phase == .idle)
    }

    private static func verifyStatusAdmittedDuringStartUsesQueuedSessionCorrelation() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let statusAdmitted = DispatchSemaphore(value: 0)
        let dispatcher = HelperCommandDispatcher(executor: executor) { command in
            if command == .status { statusAdmitted.signal() }
        }
        let sessionID = UUID()
        let startData = try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        let statusData = try makeStatusData(requestID: UUID())

        async let startResponseData = dispatcher.dispatch(command: .startSession, requestData: startData)
        precondition(executor.startEntered.wait(timeout: .now() + 5) == .success)
        async let statusResponseData = dispatcher.dispatch(command: .status, requestData: statusData)
        precondition(statusAdmitted.wait(timeout: .now() + 5) == .success)
        executor.releaseStart.signal()

        let startResponse: VPNHelperResponseEnvelope<StartSessionResponse> = try await VPNHelperCodec.decodeResponse(startResponseData)
        let statusResponse: VPNHelperResponseEnvelope<StatusResponse> = try await VPNHelperCodec.decodeResponse(statusResponseData)
        precondition(startResponse.payload?.phase == .running)
        precondition(statusResponse.payload?.phase == .starting)
        precondition(statusResponse.sessionID == sessionID)
        precondition(executor.commands == [.startSession])
    }

    private static func verifyStatusAdmittedDuringStopUsesQueuedSessionCorrelation() async throws {
        let executor = RecordingExecutor(blockStop: true)
        let statusAdmitted = DispatchSemaphore(value: 0)
        let dispatcher = HelperCommandDispatcher(executor: executor) { command in
            if command == .status { statusAdmitted.signal() }
        }
        let sessionID = UUID()
        let stopData = try makeStopData(requestID: UUID(), sessionID: sessionID)
        let statusData = try makeStatusData(requestID: UUID())

        async let stopResponseData = dispatcher.dispatch(command: .stopSession, requestData: stopData)
        precondition(executor.stopEntered.wait(timeout: .now() + 5) == .success)
        async let statusResponseData = dispatcher.dispatch(command: .status, requestData: statusData)
        precondition(statusAdmitted.wait(timeout: .now() + 5) == .success)
        executor.releaseStop.signal()

        let stopResponse: VPNHelperResponseEnvelope<StopSessionResponse> = try await VPNHelperCodec.decodeResponse(stopResponseData)
        let statusResponse: VPNHelperResponseEnvelope<StatusResponse> = try await VPNHelperCodec.decodeResponse(statusResponseData)
        precondition(stopResponse.payload?.phase == .idle)
        precondition(statusResponse.payload?.phase == .stopping)
        precondition(statusResponse.sessionID == sessionID)
        precondition(executor.commands == [.stopSession])
    }

    private static func verifyMismatchedStopDoesNotExecute() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let activeSessionID = UUID()
        _ = await dispatcher.dispatch(
            command: .startSession,
            requestData: try makeStartData(
                requestID: UUID(),
                sessionID: activeSessionID,
                protectedHosts: ["example.com"]
            )
        )

        let response = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: UUID())
        )

        try assertFailure(response, as: StopSessionResponse.self, code: .requestConflict)
        precondition(executor.commands == [.startSession])
        let status: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        precondition(status.sessionID == activeSessionID)
        precondition(status.payload?.phase == .running)
    }

    private static func verifyFailedStartAdvancesStopCorrelation() async throws {
        let executor = RecordingExecutor(failedStartNumber: 2)
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let previousSessionID = UUID()
        let failedSessionID = UUID()

        _ = await dispatcher.dispatch(
            command: .startSession,
            requestData: try makeStartData(requestID: UUID(), sessionID: previousSessionID, protectedHosts: ["example.com"])
        )
        _ = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: previousSessionID)
        )

        let failedStart = await dispatcher.dispatch(
            command: .startSession,
            requestData: try makeStartData(requestID: UUID(), sessionID: failedSessionID, protectedHosts: ["example.com"])
        )
        try assertFailure(failedStart, as: StartSessionResponse.self, code: .commandFailed)

        let status: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        precondition(status.sessionID == failedSessionID)
        precondition(status.payload?.phase == .failed)

        let stop = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: failedSessionID)
        )
        let stopResponse: VPNHelperResponseEnvelope<StopSessionResponse> = try VPNHelperCodec.decodeResponse(stop)
        precondition(stopResponse.payload?.phase == .idle)
        precondition(executor.commands == [.startSession, .stopSession, .startSession, .stopSession])
    }

    private static func verifyPresentableCommandFailurePreservesSafeSummary() async throws {
        let summary = "Installed Xray runtime is missing"
        let dispatcher = HelperCommandDispatcher(executor: PresentableFailingExecutor(summary: summary))
        let responseData = await dispatcher.dispatch(
            command: .status,
            requestData: try makeStatusData(requestID: UUID())
        )
        let response: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(responseData)
        precondition(response.failure?.code == .commandFailed)
        precondition(response.failure?.summary == summary)
        precondition(response.failure?.details == nil)
    }

    private static func verifyCommandFailureDoesNotExposeSecrets() async throws {
        let secret = "SENTINEL_ROOT_LOG_SECRET"
        let dispatcher = HelperCommandDispatcher(executor: SecretFailingExecutor(secret: secret))
        let responseData = await dispatcher.dispatch(
            command: .status,
            requestData: try makeStatusData(requestID: UUID())
        )
        let response: VPNHelperResponseEnvelope<StatusResponse> = try VPNHelperCodec.decodeResponse(responseData)
        precondition(response.failure?.code == .commandFailed)
        precondition(response.failure?.summary == "The privileged helper command failed")
        precondition(response.failure?.details == nil)
        precondition(!String(decoding: responseData, as: UTF8.self).contains(secret))

    }

    private static func verifyCompletedDuplicateReturnsExactBytesOnce() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHosts: ["example.com"])

        let first = await dispatcher.dispatch(command: .startSession, requestData: data)
        let second = await dispatcher.dispatch(command: .startSession, requestData: data)

        precondition(first == second)
        precondition(executor.commands == [.startSession])
    }

    private static func verifyInProgressDuplicateIsDeterministic() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHosts: ["example.com"])

        async let firstResponse = dispatcher.dispatch(command: .startSession, requestData: data)
        precondition(executor.startEntered.wait(timeout: .now() + 5) == .success)
        let duplicate = await dispatcher.dispatch(command: .startSession, requestData: data)
        try assertFailure(duplicate, as: StartSessionResponse.self, code: .inProgress)
        executor.releaseStart.signal()
        let completed = await firstResponse
        let decoded: VPNHelperResponseEnvelope<StartSessionResponse> = try VPNHelperCodec.decodeResponse(completed)
        precondition(decoded.payload?.phase == .running)
        precondition(executor.commands == [.startSession])
    }

    private static func verifyChangedDuplicateConflicts() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let requestID = UUID()
        let sessionID = UUID()
        let first = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHosts: ["example.com"])
        let changed = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHosts: ["other.example.com"])

        _ = await dispatcher.dispatch(command: .startSession, requestData: first)
        let response = await dispatcher.dispatch(command: .startSession, requestData: changed)

        try assertFailure(response, as: StartSessionResponse.self, code: .requestConflict)
        precondition(executor.commands == [.startSession])
    }

    private static func makeStatusData(requestID: UUID) throws -> Data {
        try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: nil,
            payload: StatusRequest()
        ))
    }

    private static func makeStartData(requestID: UUID, sessionID: UUID, protectedHosts: [String]) throws -> Data {
        try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                assetDirectoryPath: "/Users/test/Library/Application Support/teleport/geodata-resolved",
                configData: Data("{}".utf8),
                protectedHosts: protectedHosts,
                tunnelInterfaceName: "utun9",
                outboundInterface: "en0"
            )
        ))
    }

    private static func makeStopData(requestID: UUID, sessionID: UUID) throws -> Data {
        try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StopSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                protectedHosts: ["example.com"],
                outboundInterface: "en0"
            )
        ))
    }

    private static func makeDiagnosticsData(requestID: UUID) throws -> Data {
        try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: nil,
            payload: ReadDiagnosticsRequest(log: .control, maximumBytes: 1_024)
        ))
    }

    private static func assertMalformedFailure(_ data: Data, command: VPNHelperCommand) throws {
        switch command {
        case .status:
            try assertFailure(data, as: StatusResponse.self, code: .malformedPayload)
        case .startSession:
            try assertFailure(data, as: StartSessionResponse.self, code: .malformedPayload)
        case .stopSession:
            try assertFailure(data, as: StopSessionResponse.self, code: .malformedPayload)
        case .readDiagnostics:
            try assertFailure(data, as: DiagnosticsResponse.self, code: .malformedPayload)
        case .engageLeakGuard, .releaseLeakGuard:
            try assertFailure(data, as: LeakGuardResponse.self, code: .malformedPayload)
        }
    }

    private static func assertFailure<Payload>(
        _ data: Data,
        as payloadType: Payload.Type,
        code: VPNHelperFailureCode
    ) throws where Payload: Codable & Sendable & Equatable {
        let response: VPNHelperResponseEnvelope<Payload> = try VPNHelperCodec.decodeResponse(data)
        precondition(response.payload == nil)
        precondition(response.failure?.code == code, "Expected \(code), got \(String(describing: response.failure?.code))")
    }
}
