import Foundation

final class SystemProxyConnectionBackend: ConnectionBackend {
    private let runtimeManager: XrayRuntimeManager
    private let proxyService: SystemProxyService
    private let vpnRuntimeManager: PrivilegedXrayRuntimeManager?

    init(
        runtimeManager: XrayRuntimeManager,
        proxyService: SystemProxyService,
        vpnRuntimeManager: PrivilegedXrayRuntimeManager? = PrivilegedXrayRuntimeManager()
    ) {
        self.runtimeManager = runtimeManager
        self.proxyService = proxyService
        self.vpnRuntimeManager = vpnRuntimeManager
    }

    func hasRestorableState() -> Bool {
        proxyService.hasSavedProxySnapshot()
    }

    func hasActiveRuntimeSession() -> Bool {
        runtimeManager.isRunning
    }

    func restorePreviousState() throws {
        try proxyService.restoreSavedProxyState()
    }

    func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
        _ = splitTunnelRules
        _ = splitTunnelDefaultAction
        do {
            vpnRuntimeManager?.cleanupIfHelperAvailable(protectedHost: configuration.host)
            try startRuntime(configuration: configuration, endpoint: endpoint)
            try proxyService.enableProxy(endpoint: endpoint)
        } catch {
            runtimeManager.stop()
            try? proxyService.restoreSavedProxyState()
            throw error
        }
    }

    func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws {
        _ = splitTunnelRules
        _ = splitTunnelDefaultAction
        do {
            if shouldDisableExistingProxy {
                try proxyService.disableProxy()
            }

            runtimeManager.stop()
            vpnRuntimeManager?.cleanupIfHelperAvailable(protectedHost: configuration.host)
            try startRuntime(configuration: configuration, endpoint: endpoint)
            try proxyService.enableProxy(endpoint: endpoint)
        } catch {
            runtimeManager.stop()
            try? proxyService.restoreSavedProxyState()
            throw error
        }
    }

    func stop(shouldDisableProxy: Bool) throws {
        var disableError: Error?

        if shouldDisableProxy {
            do {
                try proxyService.disableProxy()
            } catch {
                disableError = error
            }
        }

        runtimeManager.stop()

        if let disableError {
            throw disableError
        }
    }

    func teardown() {
        runtimeManager.stop()
        try? proxyService.restoreSavedProxyState()
    }

    private func startRuntime(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint) throws {
        let configURL = try XrayConfigurationWriter(proxyEndpoint: endpoint).writeConfig(for: configuration)
        try runtimeManager.start(configURL: configURL)
        guard runtimeManager.waitUntilLocalProxyReady(endpoint: endpoint) else {
            let detail = runtimeManager.capturedErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
        }
    }
}
