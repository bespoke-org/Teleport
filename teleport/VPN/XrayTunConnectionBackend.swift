import Foundation

/// Coordinates the user-visible VPN transaction around the lower-level runtime:
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

    /// The reachable numeric address of one server and the physical interface
    /// that reaches it.
    private func protectedRoute(for configuration: ConnectionConfiguration) throws -> (address: String, interface: String) {
        let resolvedAddresses = routeInspector.resolvedAddresses(for: configuration.host)
        guard !resolvedAddresses.isEmpty else {
            throw XrayTunConnectionError.proxyAddressResolutionFailed(configuration.host)
        }
        guard let route = resolvedAddresses.lazy.compactMap({ address -> (String, String)? in
            guard let interface = self.routeInspector.outboundInterface(for: address) else { return nil }
            return (address, interface)
        }).first else {
            throw XrayTunConnectionError.proxyRouteUnavailable(configuration.host)
        }
        return route
    }

    func hasRestorableState() -> Bool { false }

    func hasActiveRuntimeSession() async -> Bool {
        await runtimeManager.isRunning()
    }

    func restorePreviousState() throws {}

    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
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
                let (defaultAddress, outboundInterface) = try self.protectedRoute(for: request.defaultConnection.configuration)
                try cancellation.check()
                var outbounds = [RoutedProxyOutbound(
                    connectionID: request.defaultConnection.id,
                    configuration: request.defaultConnection.configuration,
                    serverAddress: defaultAddress
                )]
                var protectedHosts = [defaultAddress]
                // An additional connection that cannot be routed fails the whole start:
                // its rules would otherwise fall back to the default outbound without
                // the user being told their traffic went somewhere else.
                for connection in request.additionalConnections {
                    let (address, _) = try self.protectedRoute(for: connection.configuration)
                    try cancellation.check()
                    outbounds.append(RoutedProxyOutbound(
                        connectionID: connection.id,
                        configuration: connection.configuration,
                        serverAddress: address
                    ))
                    if !protectedHosts.contains(address) {
                        protectedHosts.append(address)
                    }
                }

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
            try systemProxyService.suspendProxyForVPN()
        }

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
            try? await runtimeManager.stop()
            try? await BlockingWork.run { [systemProxyService] in
                try systemProxyService.restoreSavedProxyState()
            }
            throw error
        }
    }

    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try await runtimeManager.stop()
        do {
            try await start(request, reportPhase: reportPhase)
        } catch is CancellationError {
            // The old tunnel is already gone and its proxy snapshot still held, so
            // a cancelled pre-flight here has something to put back after all.
            try? await BlockingWork.run { [systemProxyService] in
                try systemProxyService.restoreSavedProxyState()
            }
            throw CancellationError()
        }
    }

    func stop() async throws {
        try await runtimeManager.stop()
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.restoreSavedProxyState()
        }
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

enum XrayTunConnectionError: LocalizedError {
    case existingVPNDetected(String)
    case proxyAddressResolutionFailed(String)
    case proxyRouteUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .existingVPNDetected(interface):
            return "Another VPN appears to be active on \(interface). Disconnect it before using Teleport VPN mode, or use System Proxy mode."
        case let .proxyAddressResolutionFailed(host):
            return "Teleport could not resolve the proxy server \(host) before installing VPN routes. Check the network and try again."
        case let .proxyRouteUnavailable(host):
            return "Teleport could not find a reachable physical route to the proxy server \(host). Reconnect to the network and try again."
        }
    }
}
