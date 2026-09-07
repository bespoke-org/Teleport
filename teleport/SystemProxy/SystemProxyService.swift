import Darwin
import Foundation

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
            log.error(Self.subsystem, "enabling system proxy failed, restoring: \(LogRedaction.error(error))")
            try? restoreSavedProxyState()
            throw error
        }
    }

    /// Temporarily disables every system proxy while VPN routing is active, while
    /// retaining a snapshot that can be restored after the tunnel stops.
    func suspendProxyForVPN() throws {
        log.info(Self.subsystem, "suspending system proxies for VPN routing")
        if !hasSavedProxySnapshot() {
            try persistCurrentProxyStateIfNeeded(endpoint: lastEnabledEndpoint ?? .default)
        }

        do {
            for service in try activeNetworkServices() {
                try runNetworkSetup(arguments: ["-setwebproxystate", service, "off"])
                try runNetworkSetup(arguments: ["-setsecurewebproxystate", service, "off"])
                try runNetworkSetup(arguments: ["-setsocksfirewallproxystate", service, "off"])
            }
            lastEnabledEndpoint = nil
        } catch {
            log.error(Self.subsystem, "suspending system proxies failed, restoring: \(LogRedaction.error(error))")
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
        for serviceSnapshot in snapshot.services {
            guard activeServices.contains(serviceSnapshot.serviceName) else {
                // The snapshot is deleted below regardless, so a service that was
                // down at this moment (Wi-Fi during an outage) keeps whatever proxy
                // settings Teleport wrote, with no record left to restore from.
                log.warn(Self.subsystem, "not restoring proxy settings for \(serviceSnapshot.serviceName): service is not currently active")
                continue
            }
            try restoreWebProxy(serviceSnapshot.webProxy, service: serviceSnapshot.serviceName)
            try restoreSecureWebProxy(serviceSnapshot.secureWebProxy, service: serviceSnapshot.serviceName)
            try restoreSOCKSProxy(serviceSnapshot.socksProxy, service: serviceSnapshot.serviceName)
        }

        log.info(Self.subsystem, "restored proxy settings for \(snapshot.services.filter { activeServices.contains($0.serviceName) }.count) of \(snapshot.services.count) snapshotted services; discarding snapshot")
        SystemStateDump.captureProxySettings("after restoring system proxy", services: Array(activeServices), log: log)
        try? fileManager.removeItem(at: proxySnapshotURL)
        lastEnabledEndpoint = nil
    }

    private func persistCurrentProxyStateIfNeeded(endpoint: ProxyEndpoint) throws {
        guard !hasSavedProxySnapshot() else { return }

        let services = try activeNetworkServices()
        let snapshots = try services.map { service in
            NetworkServiceProxySnapshot(
                serviceName: service,
                webProxy: try readWebProxy(service: service),
                secureWebProxy: try readSecureWebProxy(service: service),
                socksProxy: try readSOCKSProxy(service: service)
            )
        }

        if snapshots.contains(where: { $0.hasEnabledAuthenticatedProxy }) {
            throw ProxyError.authenticatedProxyCannotBePreserved
        }

        let snapshot = ProxyStateSnapshot(createdAt: Date(), endpoint: endpoint, services: snapshots)
        log.info(Self.subsystem, "saved pre-Teleport proxy snapshot for \(snapshots.count) services: \(snapshots.map(\.serviceName).joined(separator: ", "))")
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

    private func readWebProxy(service: String) throws -> NetworkProxySettings {
        try readProxySettings(arguments: ["-getwebproxy", service])
    }

    private func readSecureWebProxy(service: String) throws -> NetworkProxySettings {
        try readProxySettings(arguments: ["-getsecurewebproxy", service])
    }

    private func readSOCKSProxy(service: String) throws -> NetworkProxySettings {
        try readProxySettings(arguments: ["-getsocksfirewallproxy", service])
    }

    private func readProxySettings(arguments: [String]) throws -> NetworkProxySettings {
        let result = try runNetworkSetup(arguments: arguments)
        return NetworkProxySettings(networkSetupOutput: result.standardOutput)
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

    private func restoreWebProxy(_ settings: NetworkProxySettings, service: String) throws {
        try restoreProxySettings(settings, service: service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
    }

    private func restoreSecureWebProxy(_ settings: NetworkProxySettings, service: String) throws {
        try restoreProxySettings(settings, service: service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
    }

    private func restoreSOCKSProxy(_ settings: NetworkProxySettings, service: String) throws {
        try restoreProxySettings(settings, service: service, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate")
    }

    private func restoreProxySettings(_ settings: NetworkProxySettings, service: String, setCommand: String, stateCommand: String) throws {
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
        for service in try activeNetworkServices() {
            let webProxy = try readWebProxy(service: service)
            if webProxy.matches(host: endpoint.host, port: endpoint.httpPort) {
                try clearProxy(service: service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
            }

            let secureWebProxy = try readSecureWebProxy(service: service)
            if secureWebProxy.matches(host: endpoint.host, port: endpoint.httpPort) {
                try clearProxy(service: service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
            }

            let socksProxy = try readSOCKSProxy(service: service)
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

        let deadline = Date().addingTimeInterval(commandTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
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

        init(networkSetupOutput: String) {
            var enabled = false
            var server: String?
            var port: Int?
            var authenticated = false

            for line in networkSetupOutput.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }

                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

                switch key {
                case "enabled":
                    enabled = Self.parseBoolean(value)
                case "server":
                    server = value.isEmpty ? nil : value
                case "port":
                    port = Int(value)
                case "authenticated proxy enabled":
                    authenticated = Self.parseBoolean(value)
                default:
                    continue
                }
            }

            self.enabled = enabled
            self.server = server
            self.port = port
            self.authenticated = authenticated
        }

        func matches(host: String, port expectedPort: Int) -> Bool {
            enabled
                && server?.caseInsensitiveCompare(host) == .orderedSame
                && port == expectedPort
        }

        private static func parseBoolean(_ value: String) -> Bool {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1", "on":
                return true
            default:
                return false
            }
        }
    }

    struct CommandResult {
        let standardOutput: String
        let standardError: String
    }

    enum ProxyError: LocalizedError {
        case authenticatedProxyCannotBePreserved
        case commandFailed(arguments: [String], standardError: String)
        case commandTimedOut(arguments: [String])

        var errorDescription: String? {
            switch self {
            case .authenticatedProxyCannotBePreserved:
                return "Existing authenticated system proxy settings cannot be safely preserved because macOS does not expose the saved proxy password. Disable those proxies before connecting."
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
