import Darwin
import Foundation

/// Validates untrusted client fields, writes root-owned runtime state, and invokes
/// the generated shell routines that own Xray and macOS route mutations.
struct XrayTunController: HelperCommandExecuting, Sendable {
    private let managedProcess: ManagedXrayProcess
    private let shellRunner: HelperShellRunner
    private let scriptBuilder: XrayTunScriptBuilder
    /// One per helper process: the controller is a value, the watch is not.
    private let supervisor: XraySessionSupervisor
    /// Likewise: the guard owns a pf anchor and a lease timer, not a value.
    private let leakGuard: LeakGuardController
    private let sessionExecutor: HelperTUNSessionExecutor

    static let subsystem = "helper"

    init(
        managedProcess: ManagedXrayProcess = ManagedXrayProcess(installedXrayPath: installedXrayPath),
        shellRunner: HelperShellRunner = HelperShellRunner(),
        scriptBuilder: XrayTunScriptBuilder = XrayTunScriptBuilder(installedXrayPath: installedXrayPath),
        supervisor: XraySessionSupervisor = XraySessionSupervisor(),
        leakGuard: LeakGuardController = LeakGuardController(helperStateDirectoryPath: helperStateDirectoryPath),
        sessionExecutor: HelperTUNSessionExecutor = HelperTUNSessionExecutor()
    ) {
        self.managedProcess = managedProcess
        self.shellRunner = shellRunner
        self.scriptBuilder = scriptBuilder
        self.supervisor = supervisor
        self.leakGuard = leakGuard
        self.sessionExecutor = sessionExecutor
    }

    /// Called once before the listener accepts anything. See
    /// `LeakGuardController.releaseStaleGuard`.
    func releaseStaleLeakGuard() {
        leakGuard.releaseStaleGuard()
    }

