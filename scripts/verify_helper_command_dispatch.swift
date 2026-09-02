import Foundation

private final class RecordingExecutor: HelperCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [VPNHelperCommand] = []
    private let blockStart: Bool
    let startEntered = DispatchSemaphore(value: 0)
    let releaseStart = DispatchSemaphore(value: 0)

    init(blockStart: Bool = false) {
        self.blockStart = blockStart
    }

    var commands: [VPNHelperCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func status(request: StatusRequest) throws -> StatusResponse {
        record(.status)
        return StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
    }

    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse {
        record(.startSession)
        if blockStart {
            startEntered.signal()
            precondition(releaseStart.wait(timeout: .now() + 5) == .success)
        }
        return StartSessionResponse(phase: .running, summary: nil, details: nil)
    }

    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse {
        record(.stopSession)
        return StopSessionResponse(phase: .idle, summary: nil, details: nil)
    }

    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse {
        record(.readDiagnostics)
        return DiagnosticsResponse(log: request.log, text: "log", metadata: "metadata", wasTruncated: false)
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
        try await verifyRevisionMismatchIsStructured()
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

        let startData = try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHost: "example.com")
        let startResponse = await dispatcher.dispatch(command: .startSession, requestData: startData)
        let decodedStart: VPNHelperResponseEnvelope<StartSessionResponse> = try VPNHelperCodec.decodeResponse(startResponse)
        precondition(decodedStart.payload?.phase == .running)

        let stopData = try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: sessionID,
            payload: StopSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                protectedHost: "example.com",
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

    private static func verifyCompletedDuplicateReturnsExactBytesOnce() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHost: "example.com")

        let first = await dispatcher.dispatch(command: .startSession, requestData: data)
        let second = await dispatcher.dispatch(command: .startSession, requestData: data)

        precondition(first == second)
        precondition(executor.commands == [.startSession])
    }

    private static func verifyInProgressDuplicateIsDeterministic() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHost: "example.com")

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
        let first = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHost: "example.com")
        let changed = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHost: "other.example.com")

        _ = await dispatcher.dispatch(command: .startSession, requestData: first)
        let response = await dispatcher.dispatch(command: .startSession, requestData: changed)

        try assertFailure(response, as: StartSessionResponse.self, code: .requestConflict)
        precondition(executor.commands == [.startSession])
    }

    private static func makeStartData(requestID: UUID, sessionID: UUID, protectedHost: String) throws -> Data {
        try VPNHelperCodec.encodeRequest(VPNHelperRequestEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StartSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                configData: Data("{}".utf8),
                protectedHost: protectedHost,
                tunnelInterfaceName: "utun9",
                outboundInterface: "en0"
            )
        ))
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
