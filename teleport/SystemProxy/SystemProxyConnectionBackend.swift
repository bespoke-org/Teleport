import Foundation

/// System Proxy mode: an unprivileged Xray process plus macOS proxy settings.
/// Split-tunnel policy is deliberately unused here — routing decisions belong to
/// Xray's TUN inbound, which only VPN mode runs.
final class SystemProxyConnectionBackend: ConnectionBackend, @unchecked Sendable {
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

    func restorePreviousState() async throws {
        try await BlockingWork.run { [self] in
            try proxyService.restoreSavedProxyState()
        }
    }

    func start(_ request: ConnectionRequest) async throws {
        do {
            try await vpnRuntimeManager?.cleanupIfHelperAvailable(protectedHost: request.configuration.host)
            try await startRuntime(request)
            try await BlockingWork.run { [self] in
                try proxyService.enableProxy(endpoint: request.localProxy)
            }
        } catch {
            await rollBack()
            throw error
        }
    }

    func reconnect(_ request: ConnectionRequest) async throws {
        do {
            try await BlockingWork.run { [self] in
                try proxyService.disableProxy()
                runtimeManager.stop()
            }
            try await vpnRuntimeManager?.cleanupIfHelperAvailable(protectedHost: request.configuration.host)
            try await startRuntime(request)
            try await BlockingWork.run { [self] in
                try proxyService.enableProxy(endpoint: request.localProxy)
            }
        } catch {
            await rollBack()
            throw error
        }
    }

    func stop() async throws {
        try await BlockingWork.run { [self] in
            var disableError: Error?
            do {
                try proxyService.disableProxy()
            } catch {
                disableError = error
            }

            runtimeManager.stop()

            if let disableError {
                throw disableError
            }
        }
    }

    private func rollBack() async {
        await BlockingWork.run { [self] in
            runtimeManager.stop()
            try? proxyService.restoreSavedProxyState()
        }
    }

    private func startRuntime(_ request: ConnectionRequest) async throws {
        // Writing the config and spawning Xray block; waiting for its local ports to
        // accept connections no longer does.
        try await BlockingWork.run { [self] in
            let configURL = try XrayConfigurationWriter(proxyEndpoint: request.localProxy)
                .writeConfig(for: request.configuration)
            try runtimeManager.start(configURL: configURL)
        }
        guard await runtimeManager.waitUntilLocalProxyReady(endpoint: request.localProxy) else {
            let detail = runtimeManager.capturedErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
        }
    }
}