    func status(request: StatusRequest) throws -> StatusResponse {
        if let snapshot = sessionExecutor.snapshot,
           snapshot.phase != .running || snapshot.pid != nil {
            let phase: TUNHelperSessionPhase
            switch snapshot.phase {
            case .idle: phase = .idle
            case .starting: phase = .starting
            case .running: phase = .running
            case .stopping: phase = .stopping
            case .cleanupFailed: phase = .failed
            }
            return StatusResponse(
                helperVersion: helperVersion, phase: phase,
                summary: snapshot.phase == .cleanupFailed ? "Tunnel cleanup failed; stop must be retried" : nil,
                details: nil, tunnelInterfaceName: snapshot.tunnelInterfaceName,
                outboundInterface: snapshot.outboundInterface
            )
        }
        // The exit watch is the authority on a process this helper started: its
        // event has not come, so the process is there, whatever a momentary
        // proc_pidpath or pid-file reading says. The file check still answers for
        // a session left by an earlier helper process, which nothing watches.
        let isRunning = supervisor.watchedProcessID != nil
            || managedProcess.isManagedXrayRunning(helperStateDirectoryPath: helperStateDirectoryPath)
        // Keep reporting persisted ownership when the process has already exited:
        // an interrupted helper may have left its DNS and physical routes behind.
        let interfaces = XrayTunRuntimeInterfaces.load(helperStateDirectoryPath: helperStateDirectoryPath)
        return StatusResponse(
            helperVersion: helperVersion,
            phase: isRunning ? .running : .idle,
            summary: nil,
            details: nil,
            tunnelInterfaceName: interfaces?.tunnel,
            outboundInterface: interfaces?.outbound
        )
    }

    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse {
        let stateDirectoryPath = try validatedStateDirectoryPath(request.stateDirectoryPath)
        let assetDirectoryPath = try validatedAssetDirectoryPath(request.assetDirectoryPath)
        let protectedHosts = try validatedProtectedHosts(request.protectedHosts, required: true)
        let tunnelInterfaceName = try validatedTunnelInterfaceName(request.tunnelInterfaceName)
        let outboundInterface = try validatedOutboundInterface(request.outboundInterface)

        guard FileManager.default.isExecutableFile(atPath: installedXrayPath) else {
            throw HelperError("Installed Xray runtime is missing. Reinstall Teleport's privileged helper.")
        }

        let config = request.configData
        guard !config.isEmpty else { throw HelperError("Missing configData") }
        guard config.count <= maxConfigBytes else { throw HelperError("Xray tunnel config is too large") }
        let configPath = helperStateDirectoryPath + "/xray-tun-config.json"
        let cleanup = makeCleanup(stateDirectoryPath: stateDirectoryPath, protectedHosts: protectedHosts,
                                  tunnelInterfaceName: tunnelInterfaceName, outboundInterface: outboundInterface)
        try sessionExecutor.start(sessionID: sessionID, cleanup: cleanup, prepare: {
            let helperStateDirectoryPath = try Self.preparedHelperStateDirectoryPath()
            supervisor.cancel()
            SystemStateDump.setMarker(request.dumpsSystemState)
            TeleportLog.shared.info(Self.subsystem, "start session \(LogFormat.id(sessionID)): tun \(tunnelInterfaceName), uplink \(outboundInterface), \(protectedHosts.count) protected hosts")
            SystemStateDump.capture("helper: before tunnel start")
            try managedProcess.terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
            try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
            try writeHelperConfig(config, to: configPath)
        }) { token in
            try shellRunner.run(scriptBuilder.makeStartScript(
                helperStateDirectoryPath: helperStateDirectoryPath,
                configPath: configPath,
                assetDirectoryPath: assetDirectoryPath,
                protectedHosts: protectedHosts,
                tunnelInterfaceName: tunnelInterfaceName,
                outboundInterface: outboundInterface,
                installsIPv6Routes: NetworkInterfaceInventory.hasGlobalIPv6Address(outboundInterface)
            ), label: "tunnel start script")
            TeleportLog.shared.info(Self.subsystem, "start session \(LogFormat.id(sessionID)): tunnel is up")
            SystemStateDump.capture("helper: after tunnel start")
            return superviseStartedXray(token: token, helperStateDirectoryPath: helperStateDirectoryPath)
        }
        return StartSessionResponse(
            phase: .running,
            summary: nil,
            details: nil
        )
    }

    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse {
        let stateDirectoryPath = try validatedStateDirectoryPath(request.stateDirectoryPath)
        let protectedHosts = try validatedProtectedHosts(request.protectedHosts, required: false)
        let outboundInterface = try validatedOutboundInterface(request.outboundInterface)
        try sessionExecutor.stop(sessionID: sessionID, fallback: try restartCleanup(
            stateDirectoryPath: stateDirectoryPath, protectedHosts: protectedHosts, outboundInterface: outboundInterface
        ))
        return StopSessionResponse(
            phase: .idle,
            summary: nil,
            details: nil
        )
    }

    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse {
        // pf resolves names at load time. A hostname here would make the helper
        // perform a lookup on the client's behalf while writing root-owned
        // firewall rules, so only addresses the helper can parse itself are used.
        let protectedHosts = try validatedProtectedHosts(request.protectedHosts, required: false)
            .filter { isNumericAddress($0) }
        let stage: LeakGuardRuleset.Stage
        if let tunnelInterfaceName = request.tunnelInterfaceName {
            stage = .session(tunnelInterface: try validatedTunnelInterfaceName(tunnelInterfaceName))
        } else {
            stage = .standby
        }
        _ = try Self.preparedHelperStateDirectoryPath()
        try leakGuard.engage(
            stage: stage,
            protectedHosts: protectedHosts,
            leaseSeconds: request.leaseSeconds
        )
        return LeakGuardResponse(isEngaged: true)
    }

    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse {
        leakGuard.release()
        return LeakGuardResponse(isEngaged: false)
    }

