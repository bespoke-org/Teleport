import Foundation

/// Coordinates the user-visible TUN transaction around the lower-level runtime:
/// reject obvious VPN conflicts, disable System Proxy, derive the physical uplink,
/// build Xray JSON, and ask the privileged runtime to start or stop the session.
final class XrayTunConnectionBackend: ConnectionBackend, @unchecked Sendable {
    private let runtimeManager: PrivilegedXrayRuntimeManager
    private let routeInspector: XrayTunRouteInspector
    private let systemProxyService: SystemProxyService
    private let leakGuard: LeakGuardService

    init(
        runtimeManager: PrivilegedXrayRuntimeManager,
        routeInspector: XrayTunRouteInspector,
        systemProxyService: SystemProxyService,
        leakGuard: LeakGuardService
    ) {
        self.runtimeManager = runtimeManager
        self.routeInspector = routeInspector
        self.systemProxyService = systemProxyService
        self.leakGuard = leakGuard
    }

    func hasRestorableState() -> Bool {
        systemProxyService.hasSavedProxySnapshot()
    }

    func hasActiveRuntimeSession() async -> Bool {
        await runtimeManager.isRunning()
    }

    func restorePreviousState() async throws {
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.restoreSavedProxyState()
        }
    }

    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try validateProtectedRequest(request)
        // A previous build may still own the default tunnel and no longer accept
        // this app's signature. Repair authorization before treating that tunnel
        // as a VPN conflict, then let the helper tear down only its own session.
        try Task.checkCancellation()
        try await runtimeManager.prepareHelper { reportPhase(.awaitingUserApproval) }
        reportPhase(.connecting)
        try Task.checkCancellation()
        let existingVPNInterfaces = await BlockingWork.run { [routeInspector] in
            routeInspector.existingVPNDefaultRouteInterfaces()
        }
        await leakGuard.configure(isEnabled: request.usesLeakGuard)
        var cachedEndpoints: [String: [String]] = [:]
        let recovered = try await runtimeManager.recoverPreviousSession(existingVPNInterfaces: existingVPNInterfaces) {
            if request.usesLeakGuard { try await self.leakGuard.armBootstrap() }
            else { cachedEndpoints = await self.resolveEndpointsBeforeStopping(request) }
        }
        do {
            try await start(request, cachedEndpoints: cachedEndpoints, helperPrepared: true, reportPhase: reportPhase)
        } catch {
            // Recovery removed the old tunnel even if DNS/preflight or cancellation
            // prevents its replacement. Release that session's proxy snapshot too.
            if recovered {
                try? await BlockingWork.run { [systemProxyService] in
                    try systemProxyService.restoreSavedProxyState()
                }
            }
            throw error
        }
    }

    private func start(_ request: ConnectionRequest, cachedEndpoints: [String: [String]] = [:], helperPrepared: Bool = false,
                       reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        try Task.checkCancellation()
        if request.usesLeakGuard && !helperPrepared {
            try await runtimeManager.prepareHelper { reportPhase(.awaitingUserApproval) }
        }
        reportPhase(.connecting)
        if let otherVPN = await BlockingWork.run({ [routeInspector] in routeInspector.existingVPNDefaultRouteInterface() }) {
            throw XrayTunConnectionError.existingVPNDetected(otherVPN)
        }
        await leakGuard.configure(isEnabled: request.usesLeakGuard)
        if request.usesLeakGuard { try await leakGuard.armBootstrap() }
        // Resolve every eligible group endpoint through the helper's fixed-IP
        // HTTPS service. Never retry a failed answer through the system resolver.
        let resolvedEndpoints = request.usesLeakGuard ? try await resolveEndpoints(request) : cachedEndpoints
        let cancellation = CancellationFlag()
        let session = try await withTaskCancellationHandler {
            try await BlockingWork.run { [self] () -> XrayTunLaunchSession in
                try cancellation.check()
                if let existingVPNInterface = routeInspector.existingVPNDefaultRouteInterface() {
                    throw XrayTunConnectionError.existingVPNDetected(existingVPNInterface)
                }
                try cancellation.check()

                // Every connection in the session is pinned to the same reachable
                // numeric endpoint that receives its protected physical route. This
                // avoids a second DNS answer selecting a different address after the
                // TUN defaults have been installed. The uplink comes from the default
                // connection's route, as it did when a session had only one server.
                var outbounds: [RoutedProxyOutbound] = []
                var protectedHosts: [String] = []
                var outboundInterface = ""
                for connection in [request.defaultConnection] + request.additionalConnections {
                    let prepared = try RoutedProxyOutbound.resolve(connectionID: connection.id, configuration: connection.configuration) { host in
                        try cancellation.check()
                        return try self.routeInspector.protectedRoute(for: host, resolvedAddresses: request.usesLeakGuard ? (resolvedEndpoints[host] ?? []) : resolvedEndpoints[host])
                    }
                    if outbounds.isEmpty { outboundInterface = prepared.interface }
                    outbounds.append(prepared.outbound)
                    if !prepared.outbound.unavailableMemberHosts.isEmpty {
                        TeleportLog.shared.warn("tun", "auto-selection portal: \(prepared.outbound.unavailableMemberHosts.count) member hosts unavailable on this uplink; using \(prepared.outbound.memberAddresses.count) reachable hosts for this session")
                    }
                    for address in prepared.outbound.memberAddresses.values.sorted() where !protectedHosts.contains(address) {
                        protectedHosts.append(address)
                    }
                }
                try cancellation.check()

                let directSendThrough = routeInspector.ipv4Address(for: outboundInterface)
                let tunnelInterfaceName = routeInspector.nextAvailableTunnelInterfaceName()
                let localResolvers = request.localDNSDomains.isEmpty ? [] : XrayConfigurationWriter.resolverAddresses(SystemResolverInventory.nameservers())
                guard request.localDNSDomains.isEmpty || !localResolvers.isEmpty else {
                    throw XrayTunConnectionError.localDNSUnavailable
                }
                let endpoints = outbounds.flatMap { outbound in
                    outbound.configuration.endpointConfigurations.compactMap { config -> LeakGuardEndpoint? in
                        guard let address = outbound.memberAddresses[config.host] else { return nil }
                        return LeakGuardEndpoint(address: address,
                            transport: config.protocolType == .wireguard || config.protocolType == .hysteria ? "udp" : "tcp",
                            ports: config.hysteria?.quic?.udpHop?.ports ?? String(config.port))
                    }
                }
                let localDNSEndpoints = localResolvers.flatMap { address in
                    ["tcp", "udp"].map { LeakGuardEndpoint(address: address, transport: $0, ports: "53") }
                }
                let policy = LeakGuardPolicy(endpoints: endpoints + localDNSEndpoints,
                    allowsDirect: request.splitTunnelPolicy.defaultAction == .direct
                        || request.splitTunnelPolicy.rules.contains { $0.isEnabled && $0.action == .direct },
                    allowsLAN: request.allowsLocalNetwork)
                let configData = try XrayConfigurationWriter(proxyEndpoint: request.localProxy).tunnelConfigData(
                    for: outbounds,
                    interfaceName: tunnelInterfaceName,
                    outboundInterface: outboundInterface,
                    directSendThrough: directSendThrough,
                    splitTunnelRules: request.splitTunnelPolicy.rules,
                    defaultAction: request.splitTunnelPolicy.defaultAction,
                    dnsPolicy: TunnelDNSPolicy(
                        localResolvers: localResolvers,
                        localDomains: request.localDNSDomains,
                        ipv6Enabled: routeInspector.hasGlobalIPv6(on: outboundInterface)
                    )
                )
                return XrayTunLaunchSession(
                    configData: configData,
                    leakGuardPolicy: policy,
                    protectedHosts: protectedHosts,
                    tunnelInterfaceName: tunnelInterfaceName,
                    outboundInterface: outboundInterface
                )
            }
        } onCancel: {
            cancellation.cancel()
        }

        if !request.usesLeakGuard && !helperPrepared {
            try Task.checkCancellation()
            try await runtimeManager.prepareHelper { reportPhase(.awaitingUserApproval) }
        }
        // The commit point. Past this line the operation runs to the end whatever
        // happens to its task. Failed startup restores proxy state while the
        // firewall stays held in standby.
        try Task.checkCancellation()
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.suspendProxyForTUN()
        }

        do {
            // Before the tunnel, not after: between here and the TUN existing there
            // is nothing to route through, and this is the window the guard covers.
            // The tunnel it is about to allow is named now because the interface is
            // chosen here, so the guard never has to be widened afterwards.
            if request.usesLeakGuard {
                try await leakGuard.armForSession(
                    tunnelInterface: session.tunnelInterfaceName,
                    protectedHosts: session.protectedHosts, policy: session.leakGuardPolicy
                )
            }
            try await runtimeManager.start(session: session)
            // The helper's `start` response already follows TUN and route readiness;
            // this final check only consults the app's cached PID and is not an
            // authoritative helper health check.
            guard await runtimeManager.waitUntilRunning() else {
                let detail = await runtimeManager.capturedLogOutput()?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw XrayRuntimeManager.RuntimeError.startupTimedOut(detail)
            }
        } catch {
            if request.usesLeakGuard { await leakGuard.armStandby() }
            try? await runtimeManager.stop()
            try? await BlockingWork.run { [systemProxyService] in
                try systemProxyService.restoreSavedProxyState()
            }
            throw error
        }
    }

    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws {
        if Task.isCancelled {
            try await runtimeManager.stop()
            try await BlockingWork.run { [systemProxyService] in try systemProxyService.restoreSavedProxyState() }
            throw CancellationError()
        }
        try validateProtectedRequest(request)
        var cachedEndpoints: [String: [String]] = [:]
        if request.usesLeakGuard {
            try await runtimeManager.prepareHelper { reportPhase(.awaitingUserApproval) }
            await leakGuard.configure(isEnabled: true)
            try await leakGuard.armBootstrap()
        } else {
            cachedEndpoints = await resolveEndpointsBeforeStopping(request)
        }
        // Cancellation still tears down the old session before the provider
        // reports idle. start() observes cancellation before any new mutation.
        try await runtimeManager.stop()
        do {
            try await start(request, cachedEndpoints: cachedEndpoints, helperPrepared: request.usesLeakGuard, reportPhase: reportPhase)
        } catch is CancellationError {
            // The old tunnel is already gone and its proxy snapshot still held, so
            // a cancelled pre-flight here has something to put back after all.
            try? await BlockingWork.run { [systemProxyService] in
                try systemProxyService.restoreSavedProxyState()
            }
            throw CancellationError()
        }
    }

    private func resolveEndpointsBeforeStopping(_ request: ConnectionRequest) async -> [String: [String]] {
        // The running tunnel owns the system's preferred resolver. Resolve the
        // next endpoints while that resolver can still answer, then retain those
        // answers for this attempt. macOS may keep querying the old resolver
        // briefly after the helper removes it. Routes must still be inspected
        // after teardown so none of the old tunnel's routes are reused.
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await BlockingWork.run { [routeInspector] in
                var answers: [String: [String]] = [:]
                var seen: Set<String> = []
                // A broken old tunnel must not add one DNS timeout per member
                // before we can stop it. Missing answers retry after teardown.
                let deadline = ContinuousClock.now + .seconds(5)
                for connection in request.connections {
                    for endpoint in connection.configuration.endpointConfigurations where seen.insert(endpoint.host).inserted {
                        do { try cancellation.check() } catch { return answers }
                        guard ContinuousClock.now < deadline else { return answers }
                        let addresses = routeInspector.resolvedAddresses(for: endpoint.host)
                        if !addresses.isEmpty { answers[endpoint.host] = addresses }
                    }
                }
                return answers
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func validateProtectedRequest(_ request: ConnectionRequest) throws {
        if request.usesLeakGuard, let unsafe = request.connections.flatMap({ $0.configuration.endpointConfigurations }).first(where: {
            $0.securityWarningText != nil
        }) {
            throw XrayTunConnectionError.unsafeConfiguration(unsafe.displayName)
        }
        guard request.localDNSDomains.isEmpty || request.allowsLocalNetwork else {
            throw XrayTunConnectionError.localDNSRequiresLAN
        }
    }

    private func resolveEndpoints(_ request: ConnectionRequest) async throws -> [String: [String]] {
        guard let uplink = SystemUplinkInventory.primaryInterfaceName() else {
            throw XrayTunConnectionError.proxyRouteUnavailable(request.configuration.host)
        }
        var answers: [String: [String]] = [:]
        for connection in request.connections {
            for endpoint in connection.configuration.endpointConfigurations where answers[endpoint.host] == nil {
                try Task.checkCancellation()
                answers[endpoint.host] = isNumericIPAddress(endpoint.host) ? [endpoint.host]
                    : (try? await leakGuard.resolveEndpoint(host: endpoint.host, interface: uplink)) ?? []
                try Task.checkCancellation()
            }
        }
        return answers
    }

    func stop() async throws {
        try await runtimeManager.stop()
        try await BlockingWork.run { [systemProxyService] in
            try systemProxyService.restoreSavedProxyState()
        }
    }
}

/// Carries task cancellation into blocking work that runs outside the task.
nonisolated private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock(); isCancelled = true; lock.unlock()
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
    }
}

