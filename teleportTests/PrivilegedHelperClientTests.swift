import Foundation
import XCTest

/// Thrown by scripted transports for a command the test did not expect, after recording the failure.
private struct UnexpectedCommand: Error {
    let command: TUNHelperCommand
}

private final class ScriptedTransport: TUNHelperTransport, @unchecked Sendable {
    typealias Handler = (TUNHelperCommand, Data, TimeInterval, Int) throws -> Data

    private let lock = NSLock()
    private let handler: Handler
    private var recordedCalls: [(TUNHelperCommand, Data, TimeInterval)] = []
    private var invalidationCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var calls: [(TUNHelperCommand, Data, TimeInterval)] {
        lock.withLock { recordedCalls }
    }

    var invalidations: Int {
        lock.withLock { invalidationCount }
    }

    func send(command: TUNHelperCommand, requestData: Data, timeout: TimeInterval) async throws -> Data {
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

private final class LostStopReplyProxy: NSObject, TUNHelperXPCProtocol, @unchecked Sendable {
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

    func resolveEndpoint(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "test.unexpected-resolve", code: 1))
    }

    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { statusCalls += 1 }
        do {
            let envelope: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(request)
            reply(try response(
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

private final class LostStopReplyConnection: TUNHelperXPCConnection, @unchecked Sendable {
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
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> (any TUNHelperXPCProtocol)? {
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

    func make() -> any TUNHelperXPCConnection {
        lock.withLock {
            XCTAssert(!connections.isEmpty, "Unexpected XPC connection creation")
            return connections.removeFirst()
        }
    }
}

final class PrivilegedHelperClientTests: XCTestCase {
    @MainActor
    func testFailedTUNRecoveryKeepsProxyRestorationFailureActionable() async throws {
        try await assertTUNProxyRestorationFailure(cancelBeforeStart: false)
    }

    @MainActor
    func testCancelledTUNStartKeepsProxyRestorationFailureActionable() async throws {
        try await assertTUNProxyRestorationFailure(cancelBeforeStart: true)
    }

    @MainActor
    private func assertTUNProxyRestorationFailure(cancelBeforeStart: Bool) async throws {
        let paths = try temporaryRuntimePaths(named: "tun-proxy-restore")
        defer { removeTemporaryRuntimePaths(paths) }
        let root = paths.sessionStateFileURL.deletingLastPathComponent()
        let snapshot = root.appendingPathComponent("teleport/system-proxy-snapshot.json")
        let recovery = RecoveryProbe()
        let restore = ProxyRestoreProbe()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                let hasOldConfig = recovery.sessionID == nil
                return try response(requestID: request.requestID, sessionID: nil,
                    payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion,
                        phase: .idle, summary: nil, details: nil,
                        tunnelInterfaceName: hasOldConfig ? "utun10" : nil,
                        outboundInterface: hasOldConfig ? "en0" : nil))
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                recovery.record(sessionID: try XCTUnwrap(request.sessionID))
                return try response(requestID: request.requestID, sessionID: request.sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
            default: throw UnexpectedCommand(command: command)
            }
        }
        let manager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: transport), paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") },
            ensureHelperInstalled: { _, _ in }
        )
        let proxyService = SystemProxyService(processRunner: { try restore.run($0) },
            fileManager: ReconnectFileManager(root: root))
        let backend = XrayTunConnectionBackend(runtimeManager: manager,
            routeInspector: XrayTunRouteInspector(runCommand: { executable, _ in
                executable.hasSuffix("dscacheutil") ? nil : "interface: en0\n"
            }), systemProxyService: proxyService, leakGuard: LeakGuardService(isEnabled: false))
        let provider = BackendConnectionProvider(mode: .tun, backend: backend)
        let ready = expectation(description: "Initial TUN state resolved")
        let observation = Task {
            for await state in provider.stateUpdates() where state == .idle {
                ready.fulfill()
                break
            }
        }
        defer { observation.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        // Create the old snapshot after initial resolution. All networksetup
        // commands are intercepted, so this never changes the machine's proxies.
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"createdAt":0,"endpoint":{"host":"127.0.0.1","httpPort":1087,"socksPort":1080},"services":[]}"#.utf8).write(to: snapshot)
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@next.invalid:443?security=none&type=tcp")
        let request = ConnectionRequest(defaultConnection: .init(id: UUID(), configuration: configuration),
            localProxy: .default, splitTunnelPolicy: .init(rules: [], defaultAction: .proxy), usesLeakGuard: false)
        let attempt = Task {
            if cancelBeforeStart { withUnsafeCurrentTask { $0?.cancel() } }
            try await provider.connect(request)
        }
        do { try await attempt.value; XCTFail("Expected failed startup") }
        catch is CancellationError { XCTAssertTrue(cancelBeforeStart) }
        catch { XCTAssertFalse(cancelBeforeStart) }
        if case let .failed(failure) = await provider.currentState() {
            XCTAssertTrue(failure.details?.contains("could not finish disconnecting") == true)
            XCTAssertTrue(failure.details?.contains("Synthetic proxy restore failure") == true)
        } else {
            XCTFail("An un-restored TUN proxy snapshot must keep Disconnect available")
        }
        XCTAssertTrue(proxyService.hasSavedProxySnapshot())
        if !cancelBeforeStart { XCTAssertNotNil(recovery.sessionID, "Old tunnel cleanup precedes DNS failure") }

        restore.allowRestoration()
        try await provider.disconnect()
        let finalState = await provider.currentState()
        XCTAssertEqual(finalState, .idle)
        XCTAssertFalse(proxyService.hasSavedProxySnapshot(), "Disconnect must retry the real TUN proxy restoration")
    }

    @MainActor
    func testReconnectResolvesNewEndpointBeforeStoppingTunnelDNS() async throws {
        try await assertReconnectResolution(availableBeforeStop: true)
    }

    @MainActor
    func testReconnectRetriesResolutionAfterStoppingBrokenTunnel() async throws {
        try await assertReconnectResolution(availableBeforeStop: false)
    }

    @MainActor
    func testCancelledReconnectStillStopsPreviousSession() async throws {
        try await assertReconnectResolution(availableBeforeStop: true, cancelBeforeReconnect: true)
    }

    @MainActor
    private func assertReconnectResolution(availableBeforeStop: Bool, cancelBeforeReconnect: Bool = false) async throws {
        let paths = try temporaryRuntimePaths(named: "reconnect-dns")
        defer { removeTemporaryRuntimePaths(paths) }
        let sessionID = UUID()
        let state = XrayTunSessionState(sessionID: sessionID, pid: nil, protectedHosts: ["192.0.2.1"],
                                        tunnelInterfaceName: "utun10", outboundInterface: "en0",
                                        configPath: paths.configFileURL.path, startedAt: Date())
        try JSONEncoder().encode(state).write(to: paths.sessionStateFileURL)
        let network = ReconnectDNSProbe(availableBeforeStop: availableBeforeStop)
        let transport = ScriptedTransport { command, data, _, _ in
            XCTAssertEqual(command, .stopSession)
            let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
            network.stopTunnel()
            return try response(requestID: request.requestID, sessionID: sessionID,
                                payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
        }
        let manager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: transport), paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") },
            // End at the helper preparation boundary, before changing any real
            // proxy settings, firewall rules, routes or processes.
            ensureHelperInstalled: { _, _ in throw ReconnectDNSProbe.Reached.helperPreparation }
        )
        let backend = XrayTunConnectionBackend(
            runtimeManager: manager,
            routeInspector: XrayTunRouteInspector(runCommand: { network.command($0, $1) }),
            systemProxyService: SystemProxyService(fileManager: ReconnectFileManager(root: paths.sessionStateFileURL.deletingLastPathComponent())),
            leakGuard: LeakGuardService(isEnabled: false)
        )
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@next.example.test:443?security=none&type=tcp"
        )
        let request = ConnectionRequest(defaultConnection: .init(id: UUID(), configuration: configuration),
                                        localProxy: .default, splitTunnelPolicy: .init(rules: [], defaultAction: .proxy), usesLeakGuard: false)
        do {
            let task = Task { try await backend.reconnect(request, reportPhase: { _ in }) }
            if cancelBeforeReconnect { task.cancel() }
            try await task.value
            XCTFail("Expected to stop at helper preparation")
        } catch ReconnectDNSProbe.Reached.helperPreparation {
            XCTAssertFalse(cancelBeforeReconnect)
            // Success: the next session was prepared despite DNS disappearing
            // with the previous tunnel, as it can during resolver reconfiguration.
        } catch is CancellationError {
            XCTAssertTrue(cancelBeforeReconnect)
        } catch {
            XCTFail("Reconnect lost DNS before resolving its next endpoint: \(error)")
        }
        XCTAssertEqual(network.events.first, cancelBeforeReconnect ? "stop" : "resolve")
        XCTAssertTrue(network.events.contains("stop"))
        XCTAssertEqual(network.events.filter { $0 == "resolve" }.count, cancelBeforeReconnect ? 0 : (availableBeforeStop ? 1 : 2))
    }

    @MainActor
    func testConnectRecoversOwnedTunnelBeforeCheckingForVPNConflicts() async throws {
        let paths = try temporaryRuntimePaths(named: "connect-recovery")
        defer { removeTemporaryRuntimePaths(paths) }
        let sessionID = UUID()
        let probe = RecoveryProbe()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(requestID: request.requestID, sessionID: sessionID,
                    payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion,
                        phase: .running, summary: nil, details: nil,
                        tunnelInterfaceName: "utun10", outboundInterface: "en0"))
            case .stopSession:
                XCTAssertGreaterThan(probe.installCount, 0, "Renew helper approval before trying to stop an older build's tunnel")
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssertEqual(request.sessionID, sessionID)
                probe.record(sessionID: sessionID)
                return try response(requestID: request.requestID, sessionID: sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
            default:
                throw UnexpectedCommand(command: command)
            }
        }
        let manager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: transport), paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") },
            ensureHelperInstalled: { _, _ in probe.recordInstall() }
        )
        let backend = XrayTunConnectionBackend(runtimeManager: manager,
            routeInspector: XrayTunRouteInspector(runCommand: { executable, _ in
                // End at DNS, before touching any actual network settings.
                if executable.hasSuffix("dscacheutil") { return nil }
                return probe.sessionID == nil ? "interface: utun10\n" : "interface: en0\n"
            }),
            systemProxyService: SystemProxyService(fileManager: ReconnectFileManager(root: paths.sessionStateFileURL.deletingLastPathComponent())),
            leakGuard: LeakGuardService(isEnabled: false))
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@next.invalid:443?security=none&type=tcp")
        let request = ConnectionRequest(defaultConnection: .init(id: UUID(), configuration: configuration),
            localProxy: .default, splitTunnelPolicy: .init(rules: [], defaultAction: .proxy), usesLeakGuard: false)
        do {
            try await backend.start(request, reportPhase: { _ in })
            XCTFail("Expected the synthetic DNS lookup to fail")
        } catch XrayTunConnectionError.proxyAddressResolutionFailed {
            // Reaching DNS proves the old TUN no longer blocks the VPN preflight.
        } catch {
            XCTFail("Connect did not recover its own old tunnel: \(error)")
        }
        XCTAssertEqual(probe.sessionID, sessionID)
    }

    @MainActor
    func testConnectRecoveryRetainsDNSFromPreviousTunnel() async throws {
        let paths = try temporaryRuntimePaths(named: "recovery-dns")
        defer { removeTemporaryRuntimePaths(paths) }
        let network = ReconnectDNSProbe(availableBeforeStop: true)
        let sessionID = UUID()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(requestID: request.requestID, sessionID: sessionID,
                    payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion, phase: .running,
                        summary: nil, details: nil, tunnelInterfaceName: "utun10", outboundInterface: "en0"))
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                network.stopTunnel()
                return try response(requestID: request.requestID, sessionID: sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
            default: throw UnexpectedCommand(command: command)
            }
        }
        let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") }, ensureHelperInstalled: { _, _ in })
        let backend = XrayTunConnectionBackend(runtimeManager: manager,
            routeInspector: XrayTunRouteInspector(runCommand: { executable, arguments in
                if executable.hasSuffix("dscacheutil") { return network.command(executable, arguments) }
                // Stop at the route lookup after DNS; never mutate host networking.
                return network.events.contains("stop") ? nil : "interface: utun10\n"
            }),
            systemProxyService: SystemProxyService(fileManager: ReconnectFileManager(root: paths.sessionStateFileURL.deletingLastPathComponent())),
            leakGuard: LeakGuardService(isEnabled: false))
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@next.invalid:443?security=none&type=tcp")
        let request = ConnectionRequest(defaultConnection: .init(id: UUID(), configuration: configuration),
            localProxy: .default, splitTunnelPolicy: .init(rules: [], defaultAction: .proxy), usesLeakGuard: false)
        do {
            try await backend.start(request, reportPhase: { _ in })
            XCTFail("Expected to stop at the synthetic route failure")
        } catch XrayTunConnectionError.proxyRouteUnavailable {
            // The cached answer reached routing despite DNS disappearing on stop.
        } catch { XCTFail("Recovery lost the previous tunnel's DNS answer: \(error)") }
        XCTAssertEqual(network.events, ["resolve", "stop"])
    }

    func testRecoveryDoesNotStopTheOldTunnelWhenProtectionFails() async throws {
        enum ProtectionFailure: Error { case rejected }
        let paths = try temporaryRuntimePaths(named: "recovery-protection-failure")
        defer { removeTemporaryRuntimePaths(paths) }
        let sessionID = UUID()
        let transport = ScriptedTransport { command, data, _, _ in
            XCTAssertEqual(command, .status, "a failed guard must prevent the stop mutation")
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            return try response(requestID: request.requestID, sessionID: sessionID,
                payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion, phase: .running,
                    summary: nil, details: nil, tunnelInterfaceName: "utun10", outboundInterface: "en0"))
        }
        let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths,
            runtimeURLProvider: { URL(fileURLWithPath: "/tmp/test-xray") }, ensureHelperInstalled: { _, _ in })
        do {
            _ = try await manager.recoverPreviousSession(existingVPNInterfaces: ["utun10"]) { throw ProtectionFailure.rejected }
            XCTFail("Expected failed protection to abort recovery")
        } catch ProtectionFailure.rejected {}
        XCTAssertEqual(transport.calls.map(\.0), [.status])
    }

    func testConnectRecoveryUsesHelperOwnershipAfterHelperRestart() async throws {
        // Both a missing UUID after helper restart and a newer observed UUID must
        // take precedence over the stale app cache. Ordinary Disconnect still
        // requires the known session identity (covered separately below).
        for observedSessionID in [nil, UUID()] as [UUID?] {
            let paths = try temporaryRuntimePaths(named: "restarted-helper")
            defer { removeTemporaryRuntimePaths(paths) }
            let cachedSessionID = UUID()
            let state = XrayTunSessionState(sessionID: cachedSessionID, pid: nil, protectedHosts: ["192.0.2.1"],
                tunnelInterfaceName: "utun9", outboundInterface: "en9", configPath: paths.configFileURL.path, startedAt: Date())
            try JSONEncoder().encode(state).write(to: paths.sessionStateFileURL)
            let transport = ScriptedTransport { command, data, _, _ in
                switch command {
                case .status:
                    let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                    return try response(requestID: request.requestID, sessionID: observedSessionID,
                        payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion,
                            phase: .running, summary: nil, details: nil, tunnelInterfaceName: "utun10", outboundInterface: "en0"))
                case .stopSession:
                    let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                    XCTAssertNotNil(request.sessionID)
                    XCTAssertNotEqual(request.sessionID, cachedSessionID)
                    if let observedSessionID { XCTAssertEqual(request.sessionID, observedSessionID) }
                    XCTAssertEqual(request.payload.outboundInterface, "en0")
                    XCTAssertNil(request.payload.protectedHosts, "Use the helper's root-owned route records")
                    return try response(requestID: request.requestID, sessionID: request.sessionID,
                        payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
                default: throw UnexpectedCommand(command: command)
                }
            }
            let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths)
            try await manager.recoverPreviousSession(existingVPNInterfaces: ["utun10"])
            XCTAssertEqual(transport.calls.map(\.0), [.status, .stopSession])
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
        }
    }

    func testConnectRecoveryPreservesOtherVPNsAndUncertainSessions() async throws {
        let scenarios: [(TUNHelperSessionPhase, String?, [String], String)] = [
            (.running, "utun10", ["utun5"], PrivilegedHelperClient.expectedVersion),
            (.running, "utun10", ["utun10", "utun5"], PrivilegedHelperClient.expectedVersion),
            (.running, nil, ["utun10"], PrivilegedHelperClient.expectedVersion),
            (.running, nil, [], PrivilegedHelperClient.expectedVersion),
            (.starting, "utun10", [], PrivilegedHelperClient.expectedVersion),
            (.stopping, "utun10", [], PrivilegedHelperClient.expectedVersion),
            (.unknown, "utun10", [], PrivilegedHelperClient.expectedVersion),
            (.running, "utun10", ["utun10"], "old")
        ]
        for (phase, tunnel, routes, version) in scenarios {
            let paths = try temporaryRuntimePaths(named: "unsafe-recovery")
            defer { removeTemporaryRuntimePaths(paths) }
            let cache = Data("cached state must survive failed recovery".utf8)
            try cache.write(to: paths.sessionStateFileURL)
            let transport = ScriptedTransport { command, data, _, _ in
                guard command == .status else { XCTFail("Unsafe cleanup attempted"); throw UnexpectedCommand(command: command) }
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(requestID: request.requestID, sessionID: UUID(),
                    payload: StatusResponse(helperVersion: version, phase: phase, summary: nil, details: nil,
                        tunnelInterfaceName: tunnel, outboundInterface: "en0"))
            }
            let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths)
            do {
                try await manager.recoverPreviousSession(existingVPNInterfaces: routes)
                XCTFail("Unsafe recovery accepted: \(phase), \(routes)")
            } catch {
                XCTAssertEqual(transport.calls.map(\.0), [.status])
                XCTAssertEqual(try Data(contentsOf: paths.sessionStateFileURL), cache)
            }
        }
    }

    func testIdleHelperClearsStaleCacheWithoutStoppingAnything() async throws {
        let paths = try temporaryRuntimePaths(named: "idle-recovery")
        defer { removeTemporaryRuntimePaths(paths) }
        try Data("stale state".utf8).write(to: paths.sessionStateFileURL)
        let transport = ScriptedTransport { command, data, _, _ in
            guard command == .status else { throw UnexpectedCommand(command: command) }
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            return try response(requestID: request.requestID, sessionID: nil,
                payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion, phase: .idle, summary: nil, details: nil))
        }
        let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths)
        try await manager.recoverPreviousSession(existingVPNInterfaces: [])
        XCTAssertEqual(transport.calls.map(\.0), [.status])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
    }

    func testConnectCleansRootStateEvenWhenOldProcessAndAppCacheAreGone() async throws {
        let paths = try temporaryRuntimePaths(named: "orphaned-root-state")
        defer { removeTemporaryRuntimePaths(paths) }
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(requestID: request.requestID, sessionID: nil,
                    payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion, phase: .idle,
                        summary: nil, details: nil, tunnelInterfaceName: "utun10", outboundInterface: "en0"))
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssertNotNil(request.sessionID)
                XCTAssertEqual(request.payload.outboundInterface, "en0")
                XCTAssertNil(request.payload.protectedHosts)
                return try response(requestID: request.requestID, sessionID: request.sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil))
            default: throw UnexpectedCommand(command: command)
            }
        }
        let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths)
        let recovered = try await manager.recoverPreviousSession(existingVPNInterfaces: [])
        XCTAssertTrue(recovered)
        XCTAssertEqual(transport.calls.map(\.0), [.status, .stopSession])
    }

    func testRecoveryDoesNotClearCacheWhenStopFails() async throws {
        let paths = try temporaryRuntimePaths(named: "failed-recovery")
        defer { removeTemporaryRuntimePaths(paths) }
        let cache = Data("keep the previous session".utf8)
        try cache.write(to: paths.sessionStateFileURL)
        let transport = ScriptedTransport { command, data, _, _ in
            if command == .stopSession { throw PrivilegedHelperClientError.commandFailed("stop failed", nil) }
            guard command == .status else { throw UnexpectedCommand(command: command) }
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            return try response(requestID: request.requestID, sessionID: UUID(),
                payload: StatusResponse(helperVersion: PrivilegedHelperClient.expectedVersion, phase: .running,
                    summary: nil, details: nil, tunnelInterfaceName: "utun10", outboundInterface: "en0"))
        }
        let manager = PrivilegedXrayRuntimeManager(helperClient: PrivilegedHelperClient(transport: transport), paths: paths)
        do {
            try await manager.recoverPreviousSession(existingVPNInterfaces: ["utun10"])
            XCTFail("Expected stop failure")
        } catch {
            XCTAssertEqual(transport.calls.map(\.0), [.status, .stopSession])
            XCTAssertEqual(try Data(contentsOf: paths.sessionStateFileURL), cache)
        }
    }

    func testEveryProtocolFailureHasAnActionableSummaryAndPreservesDetailsForUI() async throws {
        for code in TUNHelperFailureCode.allCases {
            let rawSummary = code == .commandFailed ? "Xray could not load the routing data. Check Tunnel settings." : "technical-\(code.rawValue)"
            let transport = ScriptedTransport { _, data, _, _ in
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try TUNHelperCodec.encodeResponse(TUNHelperResponseEnvelope<StatusResponse>(
                    revision: TUNHelperProtocol.revision, requestID: request.requestID, sessionID: nil, payload: nil,
                    failure: TUNHelperProtocolFailure(code: code, summary: rawSummary,
                        details: "diagnostic-\(code.rawValue)", retryDisposition: .never)))
            }
            do {
                _ = try await PrivilegedHelperClient(transport: transport).status()
                XCTFail("Expected \(code)")
            } catch {
                let presentation = ConnectionFailure(error: error)
                XCTAssertFalse(presentation.summary.isEmpty, "\(code)")
                if code != .commandFailed { XCTAssertFalse(presentation.summary.contains("technical-"), "\(code): \(presentation.summary)") }
                XCTAssertTrue(presentation.details?.contains("diagnostic-\(code.rawValue)") == true, "\(code)")
            }
        }
    }

    func testEveryTransportFailureHasAnActionableSummaryAndDiagnosticDetails() async throws {
        for transportError in [TUNHelperTransportError.unavailable("technical-unavailable"),
                               .interrupted, .invalidated, .deadlineExceeded, .invalidResponse("technical-response")] {
            let transport = ScriptedTransport { _, _, _, _ in throw transportError }
            do {
                _ = try await PrivilegedHelperClient(transport: transport).status()
                XCTFail("Expected transport failure")
            } catch {
                let presentation = ConnectionFailure(error: error)
                XCTAssertFalse(presentation.summary.contains("technical-"))
                XCTAssertTrue(presentation.summary.contains("Try") || presentation.summary.contains("Reinstall"))
                XCTAssertNotNil(presentation.details)
                XCTAssertFalse(presentation.summary.contains("is not running"), "A timeout or interruption does not establish whether the helper is running")
            }
        }
    }

    func testDeadlinesPayloadsAndNormalMapping() async throws {
        let sessionID = UUID()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .resolveEndpoint:
                let request: TUNHelperRequestEnvelope<ResolveEndpointRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(requestID: request.requestID, sessionID: nil,
                                    payload: ResolveEndpointResponse(addresses: ["203.0.113.10"]))
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
                )
            case .readDiagnostics:
                let request: TUNHelperRequestEnvelope<ReadDiagnosticsRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.payload.maximumBytes == TUNHelperProtocol.maximumDiagnosticsBytes)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: DiagnosticsResponse(log: request.payload.log, text: "diagnostic", metadata: "meta", wasTruncated: false)
                )
            case .startSession:
                let request: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: StartSessionResponse(phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            case .engageLeakGuard:
                let request: TUNHelperRequestEnvelope<EngageLeakGuardRequest> = try TUNHelperCodec.decodeRequest(data)
                // The guard spans the teardown and rebuild a session change consists
                // of, so it is deliberately not scoped to one session.
                XCTAssert(request.sessionID == nil)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: LeakGuardResponse(isEngaged: true)
                )
            case .releaseLeakGuard:
                let request: TUNHelperRequestEnvelope<ReleaseLeakGuardRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == nil)
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
        XCTAssert(status.success && status.version == "8" && status.phase == .idle)
        let addresses = try await client.resolveEndpoint(host: "proxy.example", interface: "en0")
        XCTAssertEqual(addresses, ["203.0.113.10"])
        let diagnostics = try await client.readLog(logName: "xray-tun.log", maxBytes: Int.max)
        XCTAssert(diagnostics.success && diagnostics.details == "diagnostic")
        let config = try await client.readLog(logName: "xray-tun-config.json", maxBytes: Int.max)
        XCTAssert(config.success && config.payload.log == .config && config.details == "diagnostic")
        let processIdentifier = try await client.start(session: launch, paths: paths, sessionID: sessionID)
        XCTAssert(processIdentifier == nil)
        try await client.stop(paths: paths, protectedHosts: launch.protectedHosts, outboundInterface: launch.outboundInterface, sessionID: sessionID)
        try await client.engageLeakGuard(
            tunnelInterfaceName: launch.tunnelInterfaceName,
            protectedHosts: launch.protectedHosts,
            leaseSeconds: LeakGuardService.leaseSeconds
        )
        try await client.releaseLeakGuard()

        XCTAssert(transport.calls.map(\.0) == [.status, .resolveEndpoint, .readDiagnostics, .readDiagnostics, .startSession, .stopSession, .engageLeakGuard, .releaseLeakGuard])
        XCTAssert(transport.calls.map(\.2) == [3, 12, 5, 5, 20, 15, 10, 10])
        let requestIDs = try transport.calls.map { command, data, _ -> UUID in
            switch command {
            case .resolveEndpoint:
                let request: TUNHelperRequestEnvelope<ResolveEndpointRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .readDiagnostics:
                let request: TUNHelperRequestEnvelope<ReadDiagnosticsRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .startSession:
                let request: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .engageLeakGuard:
                let request: TUNHelperRequestEnvelope<EngageLeakGuardRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            case .releaseLeakGuard:
                let request: TUNHelperRequestEnvelope<ReleaseLeakGuardRequest> = try TUNHelperCodec.decodeRequest(data)
                return request.requestID
            }
        }
        XCTAssert(Set(requestIDs).count == requestIDs.count)
    }

    func testCommandSpecificSuccessPayloadValidation() async throws {
        let sessionID = UUID()
        let invalidStart = ScriptedTransport { _, data, _, _ in
            let request: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(data)
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
            let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
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
            let request: TUNHelperRequestEnvelope<ReadDiagnosticsRequest> = try TUNHelperCodec.decodeRequest(data)
            XCTAssert(request.payload.log == .xray)
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

    func testResponseIdentityAndRevisionValidation() async throws {
        let mismatchTransport = ScriptedTransport { _, _, _, _ in
            try response(
                requestID: UUID(),
                sessionID: nil,
                payload: StatusResponse(helperVersion: "8", phase: .idle, summary: nil, details: nil)
            )
        }
        do {
            _ = try await PrivilegedHelperClient(transport: mismatchTransport).status()
            XCTFail("Expected request identifier mismatch")
        } catch PrivilegedHelperClientError.invalidResponse {}

        let expectedSessionID = UUID()
        let sessionMismatchTransport = ScriptedTransport { _, data, _, _ in
            let request: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(data)
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
            XCTFail("Expected session identifier mismatch")
        } catch PrivilegedHelperClientError.invalidResponse {}

        let staleTransport = ScriptedTransport { _, data, _, _ in
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            let stale = TUNHelperResponseEnvelope(
                revision: TUNHelperProtocol.revision - 1,
                requestID: request.requestID,
                sessionID: nil,
                payload: StatusResponse(helperVersion: "7", phase: .idle, summary: nil, details: nil),
                failure: nil
            )
            return try JSONEncoder().encode(stale)
        }
        do {
            _ = try await PrivilegedHelperClient(transport: staleTransport).status()
            XCTFail("Expected incompatible service")
        } catch PrivilegedHelperClientError.incompatibleService {}
    }

    func testStructuredCommandFailureMapping() async throws {
        let transport = ScriptedTransport { _, data, _, _ in
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            return try TUNHelperCodec.encodeResponse(TUNHelperResponseEnvelope<StatusResponse>(
                revision: TUNHelperProtocol.revision,
                requestID: request.requestID,
                sessionID: nil,
                payload: nil,
                failure: TUNHelperProtocolFailure(
                    code: .commandFailed,
                    summary: "status failed",
                    details: "bounded details",
                    retryDisposition: .never
                )
            ))
        }
        do {
            _ = try await PrivilegedHelperClient(transport: transport).status()
            XCTFail("Expected structured command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            XCTAssert(summary == "status failed")
            XCTAssert(details == "bounded details")
        }
    }

    func testLostStartReconcilesOnce() async throws {
        let sessionID = UUID()
        let transport = reconciliationTransport(mutating: .startSession, sessionID: sessionID, phase: .running)
        let client = PrivilegedHelperClient(transport: transport)
        _ = try await client.start(session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: sessionID)
        XCTAssert(transport.calls.map(\.0) == [.startSession, .status])
        XCTAssert(transport.invalidations == 1)
    }

    func testLostStopReconcilesOnce() async throws {
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
        XCTAssert(transport.calls.map(\.0) == [.stopSession, .status])
        XCTAssert(transport.invalidations == 1)
    }

    func testFailedReconciliationIsCommandFailure() async throws {
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
            XCTFail("Expected command failure")
        } catch let PrivilegedHelperClientError.commandFailed(summary, details) {
            XCTAssert(summary == "start failed")
            XCTAssert(details == "bounded details")
        }
        XCTAssert(transport.calls.count == 2)
    }

    func testUnavailableAndUnknownReconciliationAreIndeterminate() async throws {
        let unavailableSession = UUID()
        let unavailable = ScriptedTransport { command, _, _, _ in
            if command == .startSession { throw TUNHelperTransportError.interrupted }
            throw TUNHelperTransportError.unavailable("not running")
        }
        try await assertIndeterminate(sessionID: unavailableSession) {
            _ = try await PrivilegedHelperClient(transport: unavailable).start(
                session: launchSession(), paths: XrayTunRuntimePaths(), sessionID: unavailableSession
            )
        }
        XCTAssert(unavailable.calls.map(\.0) == [.startSession, .status])

        let unknownSession = UUID()
        let unknown = reconciliationTransport(mutating: .stopSession, sessionID: unknownSession, phase: .unknown)
        try await assertIndeterminate(sessionID: unknownSession) {
            try await PrivilegedHelperClient(transport: unknown).stop(
                paths: XrayTunRuntimePaths(), protectedHosts: nil, outboundInterface: nil, sessionID: unknownSession
            )
        }
        XCTAssert(unknown.calls.map(\.0) == [.stopSession, .status])
    }

    func testStartCorrelationPersistenceOrderingAndFailureRetention() async throws {
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
            XCTFail("Expected start failure")
        } catch ExpectedFailure.start {}
        XCTAssert(failedEvents == ["persist:nil", "start"])

        var successfulEvents: [String] = []
        let pid = try await XrayTunStartCorrelation.perform(
            persist: { pid in successfulEvents.append("persist:\(pid.map(String.init) ?? "nil")") },
            start: {
                successfulEvents.append("start")
                return 42
            }
        )
        XCTAssert(pid == 42)
        XCTAssert(successfulEvents == ["persist:nil", "start", "persist:42"])
    }

    func testFailedRuntimeStartRollsBackMatchingSession() async throws {
        let paths = try temporaryRuntimePaths(named: "failed-start-rollback")
        defer { removeTemporaryRuntimePaths(paths) }
        let probe = RecoveryProbe()
        let transport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .startSession:
                let request: TUNHelperRequestEnvelope<StartSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                let sessionID = request.sessionID!
                probe.record(sessionID: sessionID)
                return try TUNHelperCodec.encodeResponse(TUNHelperResponseEnvelope<StartSessionResponse>(
                    revision: TUNHelperProtocol.revision,
                    requestID: request.requestID,
                    sessionID: sessionID,
                    payload: nil,
                    failure: TUNHelperProtocolFailure(
                        code: .commandFailed,
                        summary: "start failed",
                        details: "specific protocol failure details",
                        retryDisposition: .never
                    )
                ))
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == probe.sessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: request.sessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            case .readDiagnostics:
                let request: TUNHelperRequestEnvelope<ReadDiagnosticsRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: nil,
                    payload: DiagnosticsResponse(log: request.payload.log, text: "specific \(request.payload.log.rawValue) failure", metadata: "test", wasTruncated: false)
                )
            default:
                XCTFail("Unexpected command: \(command)")
                throw UnexpectedCommand(command: command)
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
            XCTFail("Expected start failure")
        } catch let XrayTunRuntimeError.startFailed(_, details) {
            XCTAssert(details.contains("specific protocol failure details"))
            XCTAssert(details.contains("specific control failure"))
            XCTAssert(details.contains("specific xray failure"))
            XCTAssert(details.contains("specific helper failure"))
        }

        XCTAssert(transport.calls.map(\.0) == [.startSession, .stopSession, .readDiagnostics, .readDiagnostics, .readDiagnostics])
        XCTAssert(!FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
    }

    func testUnavailableRuntimeStopReinstallsAndRetries() async throws {
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
            XCTAssert(command == .stopSession)
            let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
            XCTAssert(request.sessionID == sessionID)
            if index == 0 { throw TUNHelperTransportError.unavailable("not running") }
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

        XCTAssert(probe.installCount == 1)
        XCTAssert(transport.calls.map(\.0) == [.stopSession, .stopSession])
        XCTAssert(!FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
    }

    func testLostXPCStopReplyDoesNotReplayMutation() async throws {
        let sessionID = UUID()
        let mutatingProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: true)
        let statusProxy = LostStopReplyProxy(sessionID: sessionID, losesStopReply: false)
        let factory = LostStopReplyConnectionFactory(connections: [
            LostStopReplyConnection(proxy: mutatingProxy),
            LostStopReplyConnection(proxy: statusProxy)
        ])
        let transport = XPCTUNHelperTransport(connectionFactory: { factory.make() })
        let client = PrivilegedHelperClient(transport: transport)

        try await client.stop(
            paths: XrayTunRuntimePaths(),
            protectedHosts: ["example.com"],
            outboundInterface: "en0",
            sessionID: sessionID
        )

        XCTAssert(mutatingProxy.counts.stop == 1)
        XCTAssert(mutatingProxy.counts.status == 0)
        XCTAssert(statusProxy.counts.stop == 0)
        XCTAssert(statusProxy.counts.status == 1)
    }

    func testRuntimeResolvesMissingSessionWithoutInventingIdentity() async throws {
        let idlePaths = try temporaryRuntimePaths(named: "idle")
        defer { removeTemporaryRuntimePaths(idlePaths) }
        let idleTransport = ScriptedTransport { command, data, _, _ in
            XCTAssert(command == .status)
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
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
        XCTAssert(idleTransport.calls.map(\.0) == [.status, .status])

        let observedSessionID = UUID()
        let runningPaths = try temporaryRuntimePaths(named: "running")
        defer { removeTemporaryRuntimePaths(runningPaths) }
        let runningTransport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == observedSessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            default:
                XCTFail("Unexpected command: \(command)")
                throw UnexpectedCommand(command: command)
            }
        }
        let runningManager = PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: runningTransport),
            paths: runningPaths
        )
        try await runningManager.stop()
        XCTAssert(runningTransport.calls.map(\.0) == [.status, .stopSession])

        let cleanupPaths = try temporaryRuntimePaths(named: "cleanup")
        defer { removeTemporaryRuntimePaths(cleanupPaths) }
        let cleanupTransport = ScriptedTransport { command, data, _, _ in
            switch command {
            case .status:
                let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StatusResponse(helperVersion: "8", phase: .running, summary: nil, details: nil)
                )
            case .stopSession:
                let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
                XCTAssert(request.sessionID == observedSessionID)
                return try response(
                    requestID: request.requestID,
                    sessionID: observedSessionID,
                    payload: StopSessionResponse(phase: .idle, summary: nil, details: nil)
                )
            default:
                XCTFail("Unexpected command: \(command)")
                throw UnexpectedCommand(command: command)
            }
        }
        try await PrivilegedXrayRuntimeManager(
            helperClient: PrivilegedHelperClient(transport: cleanupTransport),
            paths: cleanupPaths
        ).cleanupIfHelperAvailable()
        XCTAssert(cleanupTransport.calls.map(\.0) == [.status, .stopSession])

        let unidentifiedPaths = try temporaryRuntimePaths(named: "unidentified")
        defer { removeTemporaryRuntimePaths(unidentifiedPaths) }
        let unidentifiedTransport = ScriptedTransport { command, data, _, _ in
            XCTAssert(command == .status)
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
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
            XCTFail("Expected an indeterminate unidentified-session failure")
        } catch let XrayTunRuntimeError.stopFailed(summary, _) {
            XCTAssert(summary.localizedCaseInsensitiveContains("session"))
        }
        XCTAssert(unidentifiedTransport.calls.map(\.0) == [.status])

        let cleanupUnidentifiedPaths = try temporaryRuntimePaths(named: "cleanup-unidentified")
        defer { removeTemporaryRuntimePaths(cleanupUnidentifiedPaths) }
        let cleanupUnidentifiedTransport = ScriptedTransport { command, data, _, _ in
            XCTAssert(command == .status)
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
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
            XCTFail("Expected cleanup to report unidentified running state")
        } catch let PrivilegedHelperClientError.indeterminateStatus(summary) {
            XCTAssert(summary.localizedCaseInsensitiveContains("correlation"))
        }
        XCTAssert(cleanupUnidentifiedTransport.calls.map(\.0) == [.status])
    }

    func testInvalidStopResponsePreservesCachedState() async throws {
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
            XCTAssert(command == .stopSession)
            let request: TUNHelperRequestEnvelope<StopSessionRequest> = try TUNHelperCodec.decodeRequest(data)
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
            XCTFail("Expected invalid stop response")
        } catch XrayTunRuntimeError.stopFailed {}
        XCTAssert(FileManager.default.fileExists(atPath: paths.sessionStateFileURL.path))
        XCTAssert(transport.calls.map(\.0) == [.stopSession])
    }

    private func temporaryRuntimePaths(named name: String) throws -> XrayTunRuntimePaths {
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

    private func removeTemporaryRuntimePaths(_ paths: XrayTunRuntimePaths) {
        try? FileManager.default.removeItem(at: paths.sessionStateFileURL.deletingLastPathComponent())
    }

    private func assertInvalidResponse(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            XCTFail("Expected invalid response")
        } catch PrivilegedHelperClientError.invalidResponse {}
    }

    private func reconciliationTransport(
        mutating command: TUNHelperCommand,
        sessionID: UUID,
        phase: TUNHelperSessionPhase,
        summary: String? = nil,
        details: String? = nil,
        transportFailure: TUNHelperTransportError = .deadlineExceeded
    ) -> ScriptedTransport {
        ScriptedTransport { actualCommand, data, _, index in
            XCTAssert(index < 2)
            if actualCommand == command {
                throw transportFailure
            }
            XCTAssert(actualCommand == .status)
            let request: TUNHelperRequestEnvelope<StatusRequest> = try TUNHelperCodec.decodeRequest(data)
            XCTAssert(request.sessionID == nil)
            return try response(
                requestID: request.requestID,
                sessionID: sessionID,
                payload: StatusResponse(helperVersion: "8", phase: phase, summary: summary, details: details)
            )
        }
    }

    private func assertIndeterminate(sessionID: UUID, operation: () async throws -> Void) async throws {
        do {
            try await operation()
            XCTFail("Expected indeterminate result")
        } catch let PrivilegedHelperClientError.indeterminate(requestID, actualSessionID, _) {
            XCTAssert(requestID != UUID())
            XCTAssert(actualSessionID == sessionID)
        }
    }

    private func launchSession() -> XrayTunLaunchSession {
        XrayTunLaunchSession(
            configData: Data("{}".utf8),
            protectedHosts: ["example.com"],
            tunnelInterfaceName: "utun9",
            outboundInterface: "en0"
        )
    }
}

