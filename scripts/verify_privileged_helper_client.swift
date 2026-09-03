import Foundation

private final class ScriptedTransport: VPNHelperTransport, @unchecked Sendable {
    typealias Handler = (VPNHelperCommand, Data, TimeInterval, Int) throws -> Data

    private let lock = NSLock()
    private let handler: Handler
    private var recordedCalls: [(VPNHelperCommand, Data, TimeInterval)] = []
    private var invalidationCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var calls: [(VPNHelperCommand, Data, TimeInterval)] {
        lock.withLock { recordedCalls }
    }

    var invalidations: Int {
        lock.withLock { invalidationCount }
    }

    func send(command: VPNHelperCommand, requestData: Data, timeout: TimeInterval) throws -> Data {
        let index = lock.withLock { () -> Int in
            recordedCalls.append((command, requestData, timeout))
            return recordedCalls.count - 1
        }
        return try handler(command, requestData, timeout, index)
    }

    func invalidate() {
        lock.withLock { invalidationCount += 1 }
    }
}

private final class LostStopReplyProxy: NSObject, VPNHelperXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: UUID
    private let losesStopReply: Bool
    private var proxyErrorHandler: (@Sendable (Error) -> Void)?
    private var stopCalls = 0
    private var statusCalls = 0

    init(sessionID: UUID, losesStopReply: Bool) {
        self.sessionID = sessionID
        self.losesStopReply = losesStopReply
    }

    var counts: (stop: Int, status: Int) {
        lock.withLock { (stopCalls, statusCalls) }
    }

    func setProxyErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.withLock { proxyErrorHandler = handler }
    }

    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { statusCalls += 1 }
        do {
            let envelope: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(request)
            reply(try VerifyPrivilegedHelperClient.response(
                requestID: envelope.requestID,
                sessionID: sessionID,
                payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
            ), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "test.unexpected-start", code: 1))
    }

    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { stopCalls += 1 }
        if losesStopReply {
            let handler = lock.withLock { proxyErrorHandler }
            handler?(NSError(
                domain: NSCocoaErrorDomain,
                code: NSXPCConnectionInterrupted,
                userInfo: [NSLocalizedDescriptionKey: "reply channel interrupted"]
            ))
        } else {
            reply(nil, NSError(domain: "test.unexpected-stop", code: 1))
        }
    }

    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "test.unexpected-diagnostics", code: 1))
    }
}

private final class LostStopReplyConnection: VPNHelperXPCConnection, @unchecked Sendable {
    private let proxy: LostStopReplyProxy
    private let lock = NSLock()
    private var invalidationHandler: (@Sendable () -> Void)?

    init(proxy: LostStopReplyProxy) {
        self.proxy = proxy
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {}
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> (any VPNHelperXPCProtocol)? {
        proxy.setProxyErrorHandler(errorHandler)
        return proxy
    }
    func activate() {}
    func invalidate() {
        let handler = lock.withLock { invalidationHandler }
        handler?()
    }
}

private final class LostStopReplyConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [LostStopReplyConnection]

    init(connections: [LostStopReplyConnection]) {
        self.connections = connections
    }

    func make() -> any VPNHelperXPCConnection {
        lock.withLock {
            precondition(!connections.isEmpty, "Unexpected XPC connection creation")
            return connections.removeFirst()
        }
    }
}

@main
private enum VerifyPrivilegedHelperClient {
    static func main() throws {
        try verifyDeadlinesPayloadsAndNormalMapping()
        try verifyResponseIdentityAndRevisionValidation()
        try verifyStructuredCommandFailureMapping()
        try verifyLostStartReconcilesOnce()
        try verifyLostStopReconcilesOnce()
        try verifyFailedReconciliationIsCommandFailure()
        try verifyUnavailableAndUnknownReconciliationAreIndeterminate()
        try verifyDispatcherPublishesMemoryOnlyCorrelation()
        try verifyStartCorrelationPersistenceOrderingAndFailureRetention()
        try verifyLostXPCStopReplyDoesNotReplayMutation()
        try verifyRuntimePersistsSessionCorrelation()
        try verifyClientContainsNoSocketTransport()
        print("verify_privileged_helper_client: all checks passed")
    }

