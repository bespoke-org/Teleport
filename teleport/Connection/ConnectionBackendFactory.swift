import Foundation

/// Selects the orchestration strategy. System Proxy runs Xray as the user and
/// changes macOS proxy settings; VPN delegates root Xray and route ownership to
/// the privileged-helper path.
struct ConnectionBackendFactory {
    func makeBackend(for mode: ConnectionMode) -> ConnectionBackend {
        switch mode {
        case .systemProxy:
            return SystemProxyConnectionBackend(
                runtimeManager: XrayRuntimeManager(),
                proxyService: SystemProxyService()
            )
        case .vpn:
            return XrayTunConnectionBackend(
                runtimeManager: PrivilegedXrayRuntimeManager(),
                routeInspector: XrayTunRouteInspector(),
                systemProxyService: SystemProxyService()
            )
        }
    }
}