private nonisolated final class ProxyRestoreProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true

    func allowRestoration() { lock.withLock { fails = false } }

    func run(_ process: Process) throws {
        if lock.withLock({ fails }) {
            throw NSError(domain: "TeleportTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic proxy restore failure"])
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = ["An asterisk denotes a disabled network service.\n"]
        try process.run()
    }
}

private final class ReconnectFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private nonisolated final class ReconnectDNSProbe: @unchecked Sendable {
    enum Reached: Error { case helperPreparation }
    private let lock = NSLock()
    private var stopped = false
    private var recordedEvents: [String] = []
    private let availableBeforeStop: Bool
    init(availableBeforeStop: Bool) { self.availableBeforeStop = availableBeforeStop }
    var events: [String] { lock.withLock { recordedEvents } }
    func stopTunnel() { lock.withLock { stopped = true; recordedEvents.append("stop") } }
    func command(_ executable: String, _ arguments: [String]) -> String? {
        lock.withLock {
            if executable.hasSuffix("dscacheutil") {
                recordedEvents.append("resolve")
                return (stopped != availableBeforeStop) ? "ip_address: 192.0.2.2\n" : nil
            }
            return "interface: en0\n"
        }
    }
}

private func response<Payload>(
    requestID: UUID,
    sessionID: UUID?,
    payload: Payload
) throws -> Data where Payload: Codable & Sendable & Equatable {
    try TUNHelperCodec.encodeResponse(TUNHelperResponseEnvelope(
        revision: TUNHelperProtocol.revision,
        requestID: requestID,
        sessionID: sessionID,
        payload: payload,
        failure: nil
    ))
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
