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

    static let subsystem = "helper"

    init(
        managedProcess: ManagedXrayProcess = ManagedXrayProcess(installedXrayPath: installedXrayPath),
        shellRunner: HelperShellRunner = HelperShellRunner(),
        scriptBuilder: XrayTunScriptBuilder = XrayTunScriptBuilder(installedXrayPath: installedXrayPath),
        supervisor: XraySessionSupervisor = XraySessionSupervisor(),
        leakGuard: LeakGuardController = LeakGuardController(helperStateDirectoryPath: helperStateDirectoryPath)
    ) {
        self.managedProcess = managedProcess
        self.shellRunner = shellRunner
        self.scriptBuilder = scriptBuilder
        self.supervisor = supervisor
        self.leakGuard = leakGuard
    }

    /// Called once before the listener accepts anything. See
    /// `LeakGuardController.releaseStaleGuard`.
    func releaseStaleLeakGuard() {
        leakGuard.releaseStaleGuard()
    }

    func status(request: StatusRequest) throws -> StatusResponse {
        let isRunning = managedProcess.isManagedXrayRunning(
            helperStateDirectoryPath: helperStateDirectoryPath
        )
        return StatusResponse(
            helperVersion: helperVersion,
            phase: isRunning ? .running : .idle,
            summary: nil,
            details: nil
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

        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
        // The previous session's watch must not fire on the Xray this start is
        // about to replace.
        supervisor.cancel()
        // Set before the first capture, so the request that turns dumps on is itself
        // dumped rather than the setting only taking effect from the next session.
        SystemStateDump.setMarker(request.dumpsSystemState)
        TeleportLog.shared.info(Self.subsystem, "start session \(LogFormat.id(sessionID)): tun \(tunnelInterfaceName), uplink \(outboundInterface), \(protectedHosts.count) protected hosts")
        SystemStateDump.capture("helper: before tunnel start")
        let configPath = try writeHelperConfig(request.configData, helperStateDirectoryPath: helperStateDirectoryPath)
        try managedProcess.terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
        try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
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
        superviseStartedXray(sessionID: sessionID, helperStateDirectoryPath: helperStateDirectoryPath, outboundInterface: outboundInterface)
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
        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
        TeleportLog.shared.info(Self.subsystem, "stop session \(LogFormat.id(sessionID)): uplink \(outboundInterface.isEmpty ? "<none>" : outboundInterface), \(protectedHosts.count) protected hosts")
        // Before the script: the exit it causes must not read as a crash.
        supervisor.cancel()
        SystemStateDump.capture("helper: before tunnel stop")
        try managedProcess.terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
        try managedProcess.terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
        try shellRunner.run(scriptBuilder.makeStopScript(
            helperStateDirectoryPath: helperStateDirectoryPath,
            protectedHosts: protectedHosts.isEmpty ? nil : protectedHosts,
            outboundInterface: outboundInterface
        ), label: "tunnel stop script")
        TeleportLog.shared.info(Self.subsystem, "stop session \(LogFormat.id(sessionID)): teardown finished")
        SystemStateDump.capture("helper: after tunnel stop")
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
        _ = try preparedHelperStateDirectoryPath()
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

    /// The start script has returned and nothing else would look at Xray again.
    /// If it exits before a stop is requested, the routes it owned are removed with
    /// the same script a stop would run, so the machine routes directly instead of
    /// into a TUN that no longer exists. The app learns of it through the status
    /// it polls, which reads the pid file the script removes.
    private func superviseStartedXray(sessionID: UUID, helperStateDirectoryPath: String, outboundInterface: String) {
        guard let pid = managedProcess.validatedManagedXrayPID(helperStateDirectoryPath: helperStateDirectoryPath) else {
            TeleportLog.shared.warn(Self.subsystem, "session \(LogFormat.id(sessionID)): no validated xray pid after start; not supervising")
            return
        }
        let managedProcess = managedProcess
        let shellRunner = shellRunner
        let scriptBuilder = scriptBuilder
        supervisor.watch(pid: pid) { exitedPID in
            // A pid file that no longer names this process means a stop already
            // ran its script; the exit is that stop's doing.
            guard managedProcess.managedXrayPID(pidFilePath: helperStateDirectoryPath + "/xray-tun.pid", expectedOwner: 0) == exitedPID else { return }
            TeleportLog.shared.error(Self.subsystem, "session \(LogFormat.id(sessionID)): xray (pid \(exitedPID)) exited on its own; removing its routes")
            SystemStateDump.capture("helper: before teardown after xray exit")
            do {
                try shellRunner.run(scriptBuilder.makeStopScript(
                    helperStateDirectoryPath: helperStateDirectoryPath,
                    protectedHosts: nil,
                    outboundInterface: outboundInterface
                ), label: "tunnel stop script")
                TeleportLog.shared.info(Self.subsystem, "session \(LogFormat.id(sessionID)): teardown after xray exit finished")
            } catch {
                TeleportLog.shared.error(Self.subsystem, "session \(LogFormat.id(sessionID)): teardown after xray exit failed: \(LogFormat.error(error))")
            }
            SystemStateDump.capture("helper: after teardown after xray exit")
        }
        TeleportLog.shared.info(Self.subsystem, "session \(LogFormat.id(sessionID)): supervising xray pid \(pid)")
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
        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
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
        let normalizedPath = try standardizedAbsolutePath(rawPath, name: "stateDirectoryPath")
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
        let normalizedPath = try standardizedAbsolutePath(rawPath, name: "assetDirectoryPath")
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

    private func writeHelperConfig(_ value: Data?, helperStateDirectoryPath: String) throws -> String {
        guard let value, !value.isEmpty else { throw HelperError("Missing configData") }
        guard value.count <= maxConfigBytes else { throw HelperError("Xray tunnel config is too large") }
        let configPath = helperStateDirectoryPath + "/xray-tun-config.json"
        removeSymlinkIfPresent(configPath)
        try value.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        guard chown(configPath, 0, 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard chmod(configPath, 0o600) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return configPath
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

    private func standardizedAbsolutePath(_ value: String, name: String) throws -> String {
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
        guard values.count <= VPNHelperProtocol.maximumProtectedHosts else {
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

    private func preparedHelperStateDirectoryPath() throws -> String {
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

    private func removeSymlinkIfPresent(_ path: String) {
        var statInfo = stat()
        if lstat(path, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFLNK {
            unlink(path)
        }
    }
}
