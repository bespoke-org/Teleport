import Foundation

/// System Proxy mode: an unprivileged Xray process plus macOS proxy settings.
/// Split-tunnel policy is deliberately unused here — routing decisions belong to
/// Xray's TUN inbound, which only TUN mode runs.
final class SystemProxyConnectionBackend: ConnectionBackend, @unchecked Sendable {
    private let runtimeManager: XrayRuntimeManager
    private let proxyService: SystemProxyService
    private let tunRuntimeManager: PrivilegedXrayRuntimeManager?

    init(
        runtimeManager: XrayRuntimeManager,
        proxyService: SystemProxyService,
        tunRuntimeManager: PrivilegedXrayRuntimeManager? = PrivilegedXrayRuntimeManager()
    ) {
        self.runtimeManager = runtimeManager
        self.proxyService = proxyService
        self.tunRuntimeManager = tunRuntimeManager
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

    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try Task.checkCancellation()
        do {
            try await tunRuntimeManager?.cleanupIfHelperAvailable(protectedHosts: [request.configuration.host])
            try await startRuntime(request)
            try Task.checkCancellation()
            try await BlockingWork.run { [self] in
                try proxyService.enableProxy(endpoint: request.localProxy)
            }
        } catch {
            await rollBack()
            throw error
        }
    }

    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        do {
            try await BlockingWork.run { [self] in
                try proxyService.disableProxy()
                runtimeManager.stop()
            }
            try Task.checkCancellation()
            try await tunRuntimeManager?.cleanupIfHelperAvailable(protectedHosts: [request.configuration.host])
            try await startRuntime(request)
            try Task.checkCancellation()
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
        try Task.checkCancellation()
        // Writing the config and spawning Xray block; waiting for its local ports to
        // accept connections no longer does.
        try await BlockingWork.run { [self] in
            let configURL = try XrayConfigurationWriter(proxyEndpoint: request.localProxy)
                .writeConfig(for: request.configuration)
            try runtimeManager.start(configURL: configURL)
        }
        let isReady = await runtimeManager.waitUntilLocalProxyReady(endpoint: request.localProxy)
        try Task.checkCancellation()
        guard isReady else {
            let detail = runtimeManager.capturedErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
        }
    }
}
