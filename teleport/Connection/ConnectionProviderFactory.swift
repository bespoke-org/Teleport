import Foundation

/// Selects the provider boundary consumed by upper application layers.
struct ConnectionProviderFactory: Sendable {
    private let systemProxyProvider: @Sendable () -> any ConnectionProvider
    private let vpnProvider: @Sendable () -> any ConnectionProvider

    /// The leak guard outlives any one provider — it is held across the teardown
    /// and rebuild a provider swap consists of — so it is handed in rather than
    /// created per provider.
    init(
        leakGuard: LeakGuardService = LeakGuardService(),
        systemProxyProvider: @escaping @Sendable () -> any ConnectionProvider = { SystemProxyConnectionProvider() },
        vpnProvider: (@Sendable () -> any ConnectionProvider)? = nil
    ) {
        let vpnProvider = vpnProvider ?? { RootXrayConnectionProvider(leakGuard: leakGuard) }
        self.systemProxyProvider = systemProxyProvider
        self.vpnProvider = vpnProvider
    }

    func makeProvider(for mode: ConnectionMode) -> any ConnectionProvider {
        switch mode {
        case .systemProxy:
            return systemProxyProvider()
        case .vpn:
            return vpnProvider()
        }
    }
}
