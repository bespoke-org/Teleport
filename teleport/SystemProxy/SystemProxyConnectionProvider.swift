import Foundation

/// Provider facade for the unprivileged Xray process and macOS System Proxy path.
struct SystemProxyConnectionProvider: ConnectionProvider, Sendable {
    private let coordinator: BackendConnectionProvider

    init(coordinator: BackendConnectionProvider) {
        self.coordinator = coordinator
    }

    init() {
        coordinator = BackendConnectionProvider(
            mode: .systemProxy,
            backend: SystemProxyConnectionBackend(
                runtimeManager: XrayRuntimeManager(),
                proxyService: SystemProxyService()
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
