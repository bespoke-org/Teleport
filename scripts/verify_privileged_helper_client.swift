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

    func send(command: VPNHelperCommand, requestData: Data, timeout: TimeInterval) async throws -> Data {
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

private final class NoopCreateDirectoryFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {}
}

private final class RecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionID: UUID?
    private var storedInstallCount = 0

    var sessionID: UUID? { lock.withLock { storedSessionID } }
    var installCount: Int { lock.withLock { storedInstallCount } }

    func record(sessionID: UUID) {
        lock.withLock { storedSessionID = sessionID }
    }

    func recordInstall() {
        lock.withLock { storedInstallCount += 1 }
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

    func engageLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "test", code: 1))
    }

    func releaseLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "test", code: 1))
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
    static func main() async throws {
        try await verifyDeadlinesPayloadsAndNormalMapping()
        try await verifyCommandSpecificSuccessPayloadValidation()
        try await verifyResponseIdentityAndRevisionValidation()
        try await verifyStructuredCommandFailureMapping()
        try await verifyLostStartReconcilesOnce()
        try await verifyLostStopReconcilesOnce()
        try await verifyFailedReconciliationIsCommandFailure()
        try await verifyUnavailableAndUnknownReconciliationAreIndeterminate()
        try await verifyStartCorrelationPersistenceOrderingAndFailureRetention()
        try await verifyFailedRuntimeStartRollsBackMatchingSession()
        try await verifyUnavailableRuntimeStopReinstallsAndRetries()
        try await verifyLostXPCStopReplyDoesNotReplayMutation()
        try await verifyRuntimeResolvesMissingSessionWithoutInventingIdentity()
        try await verifyInvalidStopResponsePreservesCachedState()
        print("verify_privileged_helper_client: all checks passed")
    }

    private static func verifyDeadlinesPayloadsAndNormalMapping() async throws {
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
            case .engageLeakGuard:
                let request: VPNHelperRequestEnvelope<EngageLeakGuardRequest> = try VPNHelperCodec.decodeRequest(data)
                // The guard spans the teardown and rebuild a session change consists
                // of, so it is deliberately not scoped to one session.
                precondition(request.sessionID == nil)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: LeakGuardResponse(isEngaged: true)
                )
            case .releaseLeakGuard:
                let request: VPNHelperRequestEnvelope<ReleaseLeakGuardRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == nil)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: LeakGuardResponse(isEngaged: false)
                )
            }
        }
        let client = PrivilegedHelperClient(transport: transport)
        let paths = XrayTunRuntimePaths()
        let launch = launchSession()

        let status = try await client.status()
        precondition(status.success && status.version == "8" && status.phase == .idle)
        let diagnostics = try await client.readLog(logName: "xray-tun.log", maxBytes: Int.max)
        precondition(diagnostics.success && diagnostics.details == "diagnostic")
        let config = try await client.readLog(logName: "xray-tun-config.json", maxBytes: Int.max)
        precondition(config.success && config.payload.log == .config && config.details == "diagnostic")
        let processIdentifier = try await client.start(session: launch, paths: paths, sessionID: sessionID)
        precondition(processIdentifier == nil)
        try await client.stop(paths: paths, protectedHosts: launch.protectedHosts, outboundInterface: launch.outboundInterface, sessionID: sessionID)
        try await client.engageLeakGuard(
            tunnelInterfaceName: launch.tunnelInterfaceName,
            protectedHosts: launch.protectedHosts,
            leaseSeconds: LeakGuardService.leaseSeconds
        )
        try await client.releaseLeakGuard()

        precondition(transport.calls.map(\.0) == [.status, .readDiagnostics, .readDiagnostics, .startSession, .stopSession, .engageLeakGuard, .releaseLeakGuard])
        precondition(transport.calls.map(\.2) == [3, 5, 5, 20, 15, 10, 10])
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
            case .engageLeakGuard:
                let request: VPNHelperRequestEnvelope<EngageLeakGuardRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            case .releaseLeakGuard:
                let request: VPNHelperRequestEnvelope<ReleaseLeakGuardRequest> = try VPNHelperCodec.decodeRequest(data)
                return request.requestID
            }
        }
        precondition(Set(requestIDs).count == requestIDs.count)
    }

    private static func verifyCommandSpecificSuccessPayloadValidation() async throws {
        let sessionID = UUID()
        let invalidStart = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StartSessionResponse(phase: .idle, summary: nil, details: nil)
            )
        }
        try await assertInvalidResponse {
            _ = try await PrivilegedHelperClient(transport: invalidStart).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID
            )
        }

        let invalidStop = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StopSessionResponse(phase: .running, summary: nil, details: nil)
            )
        }
        try await assertInvalidResponse {
            try await PrivilegedHelperClient(transport: invalidStop).stop(
                paths: XrayTunRuntimePaths(), protectedHosts: nil, outboundInterface: nil, sessionID: sessionID
            )
        }

        let mismatchedDiagnostics = ScriptedTransport { _, data, _, _ in
            let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(data)
            precondition(request.payload.log == .xray)
            return try response(
                requestID: request.requestID,
                sessionID: nil,
                payload: DiagnosticsResponse(log: .control, text: "wrong log", metadata: "meta", wasTruncated: false)
            )
        }
        try await assertInvalidResponse {
            _ = try await PrivilegedHelperClient(transport: mismatchedDiagnostics).readLog(
                logName: "xray-tun.log", maxBytes: 1_024
            )
        }
    }

    private static func verifyResponseIdentityAndRevisionValidation() async throws {
        let mismatchTransport = ScriptedTransport { _, _, _, _ in
            try response(
                requestID: UUID(),
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
            )
        }
        do {
            _ = try await PrivilegedHelperClient(transport: mismatchTransport).status()
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
            _ = try await PrivilegedHelperClient(transport: sessionMismatchTransport).start(
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
            _ = try await PrivilegedHelperClient(transport: staleTransport).status()
            preconditionFailure("Expected incompatible service")
        } catch PrivilegedHelperClientError.incompatibleService {}
    }

    private static func verifyStructuredCommandFailureMapping() async throws {
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
            _ = try await PrivilegedHelperClient(transport: transport).status()
            preconditionFailure("Expected structured command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            precondition(summary == "status failed")
            precondition(details == "bounded details")
        }
    }

    private static func verifyLostStartReconcilesOnce() async throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(mutating: .startSession, sessionID: sessionID, phase: .running)
        let client = PrivilegedHelperClient(transport: transport)
        _ = try await client.start(session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID)
        precondition(transport.calls.map(\.0) == [.startSession, .status])
        precondition(transport.invalidations == 1)
    }

    private static func verifyLostStopReconcilesOnce() async throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(
            mutating: .stopSession,
            sessionID: sessionID,
            phase: .idle,
            transportFailure: .invalidated
        )
        let client = PrivilegedHelperClient(transport: transport)
        try await client.stop(
            paths: XrayTunRuntimePaths(),
            protectedHosts: ["example.com"],
            outboundInterface: "en0",
            sessionID: sessionID
        )
        precondition(transport.calls.map(\.0) == [.stopSession, .status])
        precondition(transport.invalidations == 1)
    }

    private static func verifyFailedReconciliationIsCommandFailure() async throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(
            mutating: .startSession,
            sessionID: sessionID,
            phase: .failed,
            summary: "start failed",
            details: "bounded details"
        )
        do {
            _ = try await PrivilegedHelperClient(transport: transport).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID
            )
            preconditionFailure("Expected command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            precondition(summary == "start failed")
            precondition(details == "bounded details")
        }
        precondition(transport.calls.count == 2)
    }

    private static func verifyUnavailableAndUnknownReconciliationAreIndeterminate() async throws {
        let unavailableSession = UUID()
        let unavailable = ScriptedTransport { command, _, _, _ in
            if command == .startSession { throw VPNHelperTransportError.interrupted }
            throw VPNHelperTransportError.unavailable("not running")
        }
        try await assertIndeterminate(sessionID: unavailableSession) {
            _ = try await PrivilegedHelperClient(transport: unavailable).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: unavailableSession
            )
        }
        precondition(unavailable.calls.map(\.0) == [.startSession, .status])

        let unknownSession = UUID()
        let unknown = reconciliationTransport(mutating: .stopSession, sessionID: unknownSession, phase: .unknown)
        try await assertIndeterminate(sessionID: unknownSession) {
            try await PrivilegedHelperClient(transport: unknown).stop(
                paths: XrayTunRuntimePaths(), protectedHosts: nil, outboundInterface: nil, sessionID: unknownSession
            )
        }
        precondition(unknown.calls.map(\.0) == [.stopSession, .status])
    }

    private static func verifyStartCorrelationPersistenceOrderingAndFailureRetention() async throws {
        enum ExpectedFailure: Error { case start }

        var failedEvents: [String] = []
        do {
            _ = try await XrayTunStartCorrelation.perform(
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
        let pid = try await XrayTunStartCorrelation.perform(
            persist: { pid in successfulEvents.append("persist:\(pid.map(String.init) ?? "nil")") },
            start: {
                successfulEvents.append("start")
                return 42
            }
        )
        precondition(pid == 42)
        precondition(successfulEvents == ["persist:nil", "start", "persist:42"])
    }

    private static func verifyFailedRuntimeStartRollsBackMatchingSession() async throws {
        let paths = try temporaryRuntimePaths(named: "failed-start-rollback")
        defer { removeTemporaryRuntimePaths(paths) }
        let probe = RecoveryProbe()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .startSession:
                let request: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                let sessionID = request.sessionID!
                probe.record(sessionID: sessionID)
                return try VPNHelperCodec.encodeResponse(VPNHelperResponseEnvelope<StartSessionResponse>(
                    revision: VPNHelperProtocol.revision,
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: nil,
                    failure: VPNHelperProtocolFailure(
                        code: .commandFailed,
                        summary: "start failed",
                        details: nil,
                        retryDisposition: .never
                    )
                ))
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == probe.sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: request.sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            case .readDiagnostics:
                let request: VPNHelperRequestEnvelope<ReadDiagnosticsRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.payload.log == .control)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: DiagnosticsResponse(log: .control, text: "specific control failure", metadata: "test", wasTruncated: false)
                )
            default:
                preconditionFailure("Unexpected command: \(command)")
            }
        }
        let manager = PrivilegedXrayRuntimeManager(
            fileManager: NoopCreateDirectoryFileManager(),
            helperClient: PrivilegedHelperClient(transport: transport),
            paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") },
            assetDirectoryURLProvider: { URL(fileURLWithPath: "/tmp/test-assets", isDirectory: true) },
            ensureHelperInstalled: { _, _ in }
        )

        do {
            try await manager.start(session: launchSession())
            preconditionFailure("Expected start failure")
        } catch let XrayTunRuntimeError.startFailed(_, details) {
            precondition(details.contains("specific control failure"))
        }

        precondition(transport.calls.map(\.0) == [.startSession, .stopSession, .readDiagnostics])
        precondition(!FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
    }

    private static func verifyUnavailableRuntimeStopReinstallsAndRetries() async throws {
        let paths = try temporaryRuntimePaths(named: "unavailable-stop-recovery")
        defer { removeTemporaryRuntimePaths(paths) }
        let sessionID = UUID()
        let state = XrayTunSessionState(
            sessionID: sessionID,
            pid: nil,
            protectedHosts: ["example.com"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            configPath: paths.configFileURL.path,
            startedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: paths.sessionStateFileURL, options: .atomic)

        let probe = RecoveryProbe()
        let transport = ScriptedTransport { command, data, _, index in
            precondition(command == .stopSession)
            let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
            precondition(request.sessionID == sessionID)
            if index == 0 { throw VPNHelperTransportError.unavailable("not running") }
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
            )
        }
        let manager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: transport),
            paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") },
            ensureHelperInstalled: { _, _ in probe.recordInstall() }
        )

        try await manager.stop()

        precondition(probe.installCount == 1)
        precondition(transport.calls.map(\.0) == [.stopSession, .stopSession])
        precondition(!FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
    }

    private static func verifyLostXPCStopReplyDoesNotReplayMutation() async throws {
        let sessionID = UUID()
        let mutatingProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: true)
        let statusProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: false)
        let factory = LostStopReplyConnectionFactory(connections: [
            LostStopReplyConnection(proxy: mutatingProxy),
            LostStopReplyConnection(proxy: statusProxy)
        ])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })
        let client = PrivilegedHelperClient(transport: transport)

        try await client.stop(
            paths: XrayTunRuntimePaths(),
            protectedHosts: ["example.com"],
            outboundInterface: "en0",
            sessionID: sessionID
        )

        precondition(mutatingProxy.counts.stop == 1)
        precondition(mutatingProxy.counts.status == 0)
        precondition(statusProxy.counts.stop == 0)
        precondition(statusProxy.counts.status == 1)
    }

    private static func verifyRuntimeResolvesMissingSessionWithoutInventingIdentity() async throws {
        let idlePaths = try temporaryRuntimePaths(named: "idle")
        defer { removeTemporaryRuntimePaths(idlePaths) }
        let idleTransport = ScriptedTransport { command, data, _, _ in
            precondition(command == .status)
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
            )
        }
        let idleManager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: idleTransport),
            paths: idlePaths
        )
        try await idleManager.stop()
        try await idleManager.stop()
        precondition(idleTransport.calls.map(\.0) == [.status, .status])

        let observedSessionID = UUID()
        let runningPaths = try temporaryRuntimePaths(named: "running")
        defer { removeTemporaryRuntimePaths(runningPaths) }
        let runningTransport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == observedSessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            default:
                preconditionFailure("Unexpected command: \(command)")
            }
        }
        let runningManager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: runningTransport),
            paths: runningPaths
        )
        try await runningManager.stop()
        precondition(runningTransport.calls.map(\.0) == [.status, .stopSession])

        let cleanupPaths = try temporaryRuntimePaths(named: "cleanup")
        defer { removeTemporaryRuntimePaths(cleanupPaths) }
        let cleanupTransport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
                precondition(request.sessionID == observedSessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            default:
                preconditionFailure("Unexpected command: \(command)")
            }
        }
        try await PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: cleanupTransport),
            paths: cleanupPaths
        ).cleanupIfHelperAvailable()
        precondition(cleanupTransport.calls.map(\.0) == [.status, .stopSession])

        let unidentifiedPaths = try temporaryRuntimePaths(named: "unidentified")
        defer { removeTemporaryRuntimePaths(unidentifiedPaths) }
        let unidentifiedTransport = ScriptedTransport { command, data, _, _ in
            precondition(command == .status)
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
            )
        }
        let unidentifiedManager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: unidentifiedTransport),
            paths: unidentifiedPaths
        )
        do {
            try await unidentifiedManager.stop()
            preconditionFailure("Expected an indeterminate unidentified-session failure")
        } catch let XrayTunRuntimeError.stopFailed(summary, _) {
            precondition(summary.localizedCaseInsensitiveContains("session"))
        }
        precondition(unidentifiedTransport.calls.map(\.0) == [.status])

        let cleanupUnidentifiedPaths = try temporaryRuntimePaths(named: "cleanup-unidentified")
        defer { removeTemporaryRuntimePaths(cleanupUnidentifiedPaths) }
        let cleanupUnidentifiedTransport = ScriptedTransport { command, data, _, _ in
            precondition(command == .status)
            let request: VPNHelperRequestEnvelope<StatusRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
            )
        }
        do {
            try await PrivilegedXrayRuntimeManager(
                helperClient: PrivilegedHelperClient(transport: cleanupUnidentifiedTransport),
                paths: cleanupUnidentifiedPaths
            ).cleanupIfHelperAvailable()
            preconditionFailure("Expected cleanup to report unidentified running state")
        } catch let PrivilegedHelperClientError.indeterminateStatus(summary) {
            precondition(summary.localizedCaseInsensitiveContains("correlation"))
        }
        precondition(cleanupUnidentifiedTransport.calls.map(\.0) == [.status])
    }

    private static func verifyInvalidStopResponsePreservesCachedState() async throws {
        let paths = try temporaryRuntimePaths(named: "invalid-stop")
        defer { removeTemporaryRuntimePaths(paths) }
        let sessionID = UUID()
        let state = XrayTunSessionState(
            sessionID: sessionID,
            pid: nil,
            protectedHosts: ["example.com"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0",
            configPath: paths.configFileURL.path,
            startedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: paths.sessionStateFileURL, options: .atomic)

        let transport = ScriptedTransport { command, data, _, _ in
            precondition(command == .stopSession)
            let request: VPNHelperRequestEnvelope<StopSessionRequest> = try VPNHelperCodec.decodeRequest(data)
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StopSessionResponse(phase: .running, summary: nil, details: nil)
            )
        }
        let manager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: transport),
            paths: paths
        )
        do {
            try await manager.stop()
            preconditionFailure("Expected invalid stop response")
        } catch XrayTunRuntimeError.stopFailed {}
        precondition(FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
        precondition(transport.calls.map(\.0) == [.stopSession])
    }

    private static func temporaryRuntimePaths(named name: String) throws -> XrayTunRuntimePaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-task6-\(name)-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = URL(
            fileURLWithPath: "/Users/teleport-task6/Library/Application Support/teleport",
            isDirectory: true
        )
        let helperDirectory = root.appendingPathComponent("helper-state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        return XrayTunRuntimePaths(
            stateDirectoryURL: stateDirectory,
            helperStateDirectoryURL: helperDirectory,
            sessionStateFileURL: root.appendingPathComponent("xray-tun-session.json")
        )
    }

    private static func removeTemporaryRuntimePaths(_ paths: XrayTunRuntimePaths) {
        try? FileManager.default.removeItem(at: paths.sessionStateFileURL.deletingLastPathComponent())
    }

    private static func assertInvalidResponse(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            preconditionFailure("Expected invalid response")
        } catch PrivilegedHelperClientError.invalidResponse {}
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

    private static func assertIndeterminate(sessionID: UUID, operation: () async throws -> Void) async throws {
        do {
            try await operation()
            preconditionFailure("Expected indeterminate result")
        } catch let PrivilegedHelperClientError.indeterminate(requestID, actualSessionID, _) {
            precondition(requestID != UUID())
            precondition(actualSessionID == sessionID)
        }
    }

    private static func launchSession() -> XrayTunLaunchSession {
        XrayTunLaunchSession(
            configData: Data("{}".utf8),
            protectedHosts: ["example.com"],
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
