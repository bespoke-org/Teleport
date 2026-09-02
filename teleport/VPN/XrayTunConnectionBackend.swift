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

    func hasActiveRuntimeSession() -> Bool {
        runtimeManager.isRunning()
    }

    func restorePreviousState() throws {}

    // TODO(gpt-5.6-sol): Add an explicit rollback/reconciliation path around the
    // entire VPN start transaction. A thrown IPC error is not proof that root-side
    // start failed, yet this backend currently reports failure without attempting
    // to adopt or stop a possibly active helper session.
    func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
        if let existingVPNInterface = routeInspector.existingVPNDefaultRouteInterface() {
            throw XrayTunConnectionError.existingVPNDetected(existingVPNInterface)
        }

        try systemProxyService.disableProxy()

        // Prefer the interface used to reach the proxy server; fall back to the
        // current default-route interface so split-tunnel "direct" traffic can be
        // bound to a real uplink on any host/network, not just when the per-host
        // lookup happens to succeed.
        let outboundInterface = routeInspector.outboundInterface(for: configuration.host)
            ?? routeInspector.defaultRouteInterface()
            ?? "auto"
        let directSendThrough = routeInspector.ipv4Address(for: outboundInterface)
        let tunnelInterfaceName = routeInspector.nextAvailableTunnelInterfaceName()
        let configData = try XrayConfigurationWriter(proxyEndpoint: endpoint).tunnelConfigData(
            for: configuration,
            interfaceName: tunnelInterfaceName,
            outboundInterface: outboundInterface,
            directSendThrough: directSendThrough,
            splitTunnelRules: splitTunnelRules,
            defaultAction: splitTunnelDefaultAction
        )
        try runtimeManager.start(
            session: XrayTunLaunchSession(
                configData: configData,
                protectedHost: configuration.host,
                tunnelInterfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface
            )
        )
        // The helper's `start` response already follows TUN and route readiness;
        // this final check only consults the app's cached PID and is not an
        // authoritative helper health check.
        guard runtimeManager.waitUntilRunning() else {
            let detail = runtimeManager.capturedLogOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
        }
    }

    func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
        _ = shouldDisableExistingProxy
        try stop(shouldDisableProxy: false)
        try start(configuration: configuration, endpoint: endpoint, splitTunnelRules: splitTunnelRules, splitTunnelDefaultAction: splitTunnelDefaultAction)
    }

    func stop(shouldDisableProxy: Bool) throws {
        _ = shouldDisableProxy
        try runtimeManager.stop()
    }

    func teardown() {
        runtimeManager.teardown()
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