    private static func verifyDeadlinesPayloadsAndNormalMapping() throws {
        let sessionID = UUID()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
                )
            case .readDiagnostics:
                let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.payload.maximumBytes == VPNHelperProtocol.maximumDiagnosticsBytes)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: DiagnosticsResponse(log: request.payload.log, text: "diagnostic", metadata: "meta", wasTruncated: false)
                )
            case .startSession:
                let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: StartSessionResponse(phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            }
        }
        let client = PrivilegedHelperClient(transport: transport)
        let paths = XrayTunRuntimePaths()
        let launch = launchSession()

        let status = try client.status()
        precondition(status.success && status.version == "8" && status.phase == .idle)
        let diagnostics = try client.readLog(logName: "xray-tun.log", maxBytes: Int.max)
        precondition(diagnostics.success && diagnostics.details == "diagnostic")
        let processIdentifier = try client.start(session: launch, paths: paths, sessionID: sessionID)
        precondition(processIdentifier == nil)
        try client.stop(paths: paths, protectedHost: launch.protectedHost, outboundInterface: launch.outboundInterface, sessionID: sessionID)

        precondition(transport.calls.map(\.0) == [.status, .readDiagnostics, .startSession, .stopSession])
        precondition(transport.calls.map(\.2) == [3, 5, 20, 15])
        let requestIDs = try transport.calls.map { command, data, _ -> UUID in
            switch command {
            case .status:
                let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            case .readDiagnostics:
                let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            case .startSession:
                let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            }
        }
        precondition(Set(requestIDs).count == requestIDs.count)
    }

    private static func verifyResponseIdentityAndRevisionValidation() throws {
        let mismatchTransport = ScriptedTransport { _, _, _, _ in
            try response(
                requestID: UUID(),
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
            )
        }
        do {
            _ = try PrivilegedHelperClient(transport: mismatchTransport).status()
            preconditionFailure("Expected request identifier mismatch")
        } catch PrivilegedHelperClientError.invalidResponse {}

        let expectedSessionID = UUID()
        let sessionMismatchTransport = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: UUID(),
                payload: StartSessionResponse(phase: .running, summary: nil, details: nil)
            )
        }
        do {
            _ = try PrivilegedHelperClient(transport: sessionMismatchTransport).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: expectedSessionID
            )
            preconditionFailure("Expected session identifier mismatch")
        } catch PrivilegedHelperClientError.invalidResponse {}

        let staleTransport = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            let stale = VPNHelperResponseEnvelope(
                revision: VPNHelperProtocol.revision - 1,
                requestID: request.requestID,
                sessionID: nil,
                payload: StatusResponse(helperVersion: "7", phase: .idle, summary: nil, details: nil),
                failure: nil
            )
            return try JSONEncoder().encode(stale)
        }
        do {
            _ = try PrivilegedHelperClient(transport: staleTransport).status()
            preconditionFailure("Expected incompatible service")
        } catch PrivilegedHelperClientError.incompatibleService {}
    }

    private static func verifyStructuredCommandFailureMapping() throws {
        let transport = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            return try VPNHelperCodec.encodeResponse(VPNHelperResponseEnvelope<StatusResponse>(
                revision: VPNHelperProtocol.revision,
                requestID: request.requestID,
                sessionID: nil,
                payload: nil,
                failure: VPNHelperProtocolFailure(
                    code: .commandFailed,
                    summary: "status failed",
                    details: "bounded details",
                    retryDisposition: .never
                )
            ))
        }
        do {
            _ = try PrivilegedHelperClient(transport: transport).status()
            preconditionFailure("Expected structured command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            precondition(summary == "status failed")
            precondition(details == "bounded details")
        }
    }

    private static func verifyLostStartReconcilesOnce() throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(mutating: .startSession, sessionID: sessionID, phase: .running)
        let client = PrivilegedHelperClient(transport: transport)
        _ = try client.start(session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID)
        precondition(transport.calls.map(\.0) == [.startSession, .status])
        precondition(transport.invalidations == 1)
    }

    private static func verifyLostStopReconcilesOnce() throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(
            mutating: .stopSession,
            sessionID: sessionID,
            phase: .idle,
            transportFailure: .invalidated
        )
        let client = PrivilegedHelperClient(transport: transport)
        try client.stop(
            paths: XrayTunRuntimePaths(),
            protectedHost: "example.com",
            outboundInterface: "en0",
            sessionID: sessionID
        )
        precondition(transport.calls.map(\.0) == [.stopSession, .status])
        precondition(transport.invalidations == 1)
    }

    private static func verifyFailedReconciliationIsCommandFailure() throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(
            mutating: .startSession,
            sessionID: sessionID,
            phase: .failed,
            summary: "start failed",
            details: "bounded details"
        )
        do {
            _ = try PrivilegedHelperClient(transport: transport).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID
            )
            preconditionFailure("Expected command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            precondition(summary == "start failed")
            precondition(details == "bounded details")
        }
        precondition(transport.calls.count == 2)
    }

    private static func verifyUnavailableAndUnknownReconciliationAreIndeterminate() throws {
        let unavailableSession = UUID()
        let unavailable = ScriptedTransport { command, _, _, _ in
            if command == .startSession { throw VPNHelperTransportError.interrupted }
            throw VPNHelperTransportError.unavailable("not running")
        }
        try assertIndeterminate(sessionID: unavailableSession) {
            _ = try PrivilegedHelperClient(transport: unavailable).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: unavailableSession
            )
        }
        precondition(unavailable.calls.map(\.0) == [.startSession, .status])

        let unknownSession = UUID()
        let unknown = reconciliationTransport(mutating: .stopSession, sessionID: unknownSession, phase: .unknown)
        try assertIndeterminate(sessionID: unknownSession) {
            try PrivilegedHelperClient(transport: unknown).stop(
                paths: XrayTunRuntimePaths(), protectedHost: nil, outboundInterface: nil, sessionID: unknownSession
            )
        }
        precondition(unknown.calls.map(\.0) == [.stopSession, .status])
    }

    private static func verifyDispatcherPublishesMemoryOnlyCorrelation() throws {
        let source = try String(contentsOfFile: "TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift", encoding: .utf8)
        precondition(source.contains("observedSessionID"))
        precondition(source.contains("responseSessionID: observedSessionID"))
        precondition(source.contains("observedSessionID = successfulSessionID"))
    }

    private static func verifyStartCorrelationPersistenceOrderingAndFailureRetention() throws {
        enum ExpectedFailure: Error { case start }

        var failedEvents: [String] = []
        do {
            _ = try XrayTunStartCorrelation.perform(
                persist: { pid in failedEvents.append("persist:\(pid.map(String.init) ?? "nil")") },
                start: {
                    failedEvents.append("start")
                    throw ExpectedFailure.start
                }
            )
            preconditionFailure("Expected start failure")
        } catch ExpectedFailure.start {}
        precondition(failedEvents == ["persist:nil", "start"])

        var successfulEvents: [String] = []
        let pid = try XrayTunStartCorrelation.perform(
            persist: { pid in successfulEvents.append("persist:\(pid.map(String.init) ?? "nil")") },
            start: {
                successfulEvents.append("start")
                return 42
            }
        )
        precondition(pid == 42)
        precondition(successfulEvents == ["persist:nil", "start", "persist:42"])
    }

    private static func verifyLostXPCStopReplyDoesNotReplayMutation() throws {
        let sessionID = UUID()
        let mutatingProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: true)
        let statusProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: false)
        let factory = LostStopReplyConnectionFactory(connections: [
            LostStopReplyConnection(proxy: mutatingProxy),
            LostStopReplyConnection(proxy: statusProxy)
        ])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })
        let client = PrivilegedHelperClient(transport: transport)

        try client.stop(
            paths: XrayTunRuntimePaths(),
            protectedHost: "example.com",
            outboundInterface: "en0",
            sessionID: sessionID
        )

        precondition(mutatingProxy.counts.stop == 1)
        precondition(mutatingProxy.counts.status == 0)
        precondition(statusProxy.counts.stop == 0)
        precondition(statusProxy.counts.status == 1)
    }

    private static func verifyRuntimePersistsSessionCorrelation() throws {
        let managerSource = try String(contentsOfFile: "teleport/VPN/PrivilegedXrayRuntimeManager.swift", encoding: .utf8)
        let stateSource = try String(contentsOfFile: "teleport/VPN/XrayTunSessionState.swift", encoding: .utf8)
        precondition(managerSource.contains("let sessionID = UUID()"))
        precondition(managerSource.contains("XrayTunStartCorrelation.perform"))
        precondition(managerSource.contains("sessionID: sessionID"))
        precondition(stateSource.contains("var sessionID: UUID"))

        let stopStart = managerSource.range(of: "    func stop() throws {")!.lowerBound
        let stopEnd = managerSource.range(
            of: "    func cleanupIfHelperAvailable",
            range: stopStart..<managerSource.endIndex
        )!.lowerBound
        let stopSource = managerSource[stopStart..<stopEnd]
        precondition(stopSource.components(separatedBy: "helperClient.stop(").count - 1 == 1)
    }

    private static func verifyClientContainsNoSocketTransport() throws {
        let source = try String(contentsOfFile: "teleport/VPN/PrivilegedHelperClient.swift", encoding: .utf8)
        for forbidden in ["AF_UNIX", "sockaddr_un", "Darwin.connect", "shutdown(", "timeval", "socketPath", "PrivilegedHelperRequest", "PrivilegedHelperResponse"] {
            precondition(!source.contains(forbidden), "Legacy client symbol remains: \(forbidden)")
        }
    }

    private static func reconciliationTransport(
        mutating command: VPNHelperCommand,
        sessionID: UUID,
        phase: VPNHelperSessionPhase,
        summary: String? = nil,
        details: String? = nil,
        transportFailure: VPNHelperTransportError = .deadlineExceeded
    ) -> ScriptedTransport {
        ScriptedTransport { actualCommand, data, _, index in
            precondition(index < 2)
            if actualCommand == command {
                throw transportFailure
            }
            precondition(actualCommand == .status)
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            precondition(request.sessionID == nil)
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StatusResponse(helperVersion: "8", phase: phase, summary: summary, details: details)
            )
        }
    }

    private static func assertIndeterminate(sessionID: UUID, operation: () throws -> Void) throws {
        do {
            try operation()
            preconditionFailure("Expected indeterminate result")
        } catch let PrivilegedHelperClientError.indeterminate(requestID, actualSessionID, _) {
            precondition(requestID != UUID())
            precondition(actualSessionID == sessionID)
        }
    }

    private static func launchSession() -> XrayTunLaunchSession {
        XrayTunLaunchSession(
            configData: Data("{}".utf8),
            protectedHost: "example.com",
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0"
        )
    }

    fileprivate static func response<Payload>(
        requestID: UUID,
        sessionID: UUID?,
        payload: Payload
    ) throws -> Data where Payload: Codable & Sendable & Equatable {
        try VPNHelperCodec.encodeResponse(VPNHelperResponseEnvelope(
            revision: VPNHelperProtocol.revision,
            requestID: requestID,
            sessionID: sessionID,
            payload: payload,
            failure: nil
        ))
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
