import Foundation

/// Provider facade for app-side orchestration of the current root-Xray VPN path.
struct RootXrayConnectionProvider: ConnectionProvider, Sendable {
    private let coordinator: BackendConnectionProvider

    init(coordinator: BackendConnectionProvider) {
        self.coordinator = coordinator
    }

    init(leakGuard: LeakGuardService) {
        coordinator = BackendConnectionProvider(
            mode: .vpn,
            backend: XrayTunConnectionBackend(
                runtimeManager: PrivilegedXrayRuntimeManager(),
                routeInspector: XrayTunRouteInspector(),
                systemProxyService: SystemProxyService(),
                leakGuard: leakGuard
            )
        )
    }

    func currentState() async -> ConnectionState {
        await coordinator.currentState()
    }

    func stateUpdates() -> AsyncStream<ConnectionState> {
        coordinator.stateUpdates()
    }

    func connect(_ request: ConnectionRequest) async throws {
        try await coordinator.connect(request)
    }

    func disconnect() async throws {
        try await coordinator.disconnect()
    }
}
