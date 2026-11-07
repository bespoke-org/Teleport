import Foundation

/// Coordinates the user-visible TUN transaction around the lower-level runtime:
/// reject obvious VPN conflicts, disable System Proxy, derive the physical uplink,
/// build Xray JSON, and ask the privileged runtime to start or stop the session.
final class XrayTunConnectionBackend: ConnectionBackend, @unchecked Sendable {
    private let runtimeManager: PrivilegedXrayRuntimeManager
    private let routeInspector: XrayTunRouteInspector
    private let systemProxyService: SystemProxyService
    private let leakGuard: LeakGuardService

    init(
        runtimeManager: PrivilegedXrayRuntimeManager,
        routeInspector: XrayTunRouteInspector,
        systemProxyService: SystemProxyService,
        leakGuard: LeakGuardService
    ) {
        self.runtimeManager = runtimeManager
        self.routeInspector = routeInspector
        self.systemProxyService = systemProxyService
        self.leakGuard = leakGuard
    }

    func hasRestorableState() -> Bool { false }

    func hasActiveRuntimeSession() async -> Bool {
        await runtimeManager.isRunning()
    }

    func adoptRuntimeSession() async throws {
        try await BlockingWork.run { [systemProxyService] in try systemProxyService.resumeMonitoringIfNeeded() }
    }

    func sessionFailure() async -> ConnectionFailure? {
        await BlockingWork.run { [systemProxyService] in systemProxyService.checkForConflict() }
    }

    func sessionChanges() -> AsyncStream<Void> { systemProxyService.changes() }