nonisolated enum XrayTunConnectionError: LocalizedError {
    case unsafeConfiguration(String)
    case localDNSRequiresLAN
    case localDNSUnavailable
    case existingVPNDetected(String)
    case proxyAddressResolutionFailed(String)
    case proxyRouteUnavailable(String)
    case proxyIPv6RouteUnavailable(String)
    case noReachableGroupMembers(dnsFailures: Int, ipv6RouteFailures: Int, routeFailures: Int)

    var errorDescription: String? {
        switch self {
        case let .unsafeConfiguration(name):
            return "Protection requires encryption and certificate verification. Fix the security settings for \(name) before connecting."
        case .localDNSRequiresLAN:
            return "Local DNS zones require explicit local network access."
        case .localDNSUnavailable:
            return "No local DNS resolver is available for the configured local zones."
        case let .existingVPNDetected(interface):
            return "Another VPN appears to be active on \(interface). Disconnect it before using Teleport TUN mode, or use System Proxy mode."
        case let .proxyAddressResolutionFailed(host):
            return "DNS lookup failed for proxy server \(host). Check the network and try again."
        case let .proxyIPv6RouteUnavailable(host):
            return "IPv6 route unavailable for proxy server \(host). The available server addresses are IPv6-only, but this network has no route to them. Use a network with IPv6 connectivity or choose another portal."
        case .noReachableGroupMembers:
            return "No eligible server in this group is reachable on the current network. Check the network or choose another portal."
        case let .proxyRouteUnavailable(host):
            return "No physical route to proxy server \(host). Reconnect to the network and try again."
        }
    }
}

// Counts describe only members eligible for selection or fallback, excluding
// unused provider outbounds. Keep endpoints out of the aggregate diagnosis.
extension XrayTunConnectionError {
    var failureReason: String? {
        guard case let .noReachableGroupMembers(dns, ipv6, route) = self else { return nil }
        return [
            dns > 0 ? "DNS lookup failures: \(dns)." : nil,
            ipv6 > 0 ? "IPv6 route failures: \(ipv6)." : nil,
            route > 0 ? "Physical route failures: \(route)." : nil
        ].compactMap { $0 }.joined(separator: " ")
    }
}
