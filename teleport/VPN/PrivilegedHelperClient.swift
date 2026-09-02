import Foundation
import Darwin

/// User-side endpoint of the privileged-helper protocol. Each method opens one
/// Unix-domain socket, sends one JSON request, half-closes the write side to mark
/// end-of-request, and then waits for one JSON response from the root helper.
struct PrivilegedHelperClient: Sendable {
    static let expectedVersion = PrivilegedHelperConstants.version
    static let label = PrivilegedHelperConstants.label
    static let socketPath = PrivilegedHelperConstants.socketPath
    static let installedToolPath = PrivilegedHelperConstants.installedToolPath
    static let installedXrayPath = PrivilegedHelperConstants.installedXrayPath
    static let launchDaemonPlistPath = PrivilegedHelperConstants.launchDaemonPlistPath

    /// Prevents a dead helper from blocking the app's serial operation queue forever.
    // TODO(gpt-5.6-sol): The same five-second receive deadline is also treated as the
    // completion deadline for `start`, while the helper may spend at least ten seconds
    // waiting for a TUN interface. A socket timeout does not cancel root-side work, so
    // the app can report failure while Xray and its routes become active. Introduce a
    // session/request ID, command-specific deadlines, and post-timeout reconciliation
    // that adopts or stops the matching helper-owned session.
    private static let socketIOTimeout = timeval(tv_sec: 5, tv_usec: 0)

    func status() throws -> PrivilegedHelperResponse {
        try send(PrivilegedHelperRequest(command: "status"))
    }

    func start(session: XrayTunLaunchSession, paths: XrayTunRuntimePaths) throws -> pid_t? {
        let response = try send(PrivilegedHelperRequest(
            command: "start",
            stateDirectoryPath: paths.stateDirectoryURL.path,
            configPath: nil,
            configData: session.configData,
            protectedHost: session.protectedHost,
            tunnelInterfaceName: session.tunnelInterfaceName,
            outboundInterface: session.outboundInterface,
            pid: nil
        ))
        try response.validate()
        return response.details.flatMap(pid_t.init)
    }

    func stop(paths: XrayTunRuntimePaths, protectedHost: String?, outboundInterface: String?) throws {
        let response = try send(PrivilegedHelperRequest(
            command: "stop",
            stateDirectoryPath: paths.stateDirectoryURL.path,
            configPath: nil,
            configData: nil,
            protectedHost: protectedHost,
            tunnelInterfaceName: nil,
            outboundInterface: outboundInterface,
            pid: nil
        ))
        try response.validate()
    }

    func readLog(logName: String, maxBytes: Int) throws -> PrivilegedHelperResponse {
        try send(PrivilegedHelperRequest(
            command: "readLog",
            logName: logName,
            maxBytes: maxBytes
        ))
    }

    /// Performs the transport exchange only. Command success is checked by callers
    /// because `status` and `readLog` also need access to unsuccessful response details.
    private func send(_ request: PrivilegedHelperRequest) throws -> PrivilegedHelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw PrivilegedHelperClientError.unavailable("Helper socket path is too long")
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
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard connectResult == 0 else {
            throw PrivilegedHelperClientError.unavailable(String(cString: strerror(errno)))
        }

        var receiveTimeout = Self.socketIOTimeout
        var sendTimeout = Self.socketIOTimeout
        // TODO(gpt-5.6-sol): Check both `setsockopt` return values. If either call
        // fails, the code currently proceeds under the false assumption that I/O
        // is bounded and can still block the operation queue indefinitely.
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        let requestData = try JSONEncoder().encode(request)
        try writeAll(requestData, to: fd)
        shutdown(fd, SHUT_WR)

        let responseData = try readAll(from: fd)
        guard !responseData.isEmpty else {
            throw PrivilegedHelperClientError.invalidResponse("The privileged helper returned an empty response")
        }
        return try JSONDecoder().decode(PrivilegedHelperResponse.self, from: responseData)
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw PrivilegedHelperClientError.unavailable("Timed out writing to the privileged helper")
                } else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw PrivilegedHelperClientError.unavailable("Timed out reading from the privileged helper")
            } else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        return data
    }
}

/// JSON wire representation shared conceptually with `HelperRequest` in the helper.
/// `Codable` provides JSON encoding/decoding; `Sendable` allows the value to cross
/// Swift concurrency boundaries. The two independently compiled structs must evolve
/// together because there is currently no capability negotiation.
struct PrivilegedHelperRequest: Codable, Sendable {
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

    init(
        command: String,
        stateDirectoryPath: String? = nil,
        configPath: String? = nil,
        configData: Data? = nil,
        protectedHost: String? = nil,
        tunnelInterfaceName: String? = nil,
        outboundInterface: String? = nil,
        pid: Int32? = nil,
        logName: String? = nil,
        maxBytes: Int? = nil
    ) {
        self.command = command
        self.stateDirectoryPath = stateDirectoryPath
        self.configPath = configPath
        self.configData = configData
        self.protectedHost = protectedHost
        self.tunnelInterfaceName = tunnelInterfaceName
        self.outboundInterface = outboundInterface
        self.pid = pid
        self.logName = logName
        self.maxBytes = maxBytes
    }
}

/// Generic wire response. `details` is currently overloaded as either a PID,
/// log contents, or diagnostics depending on the command.
struct PrivilegedHelperResponse: Codable, Sendable {
    var success: Bool
    var version: String?
    var summary: String?
    var details: String?

    func validate() throws {
        guard success else {
            throw PrivilegedHelperClientError.commandFailed(
                summary?.isEmpty == false ? summary! : "Privileged helper command failed",
                details
            )
        }
    }
}

enum PrivilegedHelperClientError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case commandFailed(String, String?)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return "Teleport privileged helper is not running: \(message)"
        case let .invalidResponse(message):
            return message
        case let .commandFailed(summary, _):
            return summary
        }
    }

    var failureReason: String? {
        switch self {
        case let .commandFailed(_, details):
            return details
        default:
            return nil
        }
    }
}