    func restorePreviousState() throws {}

    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try await start(request, resolvedEndpoints: [:], reportPhase: reportPhase)
    }

    private func start(_ request: ConnectionRequest, resolvedEndpoints: [String: [String]],
                       reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try await BlockingWork.run { [systemProxyService] in try systemProxyService.prepareForTakeover() }
        do {
            try await startPrepared(request, resolvedEndpoints: resolvedEndpoints, reportPhase: reportPhase)
        } catch {
            let primary = error
            do {
                try await BlockingWork.run { [systemProxyService] in try systemProxyService.rollbackIfActive() }
            } catch {
                let cleanup = ConnectionFailure(error: error)
                throw ConnectionFailure(summary: cleanup.requiresExplicitReconnect ? cleanup.summary : primary.localizedDescription,
                                        details: "Proxy recovery: \(cleanup.details ?? cleanup.summary)",
                                        requiresExplicitReconnect: cleanup.requiresExplicitReconnect)
            }
            throw primary
        }
    }

    private func startPrepared(_ request: ConnectionRequest, resolvedEndpoints: [String: [String]], reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        // The pre-flight below reads routes and resolves names but changes nothing
        // on the machine, so a disconnect or quit that arrives meanwhile may cancel
        // it. The blocking work runs on a dispatch queue where task cancellation is
        // invisible, hence the flag it polls between steps.
        let cancellation = CancellationFlag()
        let session = try await withTaskCancellationHandler {
            try await BlockingWork.run { [self] () -> XrayTunLaunchSession in
                try cancellation.check()
                if let existingVPNInterface = routeInspector.existingVPNDefaultRouteInterface() {
                    throw XrayTunConnectionError.existingVPNDetected(existingVPNInterface)
                }
                try cancellation.check()

                // Every connection in the session is pinned to the same reachable
                // numeric endpoint that receives its protected physical route. This
                // avoids a second DNS answer selecting a different address after the
                // TUN defaults have been installed. The uplink comes from the default
                // connection's route, as it did when a session had only one server.
                var outbounds: [RoutedProxyOutbound] = []
                var protectedHosts: [String] = []
                var outboundInterface = ""
                for connection in [request.defaultConnection] + request.additionalConnections {
                    let prepared = try RoutedProxyOutbound.resolve(connectionID: connection.id, configuration: connection.configuration) { host in
                        try cancellation.check()
                        return try self.routeInspector.protectedRoute(for: host, resolvedAddresses: resolvedEndpoints[host])
                    }
                    if outbounds.isEmpty { outboundInterface = prepared.interface }
                    outbounds.append(prepared.outbound)
                    if !prepared.outbound.unavailableMemberHosts.isEmpty {
                        TeleportLog.shared.warn("tun", "auto-selection portal: \(prepared.outbound.unavailableMemberHosts.count) member hosts unavailable on this uplink; using \(prepared.outbound.memberAddresses.count) reachable hosts for this session")
                    }
                    for address in prepared.outbound.memberAddresses.values.sorted() where !protectedHosts.contains(address) {
                        protectedHosts.append(address)
                    }
                }
                try cancellation.check()

                let directSendThrough = routeInspector.ipv4Address(for: outboundInterface)
                let tunnelInterfaceName = routeInspector.nextAvailableTunnelInterfaceName()
                let configData = try XrayConfigurationWriter(proxyEndpoint: request.localProxy).tunnelConfigData(
                    for: outbounds,
                    interfaceName: tunnelInterfaceName,
                    outboundInterface: outboundInterface,
                    directSendThrough: directSendThrough,
                    splitTunnelRules: request.splitTunnelPolicy.rules,
                    defaultAction: request.splitTunnelPolicy.defaultAction,
                    dnsPolicy: TunnelDNSPolicy(
                        localResolvers: SystemResolverInventory.nameservers(),
                        ipv6Enabled: routeInspector.hasGlobalIPv6(on: outboundInterface)
                    )
                )
                return XrayTunLaunchSession(
                    configData: configData,
                    protectedHosts: protectedHosts,
                    tunnelInterfaceName: tunnelInterfaceName,
                    outboundInterface: outboundInterface
                )
            }
        } onCancel: {
            cancellation.cancel()
        }

        // Still before the commit point: an installed helper is not session state
        // and needs no undoing, and the administrator prompt it may put up is a
        // wait the user can cancel out of. After the route checks, so a network
        // that cannot reach the server does not ask for a password first.
        try Task.checkCancellation()
        try await runtimeManager.prepareHelper {
            reportPhase(.awaitingUserApproval)
        }
        reportPhase(.connecting)

        // The commit point. Past this line the operation runs to the end whatever
        // happens to its task: proxies, guard, and tunnel must be either all up or
        // all put back, and the catch below does the putting back.
        try Task.checkCancellation()
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.suspendProxyForTUN()
        }
        reportPhase(.connecting)

        do {
            // Before the tunnel, not after: between here and the TUN existing there
            // is nothing to route through, and this is the window the guard covers.
            // The tunnel it is about to allow is named now because the interface is
            // chosen here, so the guard never has to be widened afterwards.
            if request.usesLeakGuard {
                try await leakGuard.armForSession(
                    tunnelInterface: session.tunnelInterfaceName,
                    protectedHosts: session.protectedHosts
                )
            }
            try await runtimeManager.start(session: session)
            // The helper's `start` response already follows TUN and route readiness;
            // this final check only consults the app's cached PID and is not an
            // authoritative helper health check.
            guard await runtimeManager.waitUntilRunning() else {
                let detail = await runtimeManager.capturedLogOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
            }
        } catch {
            throw await recoveringFrom(error)
        }
    }

    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        // The running tunnel owns the system's preferred resolver. Resolve the
        // next endpoints while that resolver can still answer, then retain those
        // answers for this attempt. macOS may keep querying the old resolver
        // briefly after the helper removes it. Routes must still be inspected
        // after teardown so none of the old tunnel's routes are reused.
        let cancellation = CancellationFlag()
        let resolvedEndpoints = await withTaskCancellationHandler {
            await BlockingWork.run { [routeInspector] in
                var answers: [String: [String]] = [:]
                var seen: Set<String> = []
                // A broken old tunnel must not add one DNS timeout per member
                // before we can stop it. Missing answers retry after teardown.
                let deadline = ContinuousClock.now + .seconds(5)
                for connection in request.connections {
                    for endpoint in connection.configuration.endpointConfigurations where seen.insert(endpoint.host).inserted {
                        do { try cancellation.check() } catch { return answers }
                        guard ContinuousClock.now < deadline else { return answers }
                        let addresses = routeInspector.resolvedAddresses(for: endpoint.host)
                        if !addresses.isEmpty { answers[endpoint.host] = addresses }
                    }
                }
                return answers
            }
        } onCancel: {
            cancellation.cancel()
        }
        try await BlockingWork.run { [systemProxyService] in try systemProxyService.reserveForStop() }
        try await runtimeManager.stop()
        // start also restores held proxy settings if replacement pre-flight fails.
        try await start(request, resolvedEndpoints: resolvedEndpoints, reportPhase: reportPhase)
    }

    private func recoveringFrom(_ primary: Error) async -> Error {
        do { try await stop() } catch {
            let cleanup = ConnectionFailure(error: error)
            let failure = ConnectionFailure(error: primary)
            return ConnectionFailure(
                summary: cleanup.requiresExplicitReconnect ? cleanup.summary : failure.summary,
                details: [failure.details, "Cleanup: \(cleanup.details ?? cleanup.summary)"].compactMap { $0 }.joined(separator: "\n"),
                requiresExplicitReconnect: failure.requiresExplicitReconnect || cleanup.requiresExplicitReconnect)
        }
        return primary
    }

    func stop() async throws {
        try await BlockingWork.run { [systemProxyService] in try systemProxyService.reserveForStop() }
        var runtimeError: Error?
        do { try await runtimeManager.stop() } catch { runtimeError = error }
        do {
            try await BlockingWork.run { [systemProxyService] in
                try systemProxyService.restoreSavedProxyState()
            }
        } catch {
            if let runtimeError {
                let failure = ConnectionFailure(error: error)
                throw ConnectionFailure(
                    summary: failure.summary,
                    details: [failure.details, "Tunnel cleanup also failed: \(runtimeError.localizedDescription)"].compactMap { $0 }.joined(separator: "\n"),
                    requiresExplicitReconnect: failure.requiresExplicitReconnect)
            }
            throw error
        }
        if let runtimeError { throw runtimeError }
    }
}

