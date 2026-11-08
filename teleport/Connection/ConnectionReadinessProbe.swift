import Foundation

/// Confirms traffic through the new session's explicit local proxy. Those
/// inbounds always select the portal, even when split routing defaults to direct.
nonisolated struct ConnectionReadinessProbe: Sendable {
    let targets: [URL]
    let timeout: TimeInterval

    init(targets: [URL] = [
        URL(string: "https://cp.cloudflare.com/generate_204")!,
        URL(string: "https://www.gstatic.com/generate_204")!
    ], timeout: TimeInterval = 8) {
        self.targets = targets
        self.timeout = timeout
    }

    func verify(_ request: ConnectionRequest) async throws {
        // A private-subnet WireGuard peer is not an Internet gateway. Public
        // requests cannot establish its readiness; retain its existing behavior.
        if let peer = request.configuration.wireguard, !peer.carriesDefaultRoute { return }
        try await verify(endpoint: request.localProxy)
    }

    func verify(endpoint: ProxyEndpoint) async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: String?.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let transfer = ProxyVerificationTransfer()
                        try await withTaskCancellationHandler {
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                DispatchQueue.global(qos: .utility).async {
                                    continuation.resume(with: Result {
                                        try transfer.run(target: target, endpoint: endpoint, timeout: timeout)
                                    })
                                }
                            }
                            try Task.checkCancellation()
                        } onCancel: {
                            transfer.cancel()
                        }
                        return nil
                    } catch {
                        try Task.checkCancellation()
                        return (error as? Failure)?.details ?? error.localizedDescription
                    }
                }
            }
            var failures: [String] = []
            while let result = try await group.next() {
                if let result { failures.append(result) }
                else {
                    group.cancelAll()
                    return
                }
            }
            try Task.checkCancellation()
            throw Failure(details: failures.joined(separator: "\n"))
        }
    }

    struct Failure: LocalizedError {
        let details: String
        var errorDescription: String? { "Could not verify the connection through this portal." }
        var failureReason: String? {
            "The connection-check endpoints could not be reached through the portal. Try again or choose another portal.\n\(details)"
        }
    }
}

/// CFNetwork bypasses explicit proxies for loopback destinations on macOS. Curl's
/// explicit empty bypass list makes the tested path unambiguous, including tests.
nonisolated private final class ProxyVerificationTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(target: URL, endpoint: ProxyEndpoint, timeout: TimeInterval) throws {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["--disable", "--silent", "--noproxy", "",
                          "--proxy", "http://\(endpoint.host):\(endpoint.httpPort)",
                          "--connect-timeout", String(timeout), "--max-time", String(timeout),
                          "--head", "--output", "/dev/null", "--write-out", "%{http_code}", target.absoluteString]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() }
        catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        let status = Int(String(decoding: data, as: UTF8.self)) ?? 0
        guard task.terminationStatus == 0, (200...499).contains(status) else {
            let detail: String
            switch task.terminationStatus {
            case 28: detail = "Connection check timed out."
            case 35, 60: detail = "TLS handshake failed during the connection check."
            case 5, 6: detail = "DNS resolution failed during the connection check."
            case 7: detail = "The local proxy could not be reached."
            default: detail = "The portal did not complete the connection check (transport \(task.terminationStatus), HTTP \(status))."
            }
            throw ConnectionReadinessProbe.Failure(details: detail)
        }
    }
}
