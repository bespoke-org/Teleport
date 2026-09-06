import Foundation
import Network

struct ConnectionHealthProbeResult {
    let state: ConnectionHealthState
    let checkedAt: Date
    let latencyMilliseconds: Int?
    let latencyKind: ConnectionHealthLatencyKind?
    let failureSummary: String?
}

final class ConnectionHealthProbeService: @unchecked Sendable {
    private let attemptCount: Int
    private let tcpTimeoutSeconds: Int
    private let tunnelProbeTimeoutSeconds: Int
    private let tunnelProbeURL: URL
    private let bundle: Bundle
    private let fileManager: FileManager

    init(
        attemptCount: Int = 4,
        tcpTimeoutSeconds: Int = 3,
        tunnelProbeTimeoutSeconds: Int = 8,
        tunnelProbeURL: URL = URL(string: "https://cp.cloudflare.com/generate_204")!,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        self.attemptCount = max(1, attemptCount)
        self.tcpTimeoutSeconds = max(1, tcpTimeoutSeconds)
        self.tunnelProbeTimeoutSeconds = max(2, tunnelProbeTimeoutSeconds)
        self.tunnelProbeURL = tunnelProbeURL
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func probe(_ connection: SavedConnection) async -> ConnectionHealthProbeResult {
        guard UInt16(exactly: connection.configuration.port) != nil else {
            return ConnectionHealthProbeResult(
                state: .unreachable,
                checkedAt: Date(),
                latencyMilliseconds: nil,
                latencyKind: nil,
                failureSummary: "Invalid port"
            )
        }

        let checkedAt = Date()
        let tunnelResult = await proxyLatencyCheck(connection)

        if let tunnelLatency = tunnelResult.latencyMilliseconds {
            return ConnectionHealthProbeResult(
                state: .reachable,
                checkedAt: checkedAt,
                latencyMilliseconds: tunnelLatency,
                latencyKind: .proxyRequest,
                failureSummary: nil
            )
        }

        return ConnectionHealthProbeResult(
            state: .unreachable,
            checkedAt: checkedAt,
            latencyMilliseconds: nil,
            latencyKind: nil,
            failureSummary: tunnelResult.failureSummary ?? "Unavailable"
        )
    }

    private func tcpAvailabilityCheck(_ connection: SavedConnection) async -> (isReachable: Bool, latencyMilliseconds: Int?, failureSummary: String?) {
        guard let rawPort = UInt16(exactly: connection.configuration.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            return (false, nil, "Invalid port")
        }

        let host = NWEndpoint.Host(connection.configuration.host)
        var successfulLatencies: [Int] = []
        var lastFailureSummary: String?

        for _ in 0..<attemptCount {
            let sample = await tcpLatencySample(host: host, port: port, connectionID: connection.id)
            if sample.isReachable, let latency = sample.latencyMilliseconds {
                successfulLatencies.append(latency)
            } else {
                lastFailureSummary = sample.failureSummary
            }
        }

        guard !successfulLatencies.isEmpty else {
            return (false, nil, lastFailureSummary ?? "Unavailable")
        }

        return (true, Self.bestObservedLatency(successfulLatencies), nil)
    }

    private func proxyLatencyCheck(_ connection: SavedConnection) async -> (latencyMilliseconds: Int?, failureSummary: String?) {
        let probeEndpoint = temporaryProbeEndpoint()
        let runtimeManager = XrayRuntimeManager(bundle: bundle)
        let writer = XrayConfigurationWriter(proxyEndpoint: probeEndpoint)
        let probeDirectory = fileManager.temporaryDirectory.appendingPathComponent("teleport-health-\(connection.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        let configURL = probeDirectory.appendingPathComponent("xray-config.json")

        defer {
            try? fileManager.removeItem(at: probeDirectory)
        }

        do {
            _ = try writer.writeConfig(for: connection.configuration, to: configURL)
            try runtimeManager.start(configURL: configURL)
            let isReady = await waitForLocalProxyReady(endpoint: probeEndpoint, connectionID: connection.id)
            guard isReady else {
                let runtimeError = runtimeManager.stopAndCaptureErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, runtimeError.map(Self.summarizedRuntimeFailure) ?? "Proxy startup timed out")
            }

            let requestResult = try await proxyRequestLatencySample(endpoint: probeEndpoint)
            runtimeManager.stop()
            return (requestResult, nil)
        } catch {
            let runtimeError = runtimeManager.stopAndCaptureErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let runtimeError, !runtimeError.isEmpty {
                return (nil, Self.summarizedRuntimeFailure(runtimeError))
            }
            return (nil, Self.summarizedProbeFailure(error))
        }
    }

    private func proxyRequestLatencySample(endpoint: ProxyEndpoint) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(tunnelProbeTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(tunnelProbeTimeoutSeconds)
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: endpoint.host,
            kCFNetworkProxiesHTTPPort as String: endpoint.httpPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: endpoint.host,
            kCFNetworkProxiesHTTPSPort as String: endpoint.httpPort
        ]

        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }

        let probeCandidates = [
            tunnelProbeURL,
            URL(string: "https://www.gstatic.com/generate_204")!,
            URL(string: "https://www.google.com/generate_204")!
        ]

        var lastError: Error?

