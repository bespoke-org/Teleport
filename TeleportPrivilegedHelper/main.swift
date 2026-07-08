import Foundation
import Darwin
import Security

private let helperVersion = PrivilegedHelperConstants.version
private let helperLabel = PrivilegedHelperConstants.label
private let socketPath = PrivilegedHelperConstants.socketPath
private let helperStateDirectoryPath = PrivilegedHelperConstants.helperStateDirectoryPath
private let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
private let maxRequestBytes = 2 * 1024 * 1024
private let maxConfigBytes = 1024 * 1024
private let maxLogReadBytes = 1024 * 1024
private let maxCapturedShellOutputBytes = 64 * 1024

struct HelperRequest: Codable {
    var command: String
    var stateDirectoryPath: String?
    var configPath: String?
    var configData: Data?
    var protectedHost: String?
    var tunnelInterfaceName: String?
    var outboundInterface: String?
    var pid: Int32?
    var logName: String?
    var maxBytes: Int?
}

struct HelperResponse: Codable {
    var success: Bool
    var version: String?
    var summary: String?
    var details: String?
}

final class HelperServer {
    func run() throws {
        let serverFD = try makeListeningSocket()
        defer {
            close(serverFD)
            unlink(socketPath)
        }

        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            handleClient(clientFD)
        }
    }

    private func makeListeningSocket() throws -> Int32 {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw HelperError("Socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in buffer.indices {
                buffer[index] = 0
            }
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, length)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        let consoleOwner = consoleUserIDs()
        chown(socketPath, consoleOwner.uid, consoleOwner.gid)
        chmod(socketPath, 0o666)

        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        do {
            try authorizePeer(fd)
            let requestData = try readAll(from: fd)
            let request = try JSONDecoder().decode(HelperRequest.self, from: requestData)
            let response = handle(request)
            try write(response, to: fd)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let response = HelperResponse(success: false, version: helperVersion, summary: message, details: nil)
            try? write(response, to: fd)
        }
    }

    private func authorizePeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw HelperError("Could not verify Teleport client identity")
        }
        let consoleOwner = consoleUserIDs()
        guard uid == consoleOwner.uid else {
            throw HelperError("Rejected request from uid \(uid); expected console uid \(consoleOwner.uid)")
        }
        _ = gid
        try authorizePeerCodeSignature(fd)
    }

    private func authorizePeerCodeSignature(_ fd: Int32) throws {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDLength) == 0 else {
            throw HelperError("Could not identify Teleport client process")
        }

        var secCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: peerPID] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &secCode)
        guard status == errSecSuccess, let secCode else {
            throw HelperError("Could not inspect Teleport client signature: OSStatus \(status)")
        }

        var requirement: SecRequirement?
        let requirementText = "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\""
        status = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw HelperError("Could not create Teleport signature requirement: OSStatus \(status)")
        }

        status = SecCodeCheckValidity(secCode, SecCSFlags(), requirement)
        guard status == errSecSuccess else {
            throw HelperError("Rejected request from unsigned or untrusted Teleport client: OSStatus \(status)")
        }
    }

    private func handle(_ request: HelperRequest) -> HelperResponse {
        do {
            switch request.command {
            case "status":
                return HelperResponse(success: true, version: helperVersion, summary: nil, details: nil)
            case "start":
                let pid = try XrayTunController().start(request: request)
                return HelperResponse(success: true, version: helperVersion, summary: nil, details: pid.map(String.init))
            case "stop":
                try XrayTunController().stop(request: request)
                return HelperResponse(success: true, version: helperVersion, summary: nil, details: nil)
            case "readLog":
                let log = try XrayTunController().readLog(request: request)
                return HelperResponse(success: true, version: helperVersion, summary: log.metadata, details: log.text)
            default:
                return HelperResponse(success: false, version: helperVersion, summary: "Unsupported helper command: \(request.command)", details: nil)
            }
        } catch {
            let summary = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return HelperResponse(success: false, version: helperVersion, summary: summary, details: nil)
        }
    }

    private func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.count > maxRequestBytes {
                    throw HelperError("Privileged helper request is too large")
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        return data
    }

    private func write(_ response: HelperResponse, to fd: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}

