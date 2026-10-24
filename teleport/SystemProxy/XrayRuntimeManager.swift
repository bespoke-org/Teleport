import Darwin
import Foundation
import Network

/// Runs bundled Xray as the logged-in user for System Proxy mode. This manager
/// owns only the child process and its logs; `SystemProxyService` separately owns
/// macOS proxy settings. `@unchecked Sendable` means thread safety is promised by
/// this implementation rather than verified by the compiler.
nonisolated final class XrayRuntimeManager: @unchecked Sendable {
    private var process: Process?
    private var errorPipe: Pipe?
    private var logFileHandle: FileHandle?
    private let bundle: Bundle
    private let errorBufferLock = NSLock()
    private var errorBuffer = Data()
    private let assetDirectoryURLProvider: () throws -> URL
    private let log: TeleportLog
    /// Set by `stop()` before it signals the child, so its termination handler can
    /// tell an exit that was asked for from one that was not. Guarded by
    /// `errorBufferLock`, which already serializes the handler's other access.
    private var expectsExit = false

    static let subsystem = "xray"

    /// Assets come from the same resolver TUN mode uses, so both modes see one
    /// geosite/geoip pair — the user's custom downloads when there are any, the
    /// bundled files otherwise. Asking the bundle directly does not work: the
    /// resource phase flattens the .dat files into Contents/Resources, so there is
    /// no asset directory in the bundle to point Xray at.
    init(
        bundle: Bundle = .main,
        assetDirectoryURLProvider: (() throws -> URL)? = nil,
        log: TeleportLog = .shared
    ) {
        self.bundle = bundle
        self.log = log
        self.assetDirectoryURLProvider = assetDirectoryURLProvider ?? {
            try GeodataUpdateService().resolvedAssetDirectoryURL(bundle: bundle)
        }
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func runtimeURL() -> URL? {
        bundle.url(forResource: "xray", withExtension: nil)
    }

    func start(configURL: URL) throws {
        guard process?.isRunning != true else { return }
        guard let runtimeURL = runtimeURL() else {
            throw RuntimeError.binaryNotFound
        }

        let process = Process()
        process.executableURL = runtimeURL
        process.arguments = ["run", "-c", configURL.path]

        let environment = ProcessInfo.processInfo.environment.merging([
            "XRAY_LOCATION_ASSET": try assetDirectoryURLProvider().path
        ]) { _, new in new }
        process.environment = environment

        let pipe = Pipe()
        let logFileHandle = try makeLogFileHandle()
        errorBufferLock.lock()
        errorBuffer = Data()
        expectsExit = false
        errorBufferLock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.errorBufferLock.lock()
            self.errorBuffer.append(data)
            self.errorBufferLock.unlock()
            self.logFileHandle?.write(data)
        }

        process.standardError = pipe
        process.standardOutput = pipe
        errorPipe = pipe
        self.logFileHandle = logFileHandle

        // Reacting to the death — restoring proxy settings, failing the session —
        // is the provider's job, which supervises `isRunning`. This only records
        // that it happened and how, since the provider cannot see the exit status.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.errorBufferLock.lock()
            let expected = self.expectsExit
            self.errorBufferLock.unlock()
            guard !expected else { return }
            let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
            self.log.warn(Self.subsystem, "xray exited on its own (\(how) \(process.terminationStatus)); the session will be failed and settings restored")
        }
        try process.run()
        self.process = process
    }

    func waitUntilLocalProxyReady(endpoint: ProxyEndpoint, timeout: TimeInterval = 3) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(timeout)

        while clock.now < deadline {
            guard process?.isRunning == true else { return false }

            if await Self.canOpenTCPConnection(host: endpoint.host, port: endpoint.httpPort, timeout: 0.2),
               await Self.canOpenTCPConnection(host: endpoint.host, port: endpoint.socksPort, timeout: 0.2) {
                return true
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return false
    }

    func stop() {
        guard let process else {
            cleanupPipe()
            return
        }

        if process.isRunning {
            errorBufferLock.lock()
            expectsExit = true
            errorBufferLock.unlock()
            process.terminate()

            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }

            process.waitUntilExit()
        }

        self.process = nil
        cleanupPipe()
    }

    func stopAndCaptureErrorOutput() -> String? {
        stop()
        return capturedErrorOutput()
    }

    func capturedErrorOutput() -> String? {
        errorBufferLock.lock()
        defer { errorBufferLock.unlock() }
        guard !errorBuffer.isEmpty else { return nil }
        return String(data: errorBuffer, encoding: .utf8)
    }

    private func cleanupPipe() {
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    /// Appends rather than truncates: the output of the run that just died is the
    /// output worth reading, and truncating at the next start — which is what a user
    /// does immediately after a failure — destroyed it before anyone could look.
    private func makeLogFileHandle() throws -> FileHandle {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("xray.log")

        // Appending forever is the other way to lose the log, so one previous
        // generation is kept and older output is dropped at a bounded size. The
        // check happens only here: Xray writes to the descriptor directly for the
        // life of the run, so the file cannot be rotated underneath it, and a long
        // session at a verbose log level grows past the limit until the next start.
        let currentBytes = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)??.intValue ?? 0
        if currentBytes > Self.maximumLogBytes {
            let rotatedURL = directory.appendingPathComponent("xray.log.1")
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: logURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n===== xray started \(TeleportLog.timestamp()) =====\n".utf8))
        return handle
    }

    private static let maximumLogBytes = 5 * 1024 * 1024

    private static func canOpenTCPConnection(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let rawPort = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                let lock = NSLock()
                var didResume = false
            }

            let resumeState = ResumeState()
            let queue = DispatchQueue(label: "dev.x.teleport.xray-readiness", qos: .userInitiated)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

            @Sendable func finish(_ isReady: Bool) {
                resumeState.lock.lock()
                defer { resumeState.lock.unlock() }
                guard !resumeState.didResume else { return }
                resumeState.didResume = true
                connection.cancel()
                continuation.resume(returning: isReady)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    enum RuntimeError: LocalizedError {
        case binaryNotFound
        case startupTimedOut(String?)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Bundled Xray binary was not found in the app resources."
            case .startupTimedOut(let detail):
                if let detail, !detail.isEmpty {
                    return "Xray did not become ready: \(detail)"
                }
                return "Xray did not become ready before enabling the system proxy."
            }
        }
    }
}
