import Darwin
import Foundation

/// Root IPC server. Filesystem permissions make the socket reachable, while
/// `ClientAuthenticator` is the actual security boundary: it checks both the
/// active console UID and the connecting process's code signature before input.
final class HelperServer {
    private let authenticator: ClientAuthenticator

    init(authenticator: ClientAuthenticator = ClientAuthenticator()) {
        self.authenticator = authenticator
    }

    func run() throws {
        let serverFD = try makeListeningSocket()
        defer {
            close(serverFD)
            unlink(socketPath)
        }

        // TODO(gpt-5.6-sol): The accept loop handles request reading and command
        // execution synchronously. A slow `start` therefore blocks `status`, logs,
        // and—most importantly—`stop`; an authenticated client that never sends EOF
        // can block the server indefinitely because accepted sockets have no I/O
        // deadline. Use bounded reads plus a serialized lifecycle state machine that
        // still permits status and cancellation/reconciliation while start is pending.
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
        // Mode 0666 provides transport reachability only; every accepted peer is
        // still rejected unless UID and code-signature authorization both succeed.
        // TODO(gpt-5.6-sol, needs verification): Define and test behavior across the
        // login window and Fast User Switching. Socket ownership is captured once,
        // while authorization recomputes `/dev/console`, so the effective user can
        // change during this long-lived daemon's lifetime.
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
            try authenticator.authorizePeer(fd)
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

    private func handle(_ request: HelperRequest) -> HelperResponse {
        do {
            switch request.command {
            case "status":
                let status = try XrayTunController().status(request: StatusRequest())
                return HelperResponse(success: true, version: status.helperVersion, summary: status.summary, details: status.details)
            case "start":
                guard let stateDirectoryPath = request.stateDirectoryPath,
                      let configData = request.configData,
                      let protectedHost = request.protectedHost,
                      let tunnelInterfaceName = request.tunnelInterfaceName else {
                    throw HelperError("Missing privileged start request field")
                }
                let response = try XrayTunController().start(
                    request: StartSessionRequest(
                        stateDirectoryPath: stateDirectoryPath,
                        configData: configData,
                        protectedHost: protectedHost,
                        tunnelInterfaceName: tunnelInterfaceName,
                        outboundInterface: request.outboundInterface ?? ""
                    ),
                    sessionID: UUID()
                )
                return HelperResponse(success: true, version: helperVersion, summary: response.summary, details: response.details)
            case "stop":
                guard let stateDirectoryPath = request.stateDirectoryPath else {
                    throw HelperError("Missing stateDirectoryPath")
                }
                let response = try XrayTunController().stop(
                    request: StopSessionRequest(
                        stateDirectoryPath: stateDirectoryPath,
                        protectedHost: request.protectedHost,
                        outboundInterface: request.outboundInterface
                    ),
                    sessionID: UUID()
                )
                return HelperResponse(success: true, version: helperVersion, summary: response.summary, details: response.details)
            case "readLog":
                let log: VPNHelperLog
                switch request.logName {
                case "xray-tun.log":
                    log = .xray
                case "xray-tun-control.log":
                    log = .control
                default:
                    throw HelperError("Rejected invalid logName")
                }
                let response = try XrayTunController().readDiagnostics(
                    request: ReadDiagnosticsRequest(
                        log: log,
                        maximumBytes: request.maxBytes ?? VPNHelperProtocol.maximumDiagnosticsBytes
                    )
                )
                return HelperResponse(success: true, version: helperVersion, summary: response.metadata, details: response.text)
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
