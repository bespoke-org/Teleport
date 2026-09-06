import Foundation

/// Coordinates the user-visible VPN transaction around the lower-level runtime:
/// reject obvious VPN conflicts, disable System Proxy, derive the physical uplink,
/// build Xray JSON, and ask the privileged runtime to start or stop the session.
final class XrayTunConnectionBackend: ConnectionBackend, @unchecked Sendable {
    private let runtimeManager: PrivilegedXrayRuntimeManager
    private let routeInspector: XrayTunRouteInspector
    private let systemProxyService: SystemProxyService

    init(runtimeManager: PrivilegedXrayRuntimeManager, routeInspector: XrayTunRouteInspector, systemProxyService: SystemProxyService) {
        self.runtimeManager = runtimeManager
        self.routeInspector = routeInspector
        self.systemProxyService = systemProxyService
    }

    func hasRestorableState() -> Bool { false }

    func hasActiveRuntimeSession() async -> Bool {
        await runtimeManager.isRunning()
    }

    func restorePreviousState() throws {}

    func start(_ request: ConnectionRequest) async throws {
        // Route inspection and `networksetup` are blocking process calls; only the
        // helper handshake below is genuinely asynchronous.
        let session = try await BlockingWork.run { [self] () -> XrayTunLaunchSession in
            if let existingVPNInterface = routeInspector.existingVPNDefaultRouteInterface() {
                throw XrayTunConnectionError.existingVPNDetected(existingVPNInterface)
            }

            let configuration = request.configuration
            let resolvedAddresses = routeInspector.resolvedAddresses(for: configuration.host)
            guard !resolvedAddresses.isEmpty else {
                throw XrayTunConnectionError.proxyAddressResolutionFailed(configuration.host)
            }
            guard let protectedRoute = resolvedAddresses.lazy.compactMap({ address -> (String, String)? in
                guard let interface = self.routeInspector.outboundInterface(for: address) else { return nil }
                return (address, interface)
            }).first else {
                throw XrayTunConnectionError.proxyRouteUnavailable(configuration.host)
            }
            let (protectedAddress, outboundInterface) = protectedRoute

            // Pin Xray to the same reachable numeric endpoint that receives the
            // protected physical route. This avoids a second DNS answer selecting a
            // different address after the TUN defaults have been installed.
            let directSendThrough = routeInspector.ipv4Address(for: outboundInterface)
            let tunnelInterfaceName = routeInspector.nextAvailableTunnelInterfaceName()
            let configData = try XrayConfigurationWriter(proxyEndpoint: request.localProxy).tunnelConfigData(
                for: configuration,
                interfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface,
                directSendThrough: directSendThrough,
                proxyServerAddress: protectedAddress,
                splitTunnelRules: request.splitTunnelPolicy.rules,
                defaultAction: request.splitTunnelPolicy.defaultAction,
                dnsPolicy: TunnelDNSPolicy(
                    localResolvers: SystemResolverInventory.nameservers(),
                    ipv6Enabled: routeInspector.hasGlobalIPv6(on: outboundInterface)
                )
            )
            try systemProxyService.suspendProxyForVPN()
            return XrayTunLaunchSession(
                configData: configData,
                protectedHost: protectedAddress,
                tunnelInterfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface
            )
        }

        do {
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

    func reconnect(_ request: ConnectionRequest) async throws {
        try await runtimeManager.stop()
        try await start(request)
    }

    func stop() async throws {
        try await runtimeManager.stop()
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.restoreSavedProxyState()
        }
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
