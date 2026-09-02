import Foundation

/// Selects the provider boundary consumed by upper application layers.
struct ConnectionProviderFactory: Sendable {
    private let systemProxyProvider: @Sendable () -> any ConnectionProvider
    private let vpnProvider: @Sendable () -> any ConnectionProvider

    init(
        systemProxyProvider: @escaping @Sendable () -> any ConnectionProvider = { SystemProxyConnectionProvider() },
        vpnProvider: @escaping @Sendable () -> any ConnectionProvider = { RootXrayConnectionProvider() }
    ) {
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
