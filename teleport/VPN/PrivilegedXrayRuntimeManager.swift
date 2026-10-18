import Foundation

/// User-side coordinator for VPN-mode Xray. It installs the root helper when
/// necessary, sends lifecycle commands over IPC, and keeps a user-readable cache
/// of the last reported root session. The helper remains the real privilege and
/// process boundary. `@unchecked Sendable` places synchronization responsibility
/// on this implementation rather than on the compiler.
final class PrivilegedXrayRuntimeManager: @unchecked Sendable {
    nonisolated static let subsystem = "vpn"
    private let fileManager: FileManager
    private let paths: XrayTunRuntimePaths
    private let helperClient: PrivilegedHelperClient
    private let runtimeURLProvider: () -> URL?
    private let assetDirectoryURLProvider: () throws -> URL
    private let ensureHelperInstalled: (URL, @escaping @Sendable () -> Void) async throws -> Void

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        helperClient: PrivilegedHelperClient = PrivilegedHelperClient(),
        helperInstaller: PrivilegedHelperInstaller? = nil,
        paths: XrayTunRuntimePaths? = nil,
        runtimeURLProvider: (() -> URL?)? = nil,
        assetDirectoryURLProvider: (() throws -> URL)? = nil,
        ensureHelperInstalled: ((URL, @escaping @Sendable () -> Void) async throws -> Void)? = nil
    ) {
        let installer = helperInstaller ?? PrivilegedHelperInstaller(bundle: bundle)
        self.fileManager = fileManager
        self.paths = paths ?? XrayTunRuntimePaths(fileManager: fileManager)
        self.helperClient = helperClient
        self.runtimeURLProvider = runtimeURLProvider ?? {
            bundle.url(forResource: "xray", withExtension: nil)
        }
        self.assetDirectoryURLProvider = assetDirectoryURLProvider ?? {
            try GeodataUpdateService(fileManager: fileManager).resolvedAssetDirectoryURL(bundle: bundle)
        }
        self.ensureHelperInstalled = ensureHelperInstalled ?? { runtimeURL, beforeInstalling in
            try await installer.ensureInstalled(runtimeURL: runtimeURL, beforeInstalling: beforeInstalling)
        }
    }

    func runtimeURL() -> URL? {
        runtimeURLProvider()
    }

    /// Installs or updates the privileged helper if the bundled one is not what
    /// is installed and running. Separate from `start` so a connect can do it
    /// before it changes anything on the machine: the administrator prompt this
    /// may put up is then a wait the user can still cancel out of with Disconnect.
    /// `onInstallingHelper` fires only when an install is actually about to happen.
    func prepareHelper(onInstallingHelper: @escaping @Sendable () -> Void) async throws {
        guard let runtimeURL = runtimeURL() else {
            throw XrayRuntimeManager.RuntimeError.binaryNotFound
        }
        try await ensureHelperInstalled(runtimeURL, onInstallingHelper)
    }

    func start(session: XrayTunLaunchSession) async throws {
        try fileManager.createDirectory(at: paths.stateDirectoryURL, withIntermediateDirectories: true)

        guard let runtimeURL = runtimeURL() else {
            throw XrayRuntimeManager.RuntimeError.binaryNotFound
        }

        let sessionID = UUID()
        do {
            let assetDirectoryURL = try assetDirectoryURLProvider()
            // Normally a no-op after prepareHelper; still here for a start that
            // did not go through it.
            try await ensureHelperInstalled(runtimeURL, {})
            _ = try await XrayTunStartCorrelation.perform(
                persist: { pid in
                    try self.persistSessionState(for: session, sessionID: sessionID, pid: pid)
                },
                start: {
                    try await self.helperClient.start(
                        session: session,
                        paths: self.paths,
                        assetDirectoryURL: assetDirectoryURL,
                        sessionID: sessionID
                    )
                }
            )
        } catch {
            await rollbackFailedStart(session: session, sessionID: sessionID, cause: error)
            throw XrayTunRuntimeError.startFailed(summary: readableSummary(from: error), details: await diagnosticDetails(from: error))
        }
    }

    func waitUntilRunning(timeout: TimeInterval = 3) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(timeout)
        while clock.now < deadline {
            if await isRunning() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func isRunning() async -> Bool {
        // Four sessions were torn down as "Xray stopped unexpectedly" while the
        // helper's exit watch had seen nothing, and neither side had logged why
        // this answered no. Every negative answer now says what it rests on.
        do {
            let status = try await helperClient.status()
            if status.version == PrivilegedHelperClient.expectedVersion && status.phase == .running {
                return true
            }
            // Info, not a warning: at launch, idle is the expected answer. The
            // supervision in the provider says when a miss mattered.
            TeleportLog.shared.info(Self.subsystem, "helper reports the runtime is not running: phase \(status.phase.rawValue), helper version \(status.version ?? "<unknown>")")
            return false
        } catch {
            guard let pid = readSessionState()?.pid ?? readPID() else {
                TeleportLog.shared.warn(Self.subsystem, "helper status failed (\(LogFormat.error(error))) and no session pid is on record")
                return false
            }
            if kill(pid, 0) == 0 || errno == EPERM {
                return true
            }
            TeleportLog.shared.warn(Self.subsystem, "helper status failed (\(LogFormat.error(error))) and pid \(pid) is gone: \(String(cString: strerror(errno)))")
            return false
        }
    }

    func stop() async throws {
        let sessionState = readSessionState()
        let pid = sessionState?.pid ?? readPID()
        let protectedHosts = sessionState?.protectedHosts ?? readProtectedHosts()
        let outboundInterface = sessionState?.outboundInterface
        var resolvedSessionID = sessionState?.sessionID
        do {
            if resolvedSessionID == nil {
                let status = try await helperClient.status()
                if status.phase == .idle {
                    removeSessionState()
                    return
                }
                guard status.phase == .running else {
                    throw PrivilegedHelperClientError.indeterminateStatus(
                        "The privileged helper session state is indeterminate while stopping"
                    )
                }
                guard let observedSessionID = status.sessionID else {
                    throw PrivilegedHelperClientError.indeterminateStatus(
                        "The running privileged helper session has no correlation identifier"
                    )
                }
                resolvedSessionID = observedSessionID
            }

            try await stopSession(
                sessionID: resolvedSessionID!,
                protectedHosts: protectedHosts,
                outboundInterface: outboundInterface
            )
        } catch PrivilegedHelperClientError.unavailable(_) where pid == nil && protectedHosts == nil {
            return
        } catch let clientError as PrivilegedHelperClientError {
            switch clientError {
            case .unavailable, .incompatibleService:
                do {
                    guard let runtimeURL = runtimeURL() else {
                        throw XrayRuntimeManager.RuntimeError.binaryNotFound
                    }
                    try await ensureHelperInstalled(runtimeURL, {})
                    try await stopSession(
                        sessionID: resolvedSessionID ?? UUID(),
                        protectedHosts: protectedHosts,
                        outboundInterface: outboundInterface
                    )
                } catch {
                    throw XrayTunRuntimeError.stopFailed(summary: readableSummary(from: error), details: await diagnosticDetails(from: error))
                }
            default:
                throw XrayTunRuntimeError.stopFailed(summary: readableSummary(from: clientError), details: await diagnosticDetails(from: clientError))
            }
        } catch {
            throw XrayTunRuntimeError.stopFailed(summary: readableSummary(from: error), details: await diagnosticDetails(from: error))
        }
    }

    func cleanupIfHelperAvailable(protectedHosts fallbackProtectedHosts: [String] = []) async throws {
        if let runtimeURL = runtimeURL() {
            try? await ensureHelperInstalled(runtimeURL, {})
        }
        guard let response = try? await helperClient.status(), response.success else {
            return
        }
        if response.phase == .idle {
            removeSessionState()
            return
        }
        guard response.phase == .running else {
            return
        }
        guard let observedSessionID = response.sessionID else {
            throw PrivilegedHelperClientError.indeterminateStatus(
                "The running privileged helper session has no correlation identifier"
            )
        }

        let sessionState = readSessionState()
        if let cachedSessionID = sessionState?.sessionID, cachedSessionID != observedSessionID {
            throw PrivilegedHelperClientError.indeterminateStatus(
                "The running privileged helper session does not match the cached correlation identifier"
            )
        }
        let protectedHosts = sessionState?.protectedHosts ?? readProtectedHosts() ?? fallbackProtectedHosts
        let outboundInterface = sessionState?.outboundInterface
        try await helperClient.stop(
            paths: paths,
            protectedHosts: protectedHosts,
            outboundInterface: outboundInterface,
            sessionID: observedSessionID
        )
        removeSessionState()
    }

    private func stopSession(
        sessionID: UUID,
        protectedHosts: [String]?,
        outboundInterface: String?
    ) async throws {
        try await helperClient.stop(
            paths: paths,
            protectedHosts: protectedHosts,
            outboundInterface: outboundInterface,
            sessionID: sessionID
        )
        removeSessionState()
    }

    private func rollbackFailedStart(
        session: XrayTunLaunchSession,
        sessionID: UUID,
        cause: Error
    ) async {
        guard readSessionState()?.sessionID == sessionID else { return }
        if case PrivilegedHelperClientError.unavailable = cause {
            removeSessionState()
            return
        }
        try? await stopSession(
            sessionID: sessionID,
            protectedHosts: session.protectedHosts,
            outboundInterface: session.outboundInterface
        )
    }

    func capturedLogOutput() async -> String? {
        guard let response = try? await helperClient.readLog(logName: "xray-tun.log", maxBytes: 256 * 1024),
              response.success,
              let details = response.details,
              !details.isEmpty else { return nil }
        return details
    }

    private func persistSessionState(for session: XrayTunLaunchSession, sessionID: UUID, pid: pid_t?) throws {
        let state = XrayTunSessionState(
            sessionID: sessionID,
            pid: pid,
            protectedHosts: session.protectedHosts,
            tunnelInterfaceName: session.tunnelInterfaceName,
            outboundInterface: session.outboundInterface,
            configPath: paths.configFileURL.path,
            startedAt: Date()
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: paths.sessionStateFileURL, options: .atomic)
    }

    private func readSessionState() -> XrayTunSessionState? {
        guard let data = try? Data(contentsOf: paths.sessionStateFileURL) else { return nil }
        return try? JSONDecoder().decode(XrayTunSessionState.self, from: data)
    }

    private func removeSessionState() {
        try? fileManager.removeItem(at: paths.sessionStateFileURL)
    }

    private func readPID() -> pid_t? {
        guard let rawPID = try? String(contentsOf: paths.pidFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(rawPID),
            pid > 0 else {
            return nil
        }
        return pid
    }

    /// The helper writes one protected host per line.
    private func readProtectedHosts() -> [String]? {
        guard let contents = try? String(contentsOf: paths.protectedHostFileURL, encoding: .utf8) else {
            return nil
        }
        let hosts = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hosts.isEmpty ? nil : hosts
    }

    private func readableSummary(from error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription, !description.isEmpty {
            return description.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? description
        }
        return error.localizedDescription
    }

    /// The control log lives in the helper's root-only directory, so the only way
    /// to read it is the helper's own bounded `readLog` command, which carries a
    /// short timeout of its own. It is worth asking for when the helper ran its
    /// script and that failed or never reported back — the log then says how far
    /// it got — and not for a failure decided before any script ran, where there
    /// is nothing in that log about it.
    private func diagnosticDetails(from error: Error, maxLines: Int = 40) async -> String {
        let errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch error as? PrivilegedHelperClientError {
        case .commandFailed, .inProgress, .indeterminate:
            break
        default:
            return errorText
        }

        let controlLog = ((try? await helperClient.readLog(
            logName: "xray-tun-control.log",
            maxBytes: 64 * 1024
        ).details) ?? "")
            .split(separator: "\n")
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [errorText, controlLog].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum XrayTunRuntimeError: LocalizedError {
    case startFailed(summary: String, details: String)
    case stopFailed(summary: String, details: String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(summary, _):
            return summary.isEmpty ? "Failed to start Teleport VPN" : summary
        case let .stopFailed(summary, _):
            return summary.isEmpty ? "Failed to stop Teleport VPN" : summary
        }
    }

    var failureReason: String? {
        switch self {
        case let .startFailed(_, details), let .stopFailed(_, details):
            return details.isEmpty ? nil : details
        }
    }
}