/// Carries task cancellation into blocking work that runs outside the task.
nonisolated private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock(); isCancelled = true; lock.unlock()
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
    }
}

nonisolated enum XrayTunConnectionError: LocalizedError {
    case existingVPNDetected(String)
    case proxyAddressResolutionFailed(String)
    case proxyRouteUnavailable(String)
    case proxyIPv6RouteUnavailable(String)
    case noReachableGroupMembers(dnsFailures: Int, ipv6RouteFailures: Int, routeFailures: Int)

    var errorDescription: String? {
        switch self {
        case let .existingVPNDetected(interface):
            return "Another VPN appears to be active on \(interface). Disconnect it before using Teleport TUN mode, or use System Proxy mode."
        case let .proxyAddressResolutionFailed(host):
            return "DNS lookup failed for proxy server \(host). Check the network and try again."
        case let .proxyIPv6RouteUnavailable(host):
            return "IPv6 route unavailable for proxy server \(host). The available server addresses are IPv6-only, but this network has no route to them. Use a network with IPv6 connectivity or choose another portal."
        case .noReachableGroupMembers:
            return "No eligible server in this group is reachable on the current network. Check the network or choose another portal."
        case let .proxyRouteUnavailable(host):
            return "No physical route to proxy server \(host). Reconnect to the network and try again."
        }
    }
}

// Counts describe only members eligible for selection or fallback, excluding
// unused provider outbounds. Keep endpoints out of the aggregate diagnosis.
extension XrayTunConnectionError {
    var failureReason: String? {
        guard case let .noReachableGroupMembers(dns, ipv6, route) = self else { return nil }
        return [
            dns > 0 ? "DNS lookup failures: \(dns)." : nil,
            ipv6 > 0 ? "IPv6 route failures: \(ipv6)." : nil,
            route > 0 ? "Physical route failures: \(route)." : nil
        ].compactMap { $0 }.joined(separator: " ")
    }
}
