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

    // TODO(gpt-5.6-sol): Add an explicit rollback/reconciliation path around the
    // entire VPN start transaction. A thrown IPC error is not proof that root-side
    // start failed, yet this backend currently reports failure without attempting
    // to adopt or stop a possibly active helper session.
    func start(_ request: ConnectionRequest) async throws {
        // Route inspection and `networksetup` are blocking process calls; only the
        // helper handshake below is genuinely asynchronous.
        let session = try await BlockingWork.run { [self] () -> XrayTunLaunchSession in
            if let existingVPNInterface = routeInspector.existingVPNDefaultRouteInterface() {
                throw XrayTunConnectionError.existingVPNDetected(existingVPNInterface)
            }

            try systemProxyService.disableProxy()

            let configuration = request.configuration

            // Prefer the interface used to reach the proxy server; fall back to the
            // current default-route interface so split-tunnel "direct" traffic can be
            // bound to a real uplink on any host/network, not just when the per-host
            // lookup happens to succeed.
            let outboundInterface = routeInspector.outboundInterface(for: configuration.host)
                ?? routeInspector.defaultRouteInterface()
                ?? "auto"
            let directSendThrough = routeInspector.ipv4Address(for: outboundInterface)
            let tunnelInterfaceName = routeInspector.nextAvailableTunnelInterfaceName()
            let configData = try XrayConfigurationWriter(proxyEndpoint: request.localProxy).tunnelConfigData(
                for: configuration,
                interfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface,
                directSendThrough: directSendThrough,
                splitTunnelRules: request.splitTunnelPolicy.rules,
                defaultAction: request.splitTunnelPolicy.defaultAction
            )
            return XrayTunLaunchSession(
                configData: configData,
                protectedHost: configuration.host,
                tunnelInterfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface
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
    }

    func reconnect(_ request: ConnectionRequest) async throws {
        try await runtimeManager.stop()
        try await start(request)
    }

    func stop() async throws {
        try await runtimeManager.stop()
    }
}

enum XrayTunConnectionError: LocalizedError {
    case existingVPNDetected(String)

    var errorDescription: String? {
        switch self {
        case let .existingVPNDetected(interface):
            return "Another VPN appears to be active on \(interface). Disconnect it before using Teleport VPN mode, or use System Proxy mode."
        }
    }
}