final class XrayTunController {
    func start(request: HelperRequest) throws -> pid_t? {
        let stateDirectoryPath = try validatedStateDirectoryPath(request.stateDirectoryPath)
        let protectedHost = try validatedProtectedHost(request.protectedHost, required: true)
        let tunnelInterfaceName = try validatedTunnelInterfaceName(request.tunnelInterfaceName)
        let outboundInterface = try validatedOutboundInterface(request.outboundInterface)

        guard FileManager.default.isExecutableFile(atPath: installedXrayPath) else {
            throw HelperError("Installed Xray runtime is missing. Reinstall Teleport's privileged helper.")
        }

        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
        let configPath = try writeHelperConfig(request.configData, helperStateDirectoryPath: helperStateDirectoryPath)
        try terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
        try terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
        try runShell(makeStartScript(
            helperStateDirectoryPath: helperStateDirectoryPath,
            configPath: configPath,
            protectedHost: protectedHost,
            tunnelInterfaceName: tunnelInterfaceName,
            outboundInterface: outboundInterface
        ))
        return managedXrayPID(pidFilePath: helperStateDirectoryPath + "/xray-tun.pid", expectedOwner: 0)
    }

    func stop(request: HelperRequest) throws {
        let stateDirectoryPath = try validatedStateDirectoryPath(request.stateDirectoryPath)
        let protectedHost = try validatedProtectedHost(request.protectedHost, required: false)
        let outboundInterface = try validatedOutboundInterface(request.outboundInterface)
        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
        try terminateManagedXray(helperStateDirectoryPath: helperStateDirectoryPath)
        try terminateLegacyManagedXray(stateDirectoryPath: stateDirectoryPath)
        try runShell(makeStopScript(
            helperStateDirectoryPath: helperStateDirectoryPath,
            protectedHost: protectedHost.isEmpty ? nil : protectedHost,
            outboundInterface: outboundInterface
        ))
    }

