import Darwin
import Foundation
import Network

/// Runs bundled Xray as the logged-in user for System Proxy mode. This manager
/// owns only the child process and its logs; `SystemProxyService` separately owns
/// macOS proxy settings. `@unchecked Sendable` means thread safety is promised by
/// this implementation rather than verified by the compiler.
nonisolated final class XrayRuntimeManager: @unchecked Sendable {
    private var process: Process?
    private var capture: XrayOutputCapture?
    private let bundle: Bundle
    private let executableURLProvider: (() -> URL?)?
    private let logDirectoryURLProvider: () -> URL
    private let logPolicyProvider: () throws -> XrayLogPolicy

    private let assetDirectoryURLProvider: () throws -> URL
    private let log: TeleportLog


    static let subsystem = "xray"

    /// Assets come from the same resolver TUN mode uses, so both modes see one
    /// geosite/geoip pair — the user's custom downloads when there are any, the
    /// bundled files otherwise. Asking the bundle directly does not work: the
    /// resource phase flattens the .dat files into Contents/Resources, so there is
    /// no asset directory in the bundle to point Xray at.
    init(
        bundle: Bundle = .main,
        assetDirectoryURLProvider: (() throws -> URL)? = nil,
        log: TeleportLog = .shared,
        executableURLProvider: (() -> URL?)? = nil,
        logDirectoryURLProvider: @escaping () -> URL = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("teleport", isDirectory: true)
        },
        logPolicyProvider: @escaping () throws -> XrayLogPolicy = { try XrayLogPolicy.load() }
    ) {
        self.bundle = bundle
        self.executableURLProvider = executableURLProvider
        self.logDirectoryURLProvider = logDirectoryURLProvider
        self.logPolicyProvider = logPolicyProvider
        self.log = log
        self.assetDirectoryURLProvider = assetDirectoryURLProvider ?? {
            try GeodataUpdateService().resolvedAssetDirectoryURL(bundle: bundle)
        }
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    deinit { stop() }

    func runtimeURL() -> URL? {
        if let executableURLProvider { return executableURLProvider() }
        return bundle.url(forResource: "xray", withExtension: nil)
    }

    var handshakeEvidence: WireGuardHandshakeEvidence? { capture?.handshakeEvidence }

    func start(configURL: URL, trackWireGuardHandshake: Bool = false) throws {
        guard process?.isRunning != true else { return }
        // Retire the previous run before opening the same log path for another run.
        stop()
        capture = nil
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
        let directory = logDirectoryURLProvider()
        let policy: XrayLogPolicy
        do { policy = try logPolicyProvider() }
        catch {
            log.warn(Self.subsystem, "Invalid internal Xray log policy; using 5 MiB / 7 day defaults")
            policy = .standard
        }
        let capture = try XrayOutputCapture(reader: pipe.fileHandleForReading, directory: directory, policy: policy,
                                            trackWireGuardHandshake: trackWireGuardHandshake)
        self.capture = capture

        process.standardError = pipe
        process.standardOutput = pipe


        // Reacting to the death — restoring proxy settings, failing the session —
        // is the provider's job, which supervises `isRunning`. This only records
        // that it happened and how, since the provider cannot see the exit status.
        process.terminationHandler = { [log, capture] process in
            guard !capture.expectsExit else { return }
            let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
            log.warn(Self.subsystem, "xray exited on its own (\(how) \(process.terminationStatus)); the session will be failed and settings restored")
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            capture.close()
            throw error
        }
        // Only the child retains the writer; its exit now produces EOF for this capture.
        try? pipe.fileHandleForWriting.close()
        self.process = process
    }

    func waitUntilLocalProxyReady(endpoint: ProxyEndpoint, timeout: TimeInterval = 3) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(timeout)

        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
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
            capture?.close()
            return
        }

        if process.isRunning {
            capture?.expectExit()
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
        capture?.close()
    }

    func stopAndCaptureErrorOutput() -> String? {
        stop()
        return capturedErrorOutput()
    }

    func capturedErrorOutput() -> String? {
        capture?.capturedOutput()
    }

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
                return "Teleport's bundled Xray executable is missing. Reinstall Teleport from a fresh copy before connecting again."
            case .startupTimedOut:
                return "Xray did not become ready in time. Close other VPN or proxy apps and try again. If this repeats, refresh the subscription or reimport the portal."
            }
        }

        var failureReason: String? {
            if case let .startupTimedOut(details) = self { return details }
            return nil
        }
    }
}
