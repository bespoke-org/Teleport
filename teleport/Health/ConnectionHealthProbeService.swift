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
    private let tcpTimeoutSeconds: Int
    private let tunnelProbeTimeoutSeconds: Int
    private let tunnelProbeURL: URL
    private let bundle: Bundle
    private let fileManager: FileManager

    init(
        tcpTimeoutSeconds: Int = 3,
        tunnelProbeTimeoutSeconds: Int = 8,
        tunnelProbeURL: URL = URL(string: "https://cp.cloudflare.com/generate_204")!,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
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
        var outcome = await proxyLatencyCheck(connection)
        // A probe that could not run says nothing about the server. The common
        // cause is transient and local — a port the probe picked is busy — so it is
        // worth one more attempt before reporting that nothing was learned.
        if case .indeterminate = outcome {
            outcome = await proxyLatencyCheck(connection)
        }

        switch outcome {
        case let .measured(latency, kind):
            return ConnectionHealthProbeResult(
                state: .reachable,
                checkedAt: checkedAt,
                latencyMilliseconds: latency,
                latencyKind: kind,
                failureSummary: nil
            )
        case let .unreachable(summary):
            return ConnectionHealthProbeResult(
                state: .unreachable,
                checkedAt: checkedAt,
                latencyMilliseconds: nil,
                latencyKind: nil,
                failureSummary: summary
            )
        case let .indeterminate(summary):
            // Not a verdict on the server: the probe itself did not get to ask.
            return ConnectionHealthProbeResult(
                state: .unknown,
                checkedAt: checkedAt,
                latencyMilliseconds: nil,
                latencyKind: nil,
                failureSummary: summary
            )
        }
    }

    /// What a probe attempt learned. Keeping "the server answered", "the server did
    /// not answer" and "we never managed to ask" apart is the whole point: the
    /// third must never be shown as the second.
    private enum ProbeOutcome {
        case measured(Int, ConnectionHealthLatencyKind)
        case unreachable(String)
        case indeterminate(String)
    }

    private func proxyLatencyCheck(_ connection: SavedConnection) async -> ProbeOutcome {
        let probeEndpoint = temporaryProbeEndpoint()
        let runtimeManager = XrayRuntimeManager(bundle: bundle)
        let writer = XrayConfigurationWriter(proxyEndpoint: probeEndpoint)
        let probeDirectory = fileManager.temporaryDirectory.appendingPathComponent("teleport-health-\(connection.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        let configURL = probeDirectory.appendingPathComponent("xray-config.json")

        defer {
            try? fileManager.removeItem(at: probeDirectory)
        }

        // A WireGuard peer scoped to a few subnets cannot carry a request to a
        // public address, so the request below would time out on a perfectly
        // healthy peer. Such a peer is judged by its handshake instead, which Xray
        // reports at debug level.
        let peer = connection.configuration.wireguard
        let judgedByHandshake = peer != nil && !(peer?.carriesDefaultRoute ?? true)

        do {
            _ = try writer.writeConfig(
                for: connection.configuration,
                to: configURL,
                logLevel: peer == nil ? "warning" : "debug",
                // A probe has to leave through the physical uplink. Otherwise a
                // running tunnel carries it, and the result describes that tunnel
                // rather than the server being probed — which is why probing a
                // server outside the active session failed while the one inside it
                // succeeded.
                outboundInterface: SystemUplinkInventory.primaryInterfaceName()
            )
            try runtimeManager.start(configURL: configURL)
            let isReady = await waitForLocalProxyReady(endpoint: probeEndpoint, connectionID: connection.id)
            guard isReady else {
                // The local proxy never came up — the probe's own runtime, not the
                // server, so this is not a verdict about the server.
                let runtimeError = runtimeManager.stopAndCaptureErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .indeterminate(runtimeError.map(Self.summarizedRuntimeFailure) ?? "The probe's local proxy did not start")
            }

            if judgedByHandshake {
                let outcome = await wireGuardHandshakeOutcome(
                    peer: peer,
                    endpoint: probeEndpoint,
                    runtimeManager: runtimeManager
                )
                runtimeManager.stop()
                return outcome
            }

            do {
                let requestResult = try await proxyRequestLatencySample(endpoint: probeEndpoint)
                runtimeManager.stop()
                return .measured(requestResult, .proxyRequest)
            } catch {
                // A WireGuard peer that carries everything can still refuse the
                // public probe targets. Its own handshake is the more direct
                // question, so it decides before the server is called dead.
                if peer != nil {
                    let fallback = await wireGuardHandshakeOutcome(
                        peer: peer,
                        endpoint: probeEndpoint,
                        runtimeManager: runtimeManager
                    )
                    runtimeManager.stop()
                    if case .measured = fallback { return fallback }
                    if case .indeterminate = fallback { return fallback }
                }
                runtimeManager.stop()
                return .unreachable(Self.summarizedProbeFailure(error))
            }
        } catch {
            // Writing the config or launching the bundled runtime failed: nothing
            // was asked of the server.
            let runtimeError = runtimeManager.stopAndCaptureErrorOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let runtimeError, !runtimeError.isEmpty {
                return .indeterminate(Self.summarizedRuntimeFailure(runtimeError))
            }
            return .indeterminate(Self.summarizedProbeFailure(error))
        }
    }

    /// A completed handshake means the peer is up and accepted our keys, which is
    /// all a scoped peer can be asked without a reachable address inside its own
    /// subnets. WireGuard only handshakes when there is something to send, so the
    /// probe first asks the tunnel for an address the peer does carry; that request
    /// is expected to fail and its outcome is ignored — it exists to make Xray dial.
    private func wireGuardHandshakeOutcome(
        peer: WireGuardParameters?,
        endpoint: ProxyEndpoint,
        runtimeManager: XrayRuntimeManager
    ) async -> ProbeOutcome {
        guard let peer else { return .indeterminate("The probe has no WireGuard peer to ask") }
        guard let target = Self.handshakeTriggerTarget(for: peer) else {
            return .indeterminate("This peer carries no address the probe could ask for")
        }

        let startTime = DispatchTime.now().uptimeNanoseconds
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(tunnelProbeTimeoutSeconds)
        let triggerTask = Task { await Self.sendHandshakeTrigger(to: target, through: endpoint) }
        defer { triggerTask.cancel() }

        while clock.now < deadline {
            let output = runtimeManager.capturedErrorOutput() ?? ""
            if Self.containsWireGuardHandshakeResponse(output) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime
                return .measured(max(1, Int((Double(elapsed) / 1_000_000).rounded())), .wireGuardHandshake)
            }
            // The probe's own runtime died mid-question; the server was never given
            // a chance to answer.
            if !runtimeManager.isRunning {
                return .indeterminate(Self.summarizedRuntimeFailure(output.isEmpty ? "The probe's local proxy stopped" : output))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let output = runtimeManager.capturedErrorOutput() ?? ""
        // Silence from the peer is a verdict; never having asked is not.
        return Self.containsWireGuardHandshakeAttempt(output)
            ? .unreachable("The peer did not answer the WireGuard handshake")
            : .indeterminate("Teleport could not send a WireGuard handshake to this peer")
    }

    /// An address the peer is known to carry: its own resolver if it publishes one,
    /// otherwise the base address of a range it accepts. IPv4 comes first — a peer
    /// with no IPv6 address of its own drops an IPv6 packet before it ever
    /// handshakes, which would look like silence from the peer.
    nonisolated static func handshakeTriggerTarget(for peer: WireGuardParameters) -> String? {
        let candidates = XrayConfigurationWriter.resolverAddresses(peer.dnsServers)
            + peer.allowedIPs.compactMap { allowedIP -> String? in
                let base = allowedIP.split(separator: "/").first.map(String.init) ?? allowedIP
                guard !base.isEmpty, base != "0.0.0.0", base != "::" else { return nil }
                return base
            }
        return candidates.first { !$0.contains(":") } ?? candidates.first
    }

    /// Whether Xray tried at all. wireguard-go only handshakes when it has traffic
    /// to send, so an absent initiation means the probe's own request never reached
    /// the outbound, not that the peer is down.
    nonisolated static func containsWireGuardHandshakeAttempt(_ output: String) -> Bool {
        output.lowercased().contains("handshake initiation")
    }

    private static func sendHandshakeTrigger(to target: String, through endpoint: ProxyEndpoint) async {
        let host = target.contains(":") ? "[\(target)]" : target
        // https, not http: App Transport Security refuses cleartext requests, so an
        // http:// trigger never leaves the app and the tunnel is never dialled. The
        // TLS handshake here is expected to fail; what matters is that the proxy is
        // asked to CONNECT, which makes Xray dial through the peer.
        guard let url = URL(string: "https://\(host)/") else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
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
        defer { session.invalidateAndCancel() }
        // Whether this answers is irrelevant: sending it is what makes WireGuard
        // start its handshake.
        _ = try? await session.data(from: url)
    }

    /// Xray's wording has changed between releases, so the marker is matched
    /// loosely: any handshake line that is about receiving rather than sending.
    nonisolated static func containsWireGuardHandshakeResponse(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let lowercased = line.lowercased()
            guard lowercased.contains("handshake") else { return false }
            return lowercased.contains("receiving") || lowercased.contains("received")
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
        // Both inbounds must be up: the probe picks its ports at random, and one of
        // them being taken by another process would otherwise pass as ready and
        // then fail as if the server were at fault.
        guard let httpPort = NWEndpoint.Port(rawValue: UInt16(endpoint.httpPort)),
              let socksPort = NWEndpoint.Port(rawValue: UInt16(endpoint.socksPort)) else {
            return false
        }

        let host = NWEndpoint.Host(endpoint.host)
        let attemptLimit = 20

        for _ in 0..<attemptLimit {
            let sample = await tcpLatencySample(host: host, port: httpPort, connectionID: connectionID)
            if sample.isReachable,
               await tcpLatencySample(host: host, port: socksPort, connectionID: connectionID).isReachable {
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