    func readLog(request: HelperRequest) throws -> (text: String, metadata: String) {
        let logName = try validatedLogName(request.logName)
        let maxBytes = max(1, min(request.maxBytes ?? 256 * 1024, maxLogReadBytes))
        let helperStateDirectoryPath = try preparedHelperStateDirectoryPath()
        let logPath = helperStateDirectoryPath + "/" + logName
        let data = try readTail(from: logPath, maxBytes: maxBytes)
        let text = String(data: data.contents, encoding: .utf8) ?? ""
        let metadata = logMetadata(path: logPath, totalBytes: data.totalBytes, returnedBytes: data.contents.count, wasTruncated: data.wasTruncated)
        return (data.wasTruncated ? "… showing last \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) …\n" + text : text, metadata)
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

    private func validatedProtectedHost(_ value: String?, required: Bool) throws -> String {
        guard let value, !value.isEmpty else {
            if required { throw HelperError("Missing protectedHost") }
            return ""
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

    private func validatedLogName(_ value: String?) throws -> String {
        switch value {
        case "xray-tun.log", "xray-tun-control.log", "xray-tun-config.json":
            return value!
        default:
            throw HelperError("Rejected invalid logName")
        }
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

    private func terminateManagedXray(helperStateDirectoryPath: String) throws {
        let pidFilePath = helperStateDirectoryPath + "/xray-tun.pid"
        guard let pid = managedXrayPID(pidFilePath: pidFilePath, expectedOwner: 0),
              isInstalledXrayProcess(pid: pid) else {
            return
        }
        try terminateInstalledXray(pid: pid)
    }

    private func terminateLegacyManagedXray(stateDirectoryPath: String) throws {
        let pidFilePath = stateDirectoryPath + "/xray-tun.pid"
        guard let pid = managedXrayPID(pidFilePath: pidFilePath, expectedOwner: consoleUserIDs().uid),
              isInstalledXrayProcess(pid: pid) else {
            return
        }
        try terminateInstalledXray(pid: pid)
    }

    private func terminateInstalledXray(pid: pid_t) throws {
        try signalInstalledXray(pid: pid, signal: SIGTERM)
        for _ in 0 ..< 10 {
            usleep(200_000)
            if !isInstalledXrayProcess(pid: pid) {
                return
            }
        }
        try signalInstalledXray(pid: pid, signal: SIGKILL)
    }

    private func managedXrayPID(pidFilePath: String, expectedOwner: uid_t) -> pid_t? {
        var statInfo = stat()
        guard lstat(pidFilePath, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_uid == expectedOwner,
              statInfo.st_size > 0,
              statInfo.st_size <= 32,
              let rawPID = try? String(contentsOfFile: pidFilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    private func signalInstalledXray(pid: pid_t, signal: Int32) throws {
        guard isInstalledXrayProcess(pid: pid) else {
            return
        }
        guard Darwin.kill(pid, signal) == 0 || errno == ESRCH else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func isInstalledXrayProcess(pid: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return false }
        let processPath = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath().path
        let expectedPath = URL(fileURLWithPath: installedXrayPath).resolvingSymlinksInPath().path
        return processPath == expectedPath
    }

    private func runShell(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdout = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        let stderr = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        drain(outputPipe, into: stdout)
        drain(errorPipe, into: stderr)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stopDraining(outputPipe, into: stdout)
            stopDraining(errorPipe, into: stderr)
            throw error
        }

        stopDraining(outputPipe, into: stdout)
        stopDraining(errorPipe, into: stderr)

        guard process.terminationStatus == 0 else {
            throw HelperError([stderr.text(), stdout.text()].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    private func drain(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }
    }

    private func stopDraining(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        collector.append(fileHandle.readDataToEndOfFile())
    }

    private func makeStartScript(helperStateDirectoryPath: String, configPath: String, protectedHost: String, tunnelInterfaceName: String, outboundInterface: String) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let logFile = helperStateDirectoryPath + "/xray-tun.log"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedDNSFile = helperStateDirectoryPath + "/xray-tun-protected-dns"
        let controlLogFile = helperStateDirectoryPath + "/xray-tun-control.log"

        return """
        set -eu
        HELPER_STATE_DIR=\(q(helperStateDirectoryPath))
        PID_FILE=\(q(pidFile))
        LOG_FILE=\(q(logFile))
        PROTECTED_HOST_FILE=\(q(protectedHostFile))
        PROTECTED_DNS_FILE=\(q(protectedDNSFile))
        CONTROL_LOG_FILE=\(q(controlLogFile))
        XRAY=\(q(installedXrayPath))
        XRAY_ASSET_DIR=\(q(PrivilegedHelperConstants.installedAssetDirectoryPath))
        CONFIG=\(q(configPath))
        PROTECTED_HOST=\(q(protectedHost))
        TUN_INTERFACE_NAME=\(q(tunnelInterfaceName))
        OUTBOUND_INTERFACE=\(q(outboundInterface))

        \(deleteHostRouteFunction())
        \(dnsRouteFunctions())
        \(directRouteFunctions())

        for helper_file in "$PID_FILE" "$LOG_FILE" "$PROTECTED_HOST_FILE" "$PROTECTED_DNS_FILE" "$CONTROL_LOG_FILE"; do
            [ ! -L "$helper_file" ] || rm -f "$helper_file"
        done

        touch "$CONTROL_LOG_FILE"
        chmod 600 "$CONTROL_LOG_FILE"
        printf '%s helper start requested for %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PROTECTED_HOST" >> "$CONTROL_LOG_FILE"

        if [ -f "$PROTECTED_HOST_FILE" ]; then
            old_protected_host=$(cat "$PROTECTED_HOST_FILE" 2>/dev/null || true)
            if [ -n "$old_protected_host" ]; then
                delete_host_route "$old_protected_host"
            fi
        fi
        cleanup_dns_routes
        cleanup_direct_routes

        route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
        route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true

        rm -f "$PID_FILE"
        : > "$LOG_FILE"
        chmod 600 "$LOG_FILE"
        printf '%s\n' "$PROTECTED_HOST" > "$PROTECTED_HOST_FILE"
        chmod 600 "$PROTECTED_HOST_FILE"

        delete_host_route "$PROTECTED_HOST"
        gateway=$(route -n get "$PROTECTED_HOST" 2>/dev/null | awk '/gateway:/{print $2; exit}')
        \(protectHostRouteCommands())
        protect_direct_routes "$gateway"
        protect_dns_routes

        cd "$HELPER_STATE_DIR"
        (
            trap '' HUP
            XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR"
            export XRAY_LOCATION_ASSET
            exec "$XRAY" run -c "$CONFIG"
        ) </dev/null >> "$LOG_FILE" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$PID_FILE"
        chmod 600 "$PID_FILE"
        printf '%s helper launched pid %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"

        tun_interface=""
        readiness_attempt=0
        while [ -z "$tun_interface" ] && [ "$readiness_attempt" -lt 20 ]; do
            sleep 0.5
            readiness_attempt=$((readiness_attempt + 1))

            \(protectHostRouteCommands())
            protect_dns_routes

            if ! kill -0 "$pid" >/dev/null 2>&1; then
                printf '%s pid %s exited during readiness wait\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                cat "$LOG_FILE" >&2 || true
                exit 1
            fi

            if ifconfig "$TUN_INTERFACE_NAME" >/dev/null 2>&1; then
                tun_interface="$TUN_INTERFACE_NAME"
            fi
            if [ -z "$tun_interface" ]; then
                tun_interface=$(ifconfig | awk '
                    /^utun[0-9]+:/ { iface=$1; sub(":", "", iface); next }
                    /inet 169\\.254\\./ { print iface; exit }
                    /inet 172\\.18\\.0\\.1/ { print iface; exit }
                    /inet 198\\.18\\./ { print iface; exit }
                ')
            fi
        done

        if [ -z "$tun_interface" ]; then
            reason="Teleport VPN started Xray, but macOS did not create a TUN interface."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            ifconfig >> "$CONTROL_LOG_FILE" 2>&1 || true
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
        route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
        if ! route add -net 0.0.0.0/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1; then
            reason="Teleport VPN could not install the lower IPv4 default route through Teleport's TUN."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi
        if ! route add -net 128.0.0.0/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1; then
            reason="Teleport VPN could not install the upper IPv4 default route through Teleport's TUN."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        \(protectHostRouteCommands())
        protect_direct_routes "$gateway"
        protect_dns_routes

        public_interface_low=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        public_interface_high=$(route -n get 129.0.0.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        protected_interface=$(route -n get "$PROTECTED_HOST" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        printf '%s pid %s running, tun %s, public low route %s, public high route %s, protected route %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" "$tun_interface" "${public_interface_low:-unknown}" "${public_interface_high:-unknown}" "${protected_interface:-unknown}" >> "$CONTROL_LOG_FILE"

        case "$public_interface_low" in
            utun*) ;;
            *)
                reason="Teleport VPN started Xray, but macOS did not route lower-half public traffic through Teleport's TUN. Disconnect other VPN apps and try again."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                netstat -rn -f inet >> "$CONTROL_LOG_FILE" 2>&1 || true
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        case "$public_interface_high" in
            utun*) ;;
            *)
                reason="Teleport VPN started Xray, but macOS did not route upper-half public traffic through Teleport's TUN. Disconnect other VPN apps and try again."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                netstat -rn -f inet >> "$CONTROL_LOG_FILE" 2>&1 || true
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        case "$protected_interface" in
            utun*)
                reason="Teleport VPN could not keep the proxy server route outside the tunnel. Disconnect other VPN apps and try again, or use System Proxy mode."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        printf '%s pid %s ready\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
        exit 0
        """
    }

    private func makeStopScript(helperStateDirectoryPath: String, protectedHost: String?, outboundInterface: String?) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedDNSFile = helperStateDirectoryPath + "/xray-tun-protected-dns"
        let configFile = helperStateDirectoryPath + "/xray-tun-config.json"
        let controlLogFile = helperStateDirectoryPath + "/xray-tun-control.log"

        var commands: [String] = []
        commands.append("OUTBOUND_INTERFACE=\(q(outboundInterface ?? ""))")
        commands.append("PROTECTED_DNS_FILE=\(q(protectedDNSFile))")
        commands.append("CONTROL_LOG_FILE=\(q(controlLogFile))")
        commands.append(deleteHostRouteFunction())
        commands.append(dnsRouteFunctions())
        commands.append(directRouteFunctions())
        commands.append("for helper_file in \(q(pidFile)) \(q(protectedHostFile)) \(q(protectedDNSFile)) \(q(controlLogFile)); do [ ! -L \"$helper_file\" ] || rm -f \"$helper_file\"; done")
        commands.append("touch \(q(controlLogFile)); chmod 600 \(q(controlLogFile))")
        commands.append("printf '%s helper stop requested\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" >> \(q(controlLogFile))")
        if let protectedHost, !protectedHost.isEmpty {
            commands.append("delete_host_route \(q(protectedHost))")
        } else {
            commands.append("if [ -f \(q(protectedHostFile)) ]; then protected_host=$(cat \(q(protectedHostFile)) 2>/dev/null || true); if [ -n \"$protected_host\" ]; then delete_host_route \"$protected_host\"; fi; fi")
        }
        commands.append("cleanup_dns_routes")
        commands.append("cleanup_direct_routes")
        commands.append("route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("rm -f \(q(pidFile))")
        commands.append("rm -f \(q(protectedHostFile))")
        commands.append("rm -f \(q(protectedDNSFile))")
        commands.append("rm -f \(q(configFile))")
        return commands.joined(separator: "; ")
    }

    private func deleteHostRouteFunction() -> String {
        """
        delete_host_route() {
            host="$1"
            current_interface=$(route -n get "$host" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
            for scoped_interface in "${OUTBOUND_INTERFACE:-}" "$current_interface" en0 en1 en2 bridge100; do
                [ -n "$scoped_interface" ] || continue
                i=0
                while route delete -host -ifscope "$scoped_interface" "$host" >/dev/null 2>&1; do
                    i=$((i + 1))
                    [ "$i" -ge 10 ] && break
                done
            done
            i=0
            while route delete -host "$host" >/dev/null 2>&1; do
                i=$((i + 1))
                [ "$i" -ge 10 ] && break
            done
        }
        """
    }

    private func dnsRouteFunctions() -> String {
        """
        is_public_ipv4() {
            ip="$1"
            case "$ip" in
                ""|*[!0-9.]*|*.*.*.*.*) return 1 ;;
            esac
            o1=${ip%%.*}
            rest=${ip#*.}
            o2=${rest%%.*}
            case "$o1" in
                0|10|127) return 1 ;;
                169) [ "$o2" = "254" ] && return 1 ;;
                172) [ "$o2" -ge 16 ] 2>/dev/null && [ "$o2" -le 31 ] 2>/dev/null && return 1 ;;
                192) [ "$o2" = "168" ] && return 1 ;;
            esac
            [ "$o1" -ge 224 ] 2>/dev/null && return 1
            return 0
        }

        cleanup_dns_routes() {
            if [ -f "$PROTECTED_DNS_FILE" ]; then
                while IFS= read -r dns_server; do
                    [ -n "$dns_server" ] || continue
                    delete_host_route "$dns_server"
                done < "$PROTECTED_DNS_FILE"
            fi
            rm -f "$PROTECTED_DNS_FILE"
        }

        protect_dns_routes() {
            : > "$PROTECTED_DNS_FILE"
            chmod 600 "$PROTECTED_DNS_FILE"
            scutil --dns 2>/dev/null | awk '/nameserver\\[[0-9]+\\]/{print $3}' | sort -u | while IFS= read -r dns_server; do
                is_public_ipv4 "$dns_server" || continue
                delete_host_route "$dns_server"
                dns_gateway=$(route -n get "$dns_server" 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)
                dns_interface=$(route -n get "$dns_server" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
                case "$dns_interface" in
                    utun*) dns_gateway="${gateway:-$dns_gateway}" ;;
                esac
                if [ -z "$dns_gateway" ]; then
                    dns_gateway="${gateway:-}"
                fi
                if [ -n "$dns_gateway" ]; then
                    route add -host "$dns_server" "$dns_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || route change -host "$dns_server" "$dns_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || true
                    printf '%s\n' "$dns_server" >> "$PROTECTED_DNS_FILE"
                fi
            done
        }
        """
    }

    private func directRouteFunctions() -> String {
        """
        cleanup_direct_routes() {
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            route delete -net 0.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
        }

        protect_direct_routes() {
            direct_gateway="$1"
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            [ "$OUTBOUND_INTERFACE" != "auto" ] || return 0
            [ -n "$direct_gateway" ] || return 0

            cleanup_direct_routes
            route add -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
            route add -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
        }
        """
    }

    private func protectHostRouteCommands() -> String {
        """
        if [ -n "$gateway" ]; then
            delete_host_route "$PROTECTED_HOST"
            route add -host "$PROTECTED_HOST" "$gateway" >> "$CONTROL_LOG_FILE" 2>&1 || route change -host "$PROTECTED_HOST" "$gateway" >> "$CONTROL_LOG_FILE" 2>&1 || true
        fi
        """
    }
}

private func consoleUserIDs() -> (uid: uid_t, gid: gid_t) {
    var statInfo = stat()
    if stat("/dev/console", &statInfo) == 0 {
        return (statInfo.st_uid, statInfo.st_gid)
    }
    return (0, 0)
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private final class BoundedOutputCollector {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes))
            truncated = true
        }
    }

    func text() -> String {
        lock.lock()
        let capturedData = data
        let wasTruncated = truncated
        lock.unlock()

        var output = String(decoding: capturedData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if wasTruncated {
            output = "[output truncated to last \(maxBytes) bytes]\n" + output
        }
        return output
    }
}

signal(SIGPIPE, SIG_IGN)
do {
    try HelperServer().run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("\(helperLabel): \(message)\n", stderr)
    exit(1)
}

struct HelperError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message.isEmpty ? "Privileged helper command failed" : message
    }

    var errorDescription: String? { message }
}