        for probeURL in probeCandidates {
            do {
                var request = URLRequest(url: probeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: TimeInterval(tunnelProbeTimeoutSeconds))
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")

                let startTime = DispatchTime.now().uptimeNanoseconds
                let (_, response) = try await session.data(for: request)
                let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ProbeError.invalidResponse
                }

                guard (200 ... 399).contains(httpResponse.statusCode) else {
                    throw ProbeError.httpStatus(httpResponse.statusCode)
                }

                return max(1, Int((Double(elapsedNanoseconds) / 1_000_000).rounded()))
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProbeError.invalidResponse
    }

    private func waitForLocalProxyReady(endpoint: ProxyEndpoint, connectionID: UUID) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.httpPort)) else {
            return false
        }

        let host = NWEndpoint.Host(endpoint.host)
        let attemptLimit = 20

        for _ in 0..<attemptLimit {
            let sample = await tcpLatencySample(host: host, port: port, connectionID: connectionID)
            if sample.isReachable {
                return true
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        return false
    }

    private func temporaryProbeEndpoint() -> ProxyEndpoint {
        let basePort = Int.random(in: 20000 ... 45000)
        return ProxyEndpoint(host: "127.0.0.1", httpPort: basePort, socksPort: basePort + 1)
    }

    private func tcpLatencySample(host: NWEndpoint.Host, port: NWEndpoint.Port, connectionID: UUID) async -> (isReachable: Bool, latencyMilliseconds: Int?, failureSummary: String?) {
        let startTime = DispatchTime.now().uptimeNanoseconds

        return await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                let lock = NSLock()
                var didResume = false
            }

            let resumeState = ResumeState()
            let queue = DispatchQueue(label: "dev.x.teleport.health-probe.\(connectionID.uuidString)", qos: .utility)
            let nwConnection = NWConnection(host: host, port: port, using: .tcp)

            @Sendable func finish(isReachable: Bool, latencyMilliseconds: Int?, failureSummary: String?) {
                resumeState.lock.lock()
                defer { resumeState.lock.unlock() }
                guard !resumeState.didResume else { return }
                resumeState.didResume = true
                nwConnection.cancel()
                continuation.resume(returning: (isReachable, latencyMilliseconds, failureSummary))
            }

            nwConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime
                    let latency = max(1, Int((Double(elapsedNanoseconds) / 1_000_000).rounded()))
                    finish(isReachable: true, latencyMilliseconds: latency, failureSummary: nil)
                case .failed(let error):
                    finish(isReachable: false, latencyMilliseconds: nil, failureSummary: Self.summarizedConnectionFailure(error))
                default:
                    break
                }
            }

            nwConnection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(tcpTimeoutSeconds)) {
                finish(isReachable: false, latencyMilliseconds: nil, failureSummary: "Timed out")
            }
        }
    }

    private nonisolated static func summarizedConnectionFailure(_ error: NWError) -> String {
        switch error {
        case .dns:
            return "DNS resolution failed"
        case .posix(let code):
            if code == .ECONNREFUSED {
                return "Connection refused"
            }
            if code == .ETIMEDOUT {
                return "Timed out"
            }
            let message = String(describing: code).trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "TCP probe failed" : message
        default:
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("timed out") {
                return "Timed out"
            }
            return message.isEmpty ? "TCP probe failed" : message
        }
    }

    private nonisolated static func bestObservedLatency(_ values: [Int]) -> Int {
        values.min() ?? 0
    }

    private nonisolated static func summarizedProbeFailure(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return summarizedURLErrorCode(urlError.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return summarizedURLErrorCode(URLError.Code(rawValue: nsError.code))
        }

        if nsError.domain == kCFErrorDomainCFNetwork as String {
            return "Network error"
        }

        if let probeError = error as? ProbeError {
            switch probeError {
            case .invalidResponse:
                return "Invalid probe response"
            case .httpStatus(let statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return "Probe blocked"
                }
                if (500 ... 599).contains(statusCode) {
                    return "Server error"
                }
                return "Probe request failed"
            }
        }

        return summarizedRuntimeFailure(error.localizedDescription)
    }

    private nonisolated static func summarizedRuntimeFailure(_ message: String) -> String {
        let firstLine = message
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if firstLine.contains("timed out") {
            return "Timed out"
        }
        if firstLine.contains("tls") || firstLine.contains("certificate") || firstLine.contains("ssl") {
            return "TLS handshake failed"
        }
        if firstLine.contains("dns") || firstLine.contains("no such host") {
            return "DNS resolution failed"
        }
        if firstLine.contains("refused") {
            return "Connection refused"
        }
        if firstLine.contains("network") {
            return "Network error"
        }
        if firstLine.contains("forbidden") || firstLine.contains("blocked") {
            return "Probe blocked"
        }
        if firstLine.contains("invalid") {
            return "Invalid probe response"
        }

        return "Probe failed"
    }

    private nonisolated static func summarizedURLErrorCode(_ code: URLError.Code) -> String {
        switch code {
        case .unknown:
            return "Network error"
        default:
            break
        }

        switch code {
        case .appTransportSecurityRequiresSecureConnection:
            return "Probe blocked"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return "TLS handshake failed"
        case .timedOut:
            return "Timed out"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return "Network error"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS resolution failed"
        case .badServerResponse:
            return "Bad server response"
        case .userAuthenticationRequired, .userCancelledAuthentication, .noPermissionsToReadFile:
            return "Probe blocked"
        default:
            return "Probe failed"
        }
    }

    enum ProbeError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Probe returned an invalid response"
            case .httpStatus(let statusCode):
                return "Probe request failed with status \(statusCode)"
            }
        }
    }
}
