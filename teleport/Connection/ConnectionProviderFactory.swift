import Foundation

/// Selects the provider boundary consumed by upper application layers.
struct ConnectionProviderFactory: Sendable {
    private let systemProxyProvider: @Sendable () -> any ConnectionProvider
    private let tunProvider: @Sendable () -> any ConnectionProvider

    /// The leak guard outlives any one provider — it is held across the teardown
    /// and rebuild a provider swap consists of — so it is handed in rather than
    /// created per provider.
    init(
        leakGuard: LeakGuardService = LeakGuardService(),
        proxyService: SystemProxyService = .shared,
        systemProxyProvider: (@Sendable () -> any ConnectionProvider)? = nil,
        tunProvider: (@Sendable () -> any ConnectionProvider)? = nil
    ) {
        let tunProvider = tunProvider ?? { RootXrayConnectionProvider(leakGuard: leakGuard, proxyService: proxyService) }
        self.systemProxyProvider = systemProxyProvider ?? { SystemProxyConnectionProvider(proxyService: proxyService) }
        self.tunProvider = tunProvider
    }

    func makeProvider(for mode: ConnectionMode) -> any ConnectionProvider {
        switch mode {
        case .systemProxy:
            return systemProxyProvider()
        case .tun:
            return tunProvider()
        }
    }
}