    private func isNumericAddress(_ value: String) -> Bool {
        var ipv4Address = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 { return true }
        var ipv6Address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6Address) } == 1
    }

    // A client may send stop after a rejected start. Only run the restart
    // fallback when this helper has evidence of a previous tunnel.
    private func restartCleanup(stateDirectoryPath: String, protectedHosts: [String],
                                outboundInterface: String) throws -> HelperTUNSessionExecutor.Cleanup? {
        let path = try Self.preparedHelperStateDirectoryPath()
        let records = ["xray-tun-config.json", "xray-tun.pid", "xray-tun-protected-host",
                       "xray-tun-protected-gateways", "xray-tun-protected-dns"]
        guard records.contains(where: { FileManager.default.fileExists(atPath: path + "/" + $0) })
                || managedProcess.validatedLegacyPID(stateDirectoryPath: stateDirectoryPath) != nil else { return nil }
        let interfaces = XrayTunRuntimeInterfaces.load(helperStateDirectoryPath: path)
        return makeCleanup(stateDirectoryPath: stateDirectoryPath, protectedHosts: protectedHosts,
                           tunnelInterfaceName: interfaces?.tunnel, outboundInterface: interfaces?.outbound ?? outboundInterface)
    }

    /// A single cleanup recipe, retained until it succeeds. Capture only the
    /// resource drivers and validated values, never the controller/executor.
    private func makeCleanup(stateDirectoryPath: String, protectedHosts: [String],
                             tunnelInterfaceName: String?, outboundInterface: String) -> HelperTUNSessionExecutor.Cleanup {
        let supervisor = supervisor
        let managedProcess = managedProcess
        let shellRunner = shellRunner
        let scriptBuilder = scriptBuilder
        return .init(tunnelInterfaceName: tunnelInterfaceName, outboundInterface: outboundInterface) {
            supervisor.cancel()
            let path = try Self.preparedHelperStateDirectoryPath()
            SystemStateDump.capture("helper: before tunnel stop")
            try managedProcess.terminateManagedXray(helperStateDirectoryPath: path)
            try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
            try shellRunner.run(scriptBuilder.makeStopScript(
                helperStateDirectoryPath: path,
                protectedHosts: protectedHosts.isEmpty ? nil : protectedHosts,
                outboundInterface: outboundInterface
            ), label: "tunnel stop script")
            SystemStateDump.capture("helper: after tunnel stop")
        }
    }

    private func superviseStartedXray(token: HelperTUNSessionExecutor.RunToken,
                                      helperStateDirectoryPath: String) -> pid_t? {
        guard let pid = managedProcess.validatedManagedXrayPID(helperStateDirectoryPath: helperStateDirectoryPath) else {
            TeleportLog.shared.warn(Self.subsystem, "session \(LogFormat.id(token.sessionID)): no validated xray pid after start; not supervising")
            return nil
        }
        let executor = sessionExecutor
        supervisor.watch(pid: pid) { [weak executor] exitedPID in
            executor?.unexpectedExit(token: token, pid: exitedPID)
        }
        return pid
    }

    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse {
        let logName: String
        switch request.log {
        case .config:
            logName = "xray-tun-config.json"
        case .xray:
            logName = "xray-tun.log"
        case .control:
            logName = "xray-tun-control.log"
        case .helper:
            logName = "helper.log"
        }
        let maxBytes = max(1, min(request.maximumBytes, maxLogReadBytes))
        let helperStateDirectoryPath = try Self.preparedHelperStateDirectoryPath()
        let logPath = helperStateDirectoryPath + "/" + logName
        let data = try readTail(from: logPath, maxBytes: maxBytes)
        let truncationNotice = data.wasTruncated
            ? "… showing last \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) …\n"
            : ""
        let contentLimit = max(0, maxBytes - truncationNotice.lengthOfBytes(using: .utf8))
        let contents = data.wasTruncated ? Data(data.contents.suffix(contentLimit)) : data.contents
        let text = String(decoding: contents, as: UTF8.self)
        let metadata = logMetadata(path: logPath, totalBytes: data.totalBytes, returnedBytes: contents.count, wasTruncated: data.wasTruncated)
        let boundedText = truncationNotice + text
        return DiagnosticsResponse(
            log: request.log,
            text: boundedText,
            metadata: metadata,
            wasTruncated: data.wasTruncated
        )
    }

    private func required(_ value: String?, _ name: String) throws -> String {
        guard let value, !value.isEmpty else { throw HelperError("Missing \(name)") }
        return value
    }

    private func validatedStateDirectoryPath(_ value: String?) throws -> String {
        let rawPath = try required(value, "stateDirectoryPath")
        let expectedPath = try expectedStateDirectoryPath()
        let normalizedPath = try Self.standardizedAbsolutePath(rawPath, name: "stateDirectoryPath")
        guard normalizedPath == expectedPath else {
            throw HelperError("Rejected unexpected state directory path")
        }

        let resolvedPath = URL(fileURLWithPath: normalizedPath, isDirectory: true).resolvingSymlinksInPath().path
        guard resolvedPath == expectedPath else {
            throw HelperError("Rejected state directory path that resolves outside Teleport's support directory")
        }

        let consoleOwner = consoleUserIDs()
        var statInfo = stat()
        if lstat(normalizedPath, &statInfo) == 0 {
            guard (statInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw HelperError("Rejected state directory path that is not a directory")
            }
            guard statInfo.st_uid == consoleOwner.uid else {
                throw HelperError("Rejected state directory not owned by console user")
            }
            guard (statInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw HelperError("Rejected group/world-writable state directory")
            }
        } else if errno == ENOENT {
            return normalizedPath
        } else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        return normalizedPath
    }

    private func validatedAssetDirectoryPath(_ value: String?) throws -> String {
        let rawPath = try required(value, "assetDirectoryPath")
        let expectedPath = URL(fileURLWithPath: try expectedStateDirectoryPath(), isDirectory: true)
            .appendingPathComponent("geodata-resolved", isDirectory: true)
            .path
        let normalizedPath = try Self.standardizedAbsolutePath(rawPath, name: "assetDirectoryPath")
        guard normalizedPath == expectedPath,
              URL(fileURLWithPath: normalizedPath, isDirectory: true).resolvingSymlinksInPath().path == expectedPath else {
            throw HelperError("Rejected unexpected geodata asset directory path")
        }

        let consoleOwner = consoleUserIDs()
        try validateRegularPath(normalizedPath, expectedType: S_IFDIR, owner: consoleOwner.uid, name: "geodata asset directory")
        for fileName in ["geosite.dat", "geoip.dat"] {
            try validateRegularPath(
                normalizedPath + "/" + fileName,
                expectedType: S_IFREG,
                owner: consoleOwner.uid,
                name: fileName
            )
        }
        return normalizedPath
    }

    private func validateRegularPath(_ path: String, expectedType: mode_t, owner: uid_t, name: String) throws {
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else {
            throw HelperError("Missing \(name)")
        }
        guard (statInfo.st_mode & S_IFMT) == expectedType else {
            throw HelperError("Rejected \(name) that is not a regular managed path")
        }
        guard statInfo.st_uid == owner else {
            throw HelperError("Rejected \(name) not owned by the console user")
        }
        guard (statInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw HelperError("Rejected group/world-writable \(name)")
        }
    }

    private func writeHelperConfig(_ value: Data, to path: String) throws {
        // Publish config as restart evidence only after its permissions are set.
        let temporary = URL(fileURLWithPath: path + ".pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try value.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func expectedStateDirectoryPath() throws -> String {
        let uid = consoleUserIDs().uid
        guard let passwd = getpwuid(uid), let homeDirectory = passwd.pointee.pw_dir else {
            throw HelperError("Could not resolve console user home directory")
        }
        return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("teleport", isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func standardizedAbsolutePath(_ value: String, name: String) throws -> String {
        guard value.hasPrefix("/") else {
            throw HelperError("Rejected non-absolute \(name)")
        }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        guard !path.contains("/../") else {
            throw HelperError("Rejected invalid \(name)")
        }
        return path
    }

    /// Each entry is validated with the same host rules as before; the list is
    /// bounded so a client cannot ask the helper for unbounded route mutations.
    private func validatedProtectedHosts(_ values: [String]?, required: Bool) throws -> [String] {
        let values = values ?? []
        guard !values.isEmpty else {
            if required { throw HelperError("Missing protectedHosts") }
            return []
        }
        guard values.count <= TUNHelperProtocol.maximumProtectedHosts else {
            throw HelperError("Rejected too many protectedHosts")
        }
        return try values.map { try validatedProtectedHost($0, required: true) }
    }

    private func validatedProtectedHost(_ value: String?, required: Bool) throws -> String {
        guard let value, !value.isEmpty else {
            if required { throw HelperError("Missing protectedHost") }
            return ""
        }
        var ipv6Address = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 {
            return value.lowercased()
        }
        guard value.count <= 253,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-"),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else {
            throw HelperError("Rejected invalid protectedHost")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw HelperError("Rejected invalid protectedHost")
        }
        for label in value.split(separator: ".") {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                throw HelperError("Rejected invalid protectedHost")
            }
        }
        return value
    }

    private func validatedTunnelInterfaceName(_ value: String?) throws -> String {
        let value = try required(value, "tunnelInterfaceName")
        guard matches(value, pattern: #"^utun[0-9]{1,4}$"#) else {
            throw HelperError("Rejected invalid tunnelInterfaceName")
        }
        return value
    }

    private func validatedOutboundInterface(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { return "" }
        guard value.count <= 32,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-"),
              matches(value, pattern: #"^[A-Za-z0-9._-]+$"#) else {
            throw HelperError("Rejected invalid outboundInterface")
        }
        return value
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func preparedHelperStateDirectoryPath() throws -> String {
        let normalizedPath = try standardizedAbsolutePath(helperStateDirectoryPath, name: "helperStateDirectoryPath")
        var statInfo = stat()
        if lstat(normalizedPath, &statInfo) == 0 {
            guard (statInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw HelperError("Rejected helper state path that is not a directory")
            }
            guard statInfo.st_uid == 0 else {
                throw HelperError("Rejected helper state directory not owned by root")
            }
            guard (statInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw HelperError("Rejected group/world-writable helper state directory")
            }
            guard chmod(normalizedPath, 0o700) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(atPath: normalizedPath, withIntermediateDirectories: false)
            guard chown(normalizedPath, 0, 0) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard chmod(normalizedPath, 0o700) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return normalizedPath
    }

    private func readTail(from path: String, maxBytes: Int) throws -> (contents: Data, totalBytes: Int, wasTruncated: Bool) {
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else {
            if errno == ENOENT { return (Data(), 0, false) }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (statInfo.st_mode & S_IFMT) == S_IFREG else {
            throw HelperError("Rejected log path that is not a regular file")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let totalBytes = Int(try handle.seekToEnd())
        let offset = max(0, totalBytes - maxBytes)
        try handle.seek(toOffset: UInt64(offset))
        return (try handle.readToEnd() ?? Data(), totalBytes, offset > 0)
    }

    private func logMetadata(path: String, totalBytes: Int, returnedBytes: Int, wasTruncated: Bool) -> String {
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else {
            return "Missing: \(path)"
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
        let modifiedText = DateFormatter.localizedString(from: modified, dateStyle: .medium, timeStyle: .medium)
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        if wasTruncated {
            let returnedText = ByteCountFormatter.string(fromByteCount: Int64(returnedBytes), countStyle: .file)
            return "\(path) • \(sizeText) • showing \(returnedText) • modified \(modifiedText)"
        }
        return "\(path) • \(sizeText) • modified \(modifiedText)"
    }
}
