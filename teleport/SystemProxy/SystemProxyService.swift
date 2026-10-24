import Darwin
import Foundation
import SystemConfiguration

nonisolated final class SystemProxyService: @unchecked Sendable {
    private let processRunner: (Process) throws -> Void
    private let fileManager: FileManager
    private let commandTimeout: TimeInterval
    private var lastEnabledEndpoint: ProxyEndpoint?
    private let log: TeleportLog

    static let subsystem = "sysproxy"

    init(
        processRunner: @escaping (Process) throws -> Void = { try $0.run() },
        fileManager: FileManager = .default,
        commandTimeout: TimeInterval = 5,
        log: TeleportLog = .shared
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.commandTimeout = commandTimeout
        self.log = log
    }

    func hasSavedProxySnapshot() -> Bool {
        fileManager.fileExists(atPath: proxySnapshotURL.path)
    }

    func enableProxy(endpoint: ProxyEndpoint) throws {
        log.info(Self.subsystem, "enabling system proxy at \(endpoint.host) http \(endpoint.httpPort) socks \(endpoint.socksPort)")
        SystemStateDump.captureProxySettings("before enabling system proxy", services: (try? activeNetworkServices()) ?? [], log: log)
        try persistCurrentProxyStateIfNeeded(endpoint: endpoint)

        do {
            try setWebProxy(enabled: true, host: endpoint.host, port: endpoint.httpPort)
            try setSecureWebProxy(enabled: true, host: endpoint.host, port: endpoint.httpPort)
            try setSOCKSProxy(enabled: true, host: endpoint.host, port: endpoint.socksPort)
            lastEnabledEndpoint = endpoint
            SystemStateDump.captureProxySettings("after enabling system proxy", services: (try? activeNetworkServices()) ?? [], log: log)
        } catch {
            log.error(Self.subsystem, "enabling system proxy failed, restoring: \(LogFormat.error(error))")
            try? restoreSavedProxyState()
            throw error
        }
    }

    /// Temporarily disables every system proxy while TUN routing is active, while
    /// retaining a snapshot that can be restored after the tunnel stops.
    func suspendProxyForTUN() throws {
        log.info(Self.subsystem, "suspending system proxies for TUN routing")
        let hadSnapshot = hasSavedProxySnapshot()
        if !hadSnapshot {
            try persistCurrentProxyStateIfNeeded(endpoint: lastEnabledEndpoint ?? .default)
        }

        do {
            // A snapshot taken just now is the live state, so only the proxies it
            // records as enabled need switching off; each networksetup call is a
            // process spawn. An older snapshot says nothing about what the services
            // carry now, so then every proxy is switched off.
            let snapshot = hadSnapshot ? nil : try loadSavedProxySnapshot()
            for service in try activeNetworkServices() {
                let recorded = snapshot?.services.first { $0.serviceName == service }
                if recorded?.webProxy.enabled ?? true {
                    try runNetworkSetup(arguments: ["-setwebproxystate", service, "off"])
                }
                if recorded?.secureWebProxy.enabled ?? true {
                    try runNetworkSetup(arguments: ["-setsecurewebproxystate", service, "off"])
                }
                if recorded?.socksProxy.enabled ?? true {
                    try runNetworkSetup(arguments: ["-setsocksfirewallproxystate", service, "off"])
                }
            }
            lastEnabledEndpoint = nil
        } catch {
            log.error(Self.subsystem, "suspending system proxies failed, restoring: \(LogFormat.error(error))")
            try? restoreSavedProxyState()
            throw error
        }
    }

    func disableProxy() throws {
        log.info(Self.subsystem, "disabling system proxy (snapshot \(hasSavedProxySnapshot() ? "present" : "absent"))")
        if hasSavedProxySnapshot() {
            try restoreSavedProxyState()
            return
        }

        if let lastEnabledEndpoint {
            try disableProxyIfMatching(endpoint: lastEnabledEndpoint)
            self.lastEnabledEndpoint = nil
            return
        }

        // Safety fallback for stale settings created before crash-safe snapshots existed.
        // It only turns off proxies that still point at Teleport's default local endpoint.
        try disableProxyIfMatching(endpoint: .default)
    }

    func restoreSavedProxyState() throws {
        guard let snapshot = try loadSavedProxySnapshot() else { return }

        let activeServices = Set(try activeNetworkServices())
        let configurations = try readProxyConfigurations()
        var unrestored: [NetworkServiceProxySnapshot] = []

        for serviceSnapshot in snapshot.services {
            guard activeServices.contains(serviceSnapshot.serviceName) else {
                // A service that is down right now — Wi-Fi during the very outage
                // that prompted the teardown — still carries whatever Teleport
                // wrote to it. Its entry is kept so a later attempt can finish the
                // job; discarding it here is what left Wi-Fi pointing at a dead
                // local port with no record of what it should have been.
                log.warn(Self.subsystem, "deferring proxy restore for \(serviceSnapshot.serviceName): service is not currently active")
                unrestored.append(serviceSnapshot)
                continue
            }
            try restoreWebProxy(serviceSnapshot.webProxy, service: serviceSnapshot.serviceName, in: configurations)
            try restoreSecureWebProxy(serviceSnapshot.secureWebProxy, service: serviceSnapshot.serviceName, in: configurations)
            try restoreSOCKSProxy(serviceSnapshot.socksProxy, service: serviceSnapshot.serviceName, in: configurations)
        }

        let restoredCount = snapshot.services.count - unrestored.count
        SystemStateDump.captureProxySettings("after restoring system proxy", services: Array(activeServices), log: log)

        if unrestored.isEmpty {
            log.info(Self.subsystem, "restored proxy settings for all \(restoredCount) snapshotted services; discarding snapshot")
            try? fileManager.removeItem(at: proxySnapshotURL)
        } else {
            log.warn(Self.subsystem, "restored \(restoredCount) of \(snapshot.services.count) services; keeping snapshot for \(unrestored.map(\.serviceName).joined(separator: ", "))")
            try writeProxySnapshot(ProxyStateSnapshot(createdAt: snapshot.createdAt, endpoint: snapshot.endpoint, services: unrestored))
        }

        lastEnabledEndpoint = nil
    }

    /// Finishes a restore that an earlier one could not complete, for services that
    /// have come back since. Safe to call whenever Teleport is not routing: with no
    /// snapshot on disk it does nothing at all.
    func restoreDeferredProxyStateIfNeeded() throws {
        guard hasSavedProxySnapshot() else { return }
        log.info(Self.subsystem, "found a proxy snapshot left by an earlier session; attempting to restore it")
        try restoreSavedProxyState()
    }

    private func persistCurrentProxyStateIfNeeded(endpoint: ProxyEndpoint) throws {
        guard !hasSavedProxySnapshot() else { return }

        let services = try activeNetworkServices()
        let configurations = try readProxyConfigurations()
        let snapshots = services.map { service in
            NetworkServiceProxySnapshot(
                serviceName: service,
                webProxy: readWebProxy(service: service, in: configurations),
                secureWebProxy: readSecureWebProxy(service: service, in: configurations),
                socksProxy: readSOCKSProxy(service: service, in: configurations)
            )
        }

        if snapshots.contains(where: { $0.hasEnabledAuthenticatedProxy }) {
            throw ProxyError.authenticatedProxyCannotBePreserved
        }

        let snapshot = ProxyStateSnapshot(createdAt: Date(), endpoint: endpoint, services: snapshots)
        log.info(Self.subsystem, "saved pre-Teleport proxy snapshot for \(snapshots.count) services: \(snapshots.map(\.serviceName).joined(separator: ", "))")
        try writeProxySnapshot(snapshot)
    }

    private func writeProxySnapshot(_ snapshot: ProxyStateSnapshot) throws {
        try fileManager.createDirectory(at: proxyStateDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: proxySnapshotURL, options: [.atomic])
    }

    private func loadSavedProxySnapshot() throws -> ProxyStateSnapshot? {
        guard fileManager.fileExists(atPath: proxySnapshotURL.path) else { return nil }
        let data = try Data(contentsOf: proxySnapshotURL)
        return try JSONDecoder().decode(ProxyStateSnapshot.self, from: data)
    }

    private var proxyStateDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
    }

    private var proxySnapshotURL: URL {
        proxyStateDirectoryURL.appendingPathComponent("system-proxy-snapshot.json")
    }

    private func activeNetworkServices() throws -> [String] {
        let result = try runNetworkSetup(arguments: ["-listallnetworkservices"])

        return result.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("An asterisk") }
            .filter { !$0.hasPrefix("*") }
    }

    /// The proxy settings of every network service by name, read in-process from
    /// the same preferences networksetup reads. One read replaces three
    /// networksetup spawns per service.
    private func readProxyConfigurations() throws -> [String: [String: Any]] {
        guard let preferences = SCPreferencesCreate(nil, "dev.x.teleport" as CFString, nil),
              let networkSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
            throw ProxyError.preferencesUnavailable
        }
        var configurations: [String: [String: Any]] = [:]
        for service in services {
            guard let name = SCNetworkServiceGetName(service) as String?,
                  let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let configuration = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] else {
                continue
            }
            configurations[name] = configuration
        }
        return configurations
    }

    private func readWebProxy(service: String, in configurations: [String: [String: Any]]) -> NetworkProxySettings {
        NetworkProxySettings(configuration: configurations[service], keyPrefix: "HTTP")
    }

    private func readSecureWebProxy(service: String, in configurations: [String: [String: Any]]) -> NetworkProxySettings {
        NetworkProxySettings(configuration: configurations[service], keyPrefix: "HTTPS")
    }

    private func readSOCKSProxy(service: String, in configurations: [String: [String: Any]]) -> NetworkProxySettings {
        NetworkProxySettings(configuration: configurations[service], keyPrefix: "SOCKS")
    }

    private func setWebProxy(enabled: Bool, host: String?, port: Int?) throws {
        for service in try activeNetworkServices() {
            try runNetworkSetup(arguments: ["-setwebproxy", service, host ?? "", port.map(String.init) ?? "0"])
            try runNetworkSetup(arguments: ["-setwebproxystate", service, enabled ? "on" : "off"])
        }
    }

    private func setSecureWebProxy(enabled: Bool, host: String?, port: Int?) throws {
        for service in try activeNetworkServices() {
            try runNetworkSetup(arguments: ["-setsecurewebproxy", service, host ?? "", port.map(String.init) ?? "0"])
            try runNetworkSetup(arguments: ["-setsecurewebproxystate", service, enabled ? "on" : "off"])
        }
    }

    private func setSOCKSProxy(enabled: Bool, host: String?, port: Int?) throws {
        for service in try activeNetworkServices() {
            try runNetworkSetup(arguments: ["-setsocksfirewallproxy", service, host ?? "", port.map(String.init) ?? "0"])
            try runNetworkSetup(arguments: ["-setsocksfirewallproxystate", service, enabled ? "on" : "off"])
        }
    }

    private func restoreWebProxy(_ settings: NetworkProxySettings, service: String, in configurations: [String: [String: Any]]) throws {
        try restoreProxySettings(settings, current: readWebProxy(service: service, in: configurations), service: service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
    }

    private func restoreSecureWebProxy(_ settings: NetworkProxySettings, service: String, in configurations: [String: [String: Any]]) throws {
        try restoreProxySettings(settings, current: readSecureWebProxy(service: service, in: configurations), service: service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
    }

    private func restoreSOCKSProxy(_ settings: NetworkProxySettings, service: String, in configurations: [String: [String: Any]]) throws {
        try restoreProxySettings(settings, current: readSOCKSProxy(service: service, in: configurations), service: service, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate")
    }

    /// One read is cheaper than the two or three writes a restore takes, and in TUN
    /// mode most proxies were never touched, so they already match the snapshot.
    private func restoreProxySettings(_ settings: NetworkProxySettings, current: NetworkProxySettings, service: String, setCommand: String, stateCommand: String) throws {
        guard current != settings else { return }
        let setArguments = [setCommand, service, settings.server ?? "", String(settings.port ?? 0)]
        let stateArguments = [stateCommand, service, settings.enabled ? "on" : "off"]

        if settings.enabled {
            try runNetworkSetup(arguments: setArguments)
            try runNetworkSetup(arguments: stateArguments)
        } else {
            try runNetworkSetup(arguments: stateArguments)
            try runNetworkSetup(arguments: setArguments)
            try runNetworkSetup(arguments: stateArguments)
        }
    }

    private func disableProxyIfMatching(endpoint: ProxyEndpoint) throws {
        let configurations = try readProxyConfigurations()
        for service in try activeNetworkServices() {
            let webProxy = readWebProxy(service: service, in: configurations)
            if webProxy.matches(host: endpoint.host, port: endpoint.httpPort) {
                try clearProxy(service: service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
            }

            let secureWebProxy = readSecureWebProxy(service: service, in: configurations)
            if secureWebProxy.matches(host: endpoint.host, port: endpoint.httpPort) {
                try clearProxy(service: service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
            }

            let socksProxy = readSOCKSProxy(service: service, in: configurations)
            if socksProxy.matches(host: endpoint.host, port: endpoint.socksPort) {
                try clearProxy(service: service, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate")
            }
        }
    }

    private func clearProxy(service: String, setCommand: String, stateCommand: String) throws {
        try runNetworkSetup(arguments: [stateCommand, service, "off"])
        try runNetworkSetup(arguments: [setCommand, service, "", "0"])
        try runNetworkSetup(arguments: [stateCommand, service, "off"])
    }

    @discardableResult
    private func runNetworkSetup(arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try processRunner(process)

        // System uptime stops while the machine sleeps; wall-clock time does not.
        // A networksetup spawned just before sleep would otherwise be found past
        // its deadline at wake and killed mid-write, leaving the restore half done.
        let deadline = ProcessInfo.processInfo.systemUptime + commandTimeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw ProxyError.commandTimedOut(arguments: arguments)
        }

        let stdout = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            log.error(Self.subsystem, "networksetup \(arguments.joined(separator: " ")) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            throw ProxyError.commandFailed(arguments: arguments, standardError: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Only mutations are logged; the -get/-list reads around them would triple
        // the volume without saying anything about what changed.
        if arguments.first?.hasPrefix("-set") == true {
            log.info(Self.subsystem, "networksetup \(arguments.joined(separator: " "))")
        }

        return CommandResult(standardOutput: stdout, standardError: stderr)
    }

    private struct ProxyStateSnapshot: Codable {
        let createdAt: Date
        let endpoint: ProxyEndpoint
        let services: [NetworkServiceProxySnapshot]
    }

    private struct NetworkServiceProxySnapshot: Codable {
        let serviceName: String
        let webProxy: NetworkProxySettings
        let secureWebProxy: NetworkProxySettings
        let socksProxy: NetworkProxySettings

        var hasEnabledAuthenticatedProxy: Bool {
            [webProxy, secureWebProxy, socksProxy].contains { $0.enabled && $0.authenticated }
        }
    }

    private struct NetworkProxySettings: Codable, Equatable {
        let enabled: Bool
        let server: String?
        let port: Int?
        let authenticated: Bool

        init(enabled: Bool, server: String?, port: Int?, authenticated: Bool = false) {
            self.enabled = enabled
            self.server = server
            self.port = port
            self.authenticated = authenticated
        }

        /// `keyPrefix` is "HTTP", "HTTPS" or "SOCKS", as in the `kSCPropNetProxies…`
        /// keys. A proxy with a user name is treated as authenticated: the password
        /// lives in the keychain, where a snapshot cannot carry it.
        init(configuration: [String: Any]?, keyPrefix: String) {
            let configuration = configuration ?? [:]
            let server = configuration["\(keyPrefix)Proxy"] as? String
            let user = configuration["\(keyPrefix)User"] as? String
            self.init(
                enabled: (configuration["\(keyPrefix)Enable"] as? Int ?? 0) != 0,
                server: server?.isEmpty == false ? server : nil,
                port: configuration["\(keyPrefix)Port"] as? Int ?? 0,
                authenticated: user?.isEmpty == false
            )
        }

        func matches(host: String, port expectedPort: Int) -> Bool {
            enabled
                && server?.caseInsensitiveCompare(host) == .orderedSame
                && port == expectedPort
        }
    }

    struct CommandResult {
        let standardOutput: String
        let standardError: String
    }

    enum ProxyError: LocalizedError {
        case authenticatedProxyCannotBePreserved
        case preferencesUnavailable
        case commandFailed(arguments: [String], standardError: String)
        case commandTimedOut(arguments: [String])

        var errorDescription: String? {
            switch self {
            case .authenticatedProxyCannotBePreserved:
                return "Existing authenticated system proxy settings cannot be safely preserved because macOS does not expose the saved proxy password. Disable those proxies before connecting."
            case .preferencesUnavailable:
                return "Failed to read the system proxy settings."
            case let .commandFailed(arguments, standardError):
                let command = arguments.joined(separator: " ")
                if standardError.isEmpty {
                    return "Failed to update system proxy with command: \(command)"
                }
                return "Failed to update system proxy with command: \(command)\n\(standardError)"
            case let .commandTimedOut(arguments):
                let command = arguments.joined(separator: " ")
                return "Timed out while updating system proxy with command: \(command)"
            }
        }
    }
}
