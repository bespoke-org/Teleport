import Darwin
import Foundation

/// A private per-user socket. No network listener, root access or Keychain access.
nonisolated enum MCPLocalTransport {
    static let maximumBytes = 2 * 1024 * 1024
    static var directory: String { "/tmp/dev.x.teleport-mcp-\(getuid())" }
    static var socketPath: String { directory + "/socket" }

    static func prepareDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw MCPFailure("Cannot create MCP directory") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw MCPFailure("MCP directory must be owned by this user with permissions 0700")
        }
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MCPFailure("MCP socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw MCPFailure("MCP peer belongs to another user") }
    }

    static func readFrame(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw MCPFailure("MCP connection ended or timed out; read state before retrying a change") }
            if let end = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                guard data.count <= maximumBytes else { break }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw MCPFailure("MCP message exceeds 2 MiB")
    }

    static func writeFrame(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumBytes else { throw MCPFailure("MCP response exceeds 2 MiB") }
        var framed = data
        framed.append(10)
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MCPFailure("MCP write failed; read state before retrying a change") }
                offset += count
            }
        }
    }

    static func exchange(_ data: Data, path: String = socketPath) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPFailure("Cannot open MCP socket") }
        defer { close(fd) }
        configure(fd)
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else { throw MCPFailure("Open Teleport and enable MCP access in Settings → Advanced") }
        try verifyPeer(fd)
        try writeFrame(data, to: fd)
        return try readFrame(fd)
    }

    /// Runs before SwiftUI/AppViewModel initialization, so the bridge cannot start a VPN.
    static func runStdio() {
        signal(SIGPIPE, SIG_IGN)
        let session = MCPProtocolSession(call: { try exchange($0) })
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[..<count])
            while let end = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<end])
                pending.removeSubrange(...end)
                guard frame.count <= maximumBytes else { return }
                if let reply = session.respond(to: frame) {
                    do { try writeFrame(reply, to: STDOUT_FILENO) } catch { return }
                }
            }
            if pending.count > maximumBytes { return }
        }
    }
}

nonisolated final class MCPLocalServer {
    private let source: DispatchSourceRead
    private let stopped = NSLock()
    private let closed = DispatchSemaphore(value: 0)
    private var didStop = false

    init(directory: String = MCPLocalTransport.directory, handle: @escaping @Sendable (Data) async -> Data) throws {
        try MCPLocalTransport.prepareDirectory(directory)
        let path = directory + "/socket"
        let lockFD = open(directory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw MCPFailure("Cannot open MCP lock") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            throw MCPFailure("Another Teleport instance already owns MCP access")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lockFD); throw MCPFailure("Cannot open MCP listener") }
        do {
            MCPLocalTransport.configure(fd)
            _ = unlink(path) // Only the lock owner may remove a stale socket.
            guard try MCPLocalTransport.withAddress(path, { bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, listen(fd, 8) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw MCPFailure("Cannot listen for MCP requests") }
        } catch {
            close(fd); unlink(path); close(lockFD)
            throw error
        }
        let queue = DispatchQueue(label: "dev.x.teleport.mcp.listener")
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let slots = DispatchSemaphore(value: 8)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else { close(client); return }
            MCPLocalTransport.configure(client)
            DispatchQueue.global(qos: .utility).async {
                defer { close(client); slots.signal() }
                do {
                    try MCPLocalTransport.verifyPeer(client)
                    let request = try MCPLocalTransport.readFrame(client)
                    let response = MCPResponseBox()
                    let completed = DispatchSemaphore(value: 0)
                    let task = Task {
                        response.set(await handle(request))
                        completed.signal()
                    }
                    guard completed.wait(timeout: .now() + 25) == .success else { task.cancel(); return }
                    if let data = response.get() { try MCPLocalTransport.writeFrame(data, to: client) }
                } catch { /* Transport errors close this connection without exposing payloads. */ }
            }
        }
        let closed = self.closed
        source.setCancelHandler { close(fd); unlink(path); close(lockFD); closed.signal() }
        source.resume()
    }

    func stop() {
        stopped.lock()
        defer { stopped.unlock() }
        guard !didStop else { return }
        didStop = true
        source.cancel()
        closed.wait()
    }
    deinit { stop() }
}

nonisolated private final class MCPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
