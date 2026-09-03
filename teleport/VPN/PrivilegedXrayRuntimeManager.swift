import Foundation

/// User-side coordinator for VPN-mode Xray. It installs the root helper when
/// necessary, sends lifecycle commands over IPC, and keeps a user-readable cache
/// of the last reported root session. The helper remains the real privilege and
/// process boundary. `@unchecked Sendable` places synchronization responsibility
/// on this implementation rather than on the compiler.
final class PrivilegedXrayRuntimeManager: @unchecked Sendable {
    private let bundle: Bundle
    private let fileManager: FileManager
    private let paths: XrayTunRuntimePaths
    private let helperClient: PrivilegedHelperClient
    private let helperInstaller: PrivilegedHelperInstaller

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        helperClient: PrivilegedHelperClient = PrivilegedHelperClient(),
        helperInstaller: PrivilegedHelperInstaller? = nil,
        paths: XrayTunRuntimePaths? = nil
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.paths = paths ?? XrayTunRuntimePaths(fileManager: fileManager)
        self.helperClient = helperClient
        self.helperInstaller = helperInstaller ?? PrivilegedHelperInstaller(bundle: bundle)
    }

    func runtimeURL() -> URL? {
        bundle.url(forResource: "xray", withExtension: nil)
    }

    func start(session: XrayTunLaunchSession) throws {
        try fileManager.createDirectory(at: paths.stateDirectoryURL, withIntermediateDirectories: true)

        guard let runtimeURL = runtimeURL() else {
            throw XrayRuntimeManager.RuntimeError.binaryNotFound
        }

        do {
            try helperInstaller.ensureInstalled(runtimeURL: runtimeURL)
            let sessionID = UUID()
            _ = try XrayTunStartCorrelation.perform(
                persist: { pid in
                    try self.persistSessionState(for: session, sessionID: sessionID, pid: pid)
                },
                start: {
                    try self.helperClient.start(session: session, paths: self.paths, sessionID: sessionID)
                }
            )
        } catch {
            throw XrayTunRuntimeError.startFailed(summary: readableSummary(from: error), details: diagnosticDetails(from: error))
        }
    }

    func waitUntilRunning(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func isRunning() -> Bool {
        if let status = try? helperClient.status() {
            return status.version == PrivilegedHelperClient.expectedVersion && status.phase == .running
        }
        guard let pid = readSessionState()?.pid ?? readPID() else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    func stop() throws {
        let sessionState = readSessionState()
        let pid = sessionState?.pid ?? readPID()
        let protectedHost = sessionState?.protectedHost ?? readProtectedHost()
        let outboundInterface = sessionState?.outboundInterface
        do {
            let sessionID: UUID
            if let cachedSessionID = sessionState?.sessionID {
                sessionID = cachedSessionID
            } else {
                let status = try helperClient.status()
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
                sessionID = observedSessionID
            }

            try helperClient.stop(
                paths: paths,
                protectedHost: protectedHost,
                outboundInterface: outboundInterface,
                sessionID: sessionID
            )
            removeSessionState()
        } catch PrivilegedHelperClientError.unavailable(_) where pid == nil && protectedHost == nil {
            return
        } catch {
            throw XrayTunRuntimeError.stopFailed(summary: readableSummary(from: error), details: diagnosticDetails(from: error))
        }
    }

    func cleanupIfHelperAvailable(protectedHost fallbackProtectedHost: String? = nil) throws {
        if let runtimeURL = runtimeURL() {
            try? helperInstaller.ensureInstalled(runtimeURL: runtimeURL)
        }
        guard let response = try? helperClient.status(), response.success else {
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
        let protectedHost = sessionState?.protectedHost ?? readProtectedHost() ?? fallbackProtectedHost
        let outboundInterface = sessionState?.outboundInterface
        try helperClient.stop(
            paths: paths,
            protectedHost: protectedHost,
            outboundInterface: outboundInterface,
            sessionID: observedSessionID
        )
        removeSessionState()
    }

    func teardown() {
        try? stop()
    }

    func capturedLogOutput() -> String? {
        guard let response = try? helperClient.readLog(logName: "xray-tun.log", maxBytes: 256 * 1024),
              response.success,
              let details = response.details,
              !details.isEmpty else { return nil }
        return details
    }

    private func persistSessionState(for session: XrayTunLaunchSession, sessionID: UUID, pid: pid_t?) throws {
        let state = XrayTunSessionState(
            sessionID: sessionID,
            pid: pid,
            protectedHost: session.protectedHost,
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

    private func readProtectedHost() -> String? {
        try? String(contentsOf: paths.protectedHostFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readableSummary(from error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription, !description.isEmpty {
            return description.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? description
        }
        return error.localizedDescription
    }

    private func diagnosticDetails(from error: Error) -> String {
        let errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let controlLog = tailControlLog().trimmingCharacters(in: .whitespacesAndNewlines)
        return [errorText, controlLog].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func tailControlLog(maxLines: Int = 40) -> String {
        // TODO(gpt-5.6-sol): This direct read targets the helper's root-only 0700
        // directory, so diagnostics are normally empty precisely when IPC fails.
        // Fetch the bounded control-log tail through the authenticated `readLog`
        // command, with a separate short diagnostic timeout.
        guard let rawLog = try? String(contentsOf: paths.controlLogFileURL, encoding: .utf8) else { return "" }
        return rawLog
            .split(separator: "\n")
            .suffix(maxLines)
            .joined(separator: "\n")
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
