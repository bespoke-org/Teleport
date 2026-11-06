import Foundation
import XCTest

private struct PresentableFailure: TUNHelperClientPresentableError {
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
    private var recordedCommands: [TUNHelperCommand] = []
    private var statusPhase: TUNHelperSessionPhase = .idle
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

    var commands: [TUNHelperCommand] {
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
            XCTAssert(releaseStart.wait(timeout: .now() + 5) == .success)
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
            XCTAssert(releaseStop.wait(timeout: .now() + 5) == .success)
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

    func readProxyPreferences(request: ReadProxyPreferencesRequest) throws -> ProxyPreferencesSnapshot {
        record(.readProxyPreferences)
        return ProxyPreferencesSnapshot(transactionID: UUID(), inventory: ProxyInventory(locationID: "home", eligibleServiceIDs: [], services: [:]))
    }

    func applyProxyPreferences(request: ApplyProxyPreferencesRequest) throws -> ApplyProxyPreferencesResponse {
        record(.applyProxyPreferences)
        startEntered.signal()
        if blockStart { XCTAssert(releaseStart.wait(timeout: .now() + 5) == .success) }
        return ApplyProxyPreferencesResponse(applied: true)
    }

    private func record(_ command: TUNHelperCommand) {
        lock.lock()
        recordedCommands.append(command)
        lock.unlock()
    }
}

final class HelperCommandDispatchTests: XCTestCase {
    func testProxyRecoveryReadWaitsForPendingWrite() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let readAdmitted = DispatchSemaphore(value: 0)
        let dispatcher = HelperCommandDispatcher(executor: executor) { command in
            if command == .readProxyPreferences { readAdmitted.signal() }
        }
        let write = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision, requestID: UUID(), sessionID: nil,
            payload: ApplyProxyPreferencesRequest(transactionID: UUID(),
                expected: ProxyInventory(locationID: "home", eligibleServiceIDs: [], services: [:]), mutations: [])))
        let read = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision, requestID: UUID(), sessionID: nil,
            payload: ReadProxyPreferencesRequest()))
        async let writeResponse = dispatcher.dispatch(command: .applyProxyPreferences, requestData: write)
        XCTAssert(executor.startEntered.wait(timeout: .now() + 5) == .success)
        async let readResponse = dispatcher.dispatch(command: .readProxyPreferences, requestData: read)
        XCTAssert(readAdmitted.wait(timeout: .now() + 5) == .success)
        XCTAssertEqual(executor.commands, [.applyProxyPreferences])
        executor.releaseStart.signal()
        let written: TUNHelperResponseEnvelope<ApplyProxyPreferencesResponse> = try await TUNHelperCodec.decodeResponse(writeResponse)
        let snapshot: TUNHelperResponseEnvelope<ProxyPreferencesSnapshot> = try await TUNHelperCodec.decodeResponse(readResponse)
        XCTAssertEqual(written.payload?.applied, true)
        XCTAssertNotNil(snapshot.payload)
        XCTAssertEqual(executor.commands, [.applyProxyPreferences, .readProxyPreferences])
        // Ledger replay returns the previous reply without executing again.
        let repeated = await dispatcher.dispatch(command: .applyProxyPreferences, requestData: write)
        XCTAssertEqual(repeated, try TUNHelperCodec.encodeResponse(written))
        XCTAssertEqual(executor.commands, [.applyProxyPreferences, .readProxyPreferences])
    }

    func testMatchingCommandsDispatchOnlyTheirExecutorMethod() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()

        let statusData = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        ))
        let statusResponse = await dispatcher.dispatch(command: .status, requestData: statusData)
        let decodedStatus: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(statusResponse)
        XCTAssert(decodedStatus.payload?.phase == .idle)

        let startData = try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        let startResponse = await dispatcher.dispatch(command: .startSession, requestData: startData)
        let decodedStart: TUNHelperResponseEnvelope<StartSessionResponse> = try TUNHelperCodec.decodeResponse(startResponse)
        XCTAssert(decodedStart.payload?.phase == .running)

        let stopData = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: sessionID,
            payload: StopSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                protectedHosts: ["example.com"],
                outboundInterface: "en0"
            )
        ))
        let stopResponse = await dispatcher.dispatch(command: .stopSession, requestData: stopData)
        let decodedStop: TUNHelperResponseEnvelope<StopSessionResponse> = try TUNHelperCodec.decodeResponse(stopResponse)
        XCTAssert(decodedStop.payload?.phase == .idle)

        let diagnosticsData = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: ReadDiagnosticsRequest(log: .control, maximumBytes: 1_024)
        ))
        let diagnosticsResponse = await dispatcher.dispatch(command: .readDiagnostics, requestData: diagnosticsData)
        let decodedDiagnostics: TUNHelperResponseEnvelope<DiagnosticsResponse> = try TUNHelperCodec.decodeResponse(diagnosticsResponse)
        XCTAssert(decodedDiagnostics.payload?.log == .control)

        XCTAssert(executor.commands == [.status, .startSession, .stopSession, .readDiagnostics])
    }

    func testMalformedOversizedAndMismatchedRequestsNeverExecute() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)

        let malformed = await dispatcher.dispatch(command: .status, requestData: Data("{".utf8))
        try assertFailure(malformed, as: StatusResponse.self, code: .malformedPayload)

        let oversized = await dispatcher.dispatch(
            command: .status,
            requestData: Data(repeating: 0, count: TUNHelperProtocol.maximumRequestBytes + 1)
        )
        try assertFailure(oversized, as: StatusResponse.self, code: .payloadTooLarge)

        let statusData = try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        ))
        let mismatched = await dispatcher.dispatch(command: .startSession, requestData: statusData)
        try assertFailure(mismatched, as: StartSessionResponse.self, code: .malformedPayload)

        XCTAssert(executor.commands.isEmpty)
    }

    func testEveryMismatchedPayloadIsRejected() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()
        let requests: [(TUNHelperCommand, Data)] = [
            (.status, try makeStatusData(requestID: UUID())),
            (.startSession, try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])),
            (.stopSession, try makeStopData(requestID: UUID(), sessionID: sessionID)),
            (.readDiagnostics, try makeDiagnosticsData(requestID: UUID()))
        ]

        for (payloadCommand, requestData) in requests {
            for dispatchedCommand in [TUNHelperCommand.status, .startSession, .stopSession, .readDiagnostics]
            where dispatchedCommand != payloadCommand {
                let response = await dispatcher.dispatch(command: dispatchedCommand, requestData: requestData)
                try assertMalformedFailure(response, command: dispatchedCommand)
            }
        }
        XCTAssert(executor.commands.isEmpty)
    }

    func testRevisionMismatchIsStructured() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let request = TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision - 1,
            requestID: UUID(),
            sessionID: nil,
            payload: StatusRequest()
        )
        let rawData = try JSONEncoder().encode(request)
        let response = await dispatcher.dispatch(command: .status, requestData: rawData)
        try assertFailure(response, as: StatusResponse.self, code: .incompatibleService)
        XCTAssert(executor.commands.isEmpty)
    }

    func testSameDaemonStatusCorrelation() async throws {
        let freshDispatcher = HelperCommandDispatcher(executor: RecordingExecutor())
        let freshStatus: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(
            await freshDispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        XCTAssert(freshStatus.sessionID == nil)
        XCTAssert(freshStatus.payload?.phase == .idle)

        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let sessionID = UUID()
        _ = await dispatcher.dispatch(
            command: .startSession,
            requestData: try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        )
        let running: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        XCTAssert(running.sessionID == sessionID)
        XCTAssert(running.payload?.phase == .running)

        _ = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: sessionID)
        )
        let idle: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        XCTAssert(idle.sessionID == nil)
        XCTAssert(idle.payload?.phase == .idle)
    }

    func testStatusAdmittedDuringStartUsesQueuedSessionCorrelation() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let statusAdmitted = DispatchSemaphore(value: 0)
        let dispatcher = HelperCommandDispatcher(executor: executor) { command in
            if command == .status { statusAdmitted.signal() }
        }
        let sessionID = UUID()
        let startData = try makeStartData(requestID: UUID(), sessionID: sessionID, protectedHosts: ["example.com"])
        let statusData = try makeStatusData(requestID: UUID())

        async let startResponseData = dispatcher.dispatch(command: .startSession, requestData: startData)
        XCTAssert(executor.startEntered.wait(timeout: .now() + 5) == .success)
        async let statusResponseData = dispatcher.dispatch(command: .status, requestData: statusData)
        XCTAssert(statusAdmitted.wait(timeout: .now() + 5) == .success)
        executor.releaseStart.signal()

        let startResponse: TUNHelperResponseEnvelope<StartSessionResponse> = try await TUNHelperCodec.decodeResponse(startResponseData)
        let statusResponse: TUNHelperResponseEnvelope<StatusResponse> = try await TUNHelperCodec.decodeResponse(statusResponseData)
        XCTAssert(startResponse.payload?.phase == .running)
        XCTAssert(statusResponse.payload?.phase == .starting)
        XCTAssert(statusResponse.sessionID == sessionID)
        XCTAssert(executor.commands == [.startSession])
    }

    func testStatusAdmittedDuringStopUsesQueuedSessionCorrelation() async throws {
        let executor = RecordingExecutor(blockStop: true)
        let statusAdmitted = DispatchSemaphore(value: 0)
        let dispatcher = HelperCommandDispatcher(executor: executor) { command in
            if command == .status { statusAdmitted.signal() }
        }
        let sessionID = UUID()
        let stopData = try makeStopData(requestID: UUID(), sessionID: sessionID)
        let statusData = try makeStatusData(requestID: UUID())

        async let stopResponseData = dispatcher.dispatch(command: .stopSession, requestData: stopData)
        XCTAssert(executor.stopEntered.wait(timeout: .now() + 5) == .success)
        async let statusResponseData = dispatcher.dispatch(command: .status, requestData: statusData)
        XCTAssert(statusAdmitted.wait(timeout: .now() + 5) == .success)
        executor.releaseStop.signal()

        let stopResponse: TUNHelperResponseEnvelope<StopSessionResponse> = try await TUNHelperCodec.decodeResponse(stopResponseData)
        let statusResponse: TUNHelperResponseEnvelope<StatusResponse> = try await TUNHelperCodec.decodeResponse(statusResponseData)
        XCTAssert(stopResponse.payload?.phase == .idle)
        XCTAssert(statusResponse.payload?.phase == .stopping)
        XCTAssert(statusResponse.sessionID == sessionID)
        XCTAssert(executor.commands == [.stopSession])
    }

    func testMismatchedStopDoesNotExecute() async throws {
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
        XCTAssert(executor.commands == [.startSession])
        let status: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        XCTAssert(status.sessionID == activeSessionID)
        XCTAssert(status.payload?.phase == .running)
    }

    func testFailedStartAdvancesStopCorrelation() async throws {
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

        let status: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(
            await dispatcher.dispatch(command: .status, requestData: try makeStatusData(requestID: UUID()))
        )
        XCTAssert(status.sessionID == failedSessionID)
        XCTAssert(status.payload?.phase == .failed)

        let stop = await dispatcher.dispatch(
            command: .stopSession,
            requestData: try makeStopData(requestID: UUID(), sessionID: failedSessionID)
        )
        let stopResponse: TUNHelperResponseEnvelope<StopSessionResponse> = try TUNHelperCodec.decodeResponse(stop)
        XCTAssert(stopResponse.payload?.phase == .idle)
        XCTAssert(executor.commands == [.startSession, .stopSession, .startSession, .stopSession])
    }

    func testPresentableCommandFailurePreservesSafeSummary() async throws {
        let summary = "Installed Xray runtime is missing"
        let dispatcher = HelperCommandDispatcher(executor: PresentableFailingExecutor(summary: summary))
        let responseData = await dispatcher.dispatch(
            command: .status,
            requestData: try makeStatusData(requestID: UUID())
        )
        let response: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(responseData)
        XCTAssert(response.failure?.code == .commandFailed)
        XCTAssert(response.failure?.summary == summary)
        XCTAssert(response.failure?.details == nil)
    }

    func testCommandFailureDoesNotExposeSecrets() async throws {
        let secret = "SENTINEL_ROOT_LOG_SECRET"
        let dispatcher = HelperCommandDispatcher(executor: SecretFailingExecutor(secret: secret))
        let responseData = await dispatcher.dispatch(
            command: .status,
            requestData: try makeStatusData(requestID: UUID())
        )
        let response: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(responseData)
        XCTAssert(response.failure?.code == .commandFailed)
        XCTAssert(response.failure?.summary == "The privileged helper command failed")
        XCTAssert(response.failure?.details == nil)
        XCTAssert(!String(decoding: responseData, as: UTF8.self).contains(secret))

    }

    func testCompletedDuplicateReturnsExactBytesOnce() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHosts: ["example.com"])

        let first = await dispatcher.dispatch(command: .startSession, requestData: data)
        let second = await dispatcher.dispatch(command: .startSession, requestData: data)

        XCTAssert(first == second)
        XCTAssert(executor.commands == [.startSession])
    }

    func testInProgressDuplicateIsDeterministic() async throws {
        let executor = RecordingExecutor(blockStart: true)
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let data = try makeStartData(requestID: UUID(), sessionID: UUID(), protectedHosts: ["example.com"])

        async let firstResponse = dispatcher.dispatch(command: .startSession, requestData: data)
        XCTAssert(executor.startEntered.wait(timeout: .now() + 5) == .success)
        let duplicate = await dispatcher.dispatch(command: .startSession, requestData: data)
        try assertFailure(duplicate, as: StartSessionResponse.self, code: .inProgress)
        executor.releaseStart.signal()
        let completed = await firstResponse
        let decoded: TUNHelperResponseEnvelope<StartSessionResponse> = try TUNHelperCodec.decodeResponse(completed)
        XCTAssert(decoded.payload?.phase == .running)
        XCTAssert(executor.commands == [.startSession])
    }

    func testChangedDuplicateConflicts() async throws {
        let executor = RecordingExecutor()
        let dispatcher = HelperCommandDispatcher(executor: executor)
        let requestID = UUID()
        let sessionID = UUID()
        let first = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHosts: ["example.com"])
        let changed = try makeStartData(requestID: requestID, sessionID: sessionID, protectedHosts: ["other.example.com"])

        _ = await dispatcher.dispatch(command: .startSession, requestData: first)
        let response = await dispatcher.dispatch(command: .startSession, requestData: changed)

        try assertFailure(response, as: StartSessionResponse.self, code: .requestConflict)
        XCTAssert(executor.commands == [.startSession])
    }

    private func makeStatusData(requestID: UUID) throws -> Data {
        try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: nil,
            payload: StatusRequest()
        ))
    }

    private func makeStartData(requestID: UUID, sessionID: UUID, protectedHosts: [String]) throws -> Data {
        try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
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

    private func makeStopData(requestID: UUID, sessionID: UUID) throws -> Data {
        try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: StopSessionRequest(
                stateDirectoryPath: "/Users/test/Library/Application Support/teleport",
                protectedHosts: ["example.com"],
                outboundInterface: "en0"
            )
        ))
    }

    private func makeDiagnosticsData(requestID: UUID) throws -> Data {
        try TUNHelperCodec.encodeRequest(TUNHelperRequestEnvelope(
            revision: TUNHelperProtocol.revision,
            requestID: requestID,
            sessionID: nil,
            payload: ReadDiagnosticsRequest(log: .control, maximumBytes: 1_024)
        ))
    }

    private func assertMalformedFailure(_ data: Data, command: TUNHelperCommand) throws {
        switch command {
        case .readProxyPreferences:
            try assertFailure(data, as: ProxyPreferencesSnapshot.self, code: .malformedPayload)
        case .applyProxyPreferences:
            try assertFailure(data, as: ApplyProxyPreferencesResponse.self, code: .malformedPayload)
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

    private func assertFailure<Payload>(
        _ data: Data,
        as payloadType: Payload.Type,
        code: TUNHelperFailureCode
    ) throws where Payload: Codable & Sendable & Equatable {
        let response: TUNHelperResponseEnvelope<Payload> = try TUNHelperCodec.decodeResponse(data)
        XCTAssert(response.payload == nil)
        XCTAssert(response.failure?.code == code, "Expected \(code), got \(String(describing: response.failure?.code))")
    }
}

private extension HelperCommandExecuting {
    func readProxyPreferences(request: ReadProxyPreferencesRequest) throws -> ProxyPreferencesSnapshot {
        throw DispatchTestError.failedStart
    }
    func applyProxyPreferences(request: ApplyProxyPreferencesRequest) throws -> ApplyProxyPreferencesResponse {
        throw DispatchTestError.failedStart
    }
}
