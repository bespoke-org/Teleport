import Foundation

/// A user-owned cache of the session that the helper reported as started.
/// This is useful for UI restoration, but it is not authoritative root state:
/// the helper/Xray process may have changed after this snapshot was written.
struct XrayTunSessionState: Codable, Sendable {
    var sessionID: UUID
    var pid: Int32?
    var protectedHosts: [String]
    var tunnelInterfaceName: String
    var outboundInterface: String
    var configPath: String
    var startedAt: Date

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case pid
        case protectedHost
        case protectedHosts
        case tunnelInterfaceName
        case outboundInterface
        case configPath
        case startedAt
    }

    init(
        sessionID: UUID,
        pid: Int32?,
        protectedHosts: [String],
        tunnelInterfaceName: String,
        outboundInterface: String,
        configPath: String,
        startedAt: Date
    ) {
        self.sessionID = sessionID
        self.pid = pid
        self.protectedHosts = protectedHosts
        self.tunnelInterfaceName = tunnelInterfaceName
        self.outboundInterface = outboundInterface
        self.configPath = configPath
        self.startedAt = startedAt
    }

    /// A cache written by an older build holds a single `protectedHost`. Reading
    /// it as a one-element list keeps a session started before the upgrade
    /// stoppable afterwards instead of leaving its route behind.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        if let hosts = try container.decodeIfPresent([String].self, forKey: .protectedHosts) {
            protectedHosts = hosts
        } else if let host = try container.decodeIfPresent(String.self, forKey: .protectedHost) {
            protectedHosts = [host]
        } else {
            protectedHosts = []
        }
        tunnelInterfaceName = try container.decode(String.self, forKey: .tunnelInterfaceName)
        outboundInterface = try container.decode(String.self, forKey: .outboundInterface)
        configPath = try container.decode(String.self, forKey: .configPath)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encode(protectedHosts, forKey: .protectedHosts)
        try container.encode(tunnelInterfaceName, forKey: .tunnelInterfaceName)
        try container.encode(outboundInterface, forKey: .outboundInterface)
        try container.encode(configPath, forKey: .configPath)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

/// Inputs sent across the privileged IPC boundary for one Xray TUN launch.
/// `configData` is the complete JSON configuration; the helper writes it into
/// its root-only state directory before starting Xray.
struct XrayTunLaunchSession: Sendable {
    var configData: Data
    /// Every proxy server the generated config dials.
    var protectedHosts: [String]
    var tunnelInterfaceName: String
    var outboundInterface: String
}

/// Persists correlation before privileged work can become indeterminate, then
/// refreshes the cache with the confirmed process projection on success.
nonisolated enum XrayTunStartCorrelation {
    static func perform(
        persist: (Int32?) throws -> Void,
        start: () async throws -> Int32?
    ) async throws -> Int32? {
        try persist(nil)
        let pid = try await start()
        try persist(pid)
        return pid
    }
}

/// Collects paths used by both sides of the IPC protocol.
/// `stateDirectoryURL` and `sessionStateFileURL` are user-owned. The PID, logs,
/// protected-host marker, and config live below the root-only helper directory.
struct XrayTunRuntimePaths: Sendable {
    var stateDirectoryURL: URL
    var pidFileURL: URL
    var logFileURL: URL
    var protectedHostFileURL: URL
    var controlLogFileURL: URL
    var sessionStateFileURL: URL
    var configFileURL: URL

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(
            stateDirectoryURL: baseURL.appendingPathComponent("teleport", isDirectory: true),
            helperStateDirectoryURL: URL(
                fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath,
                isDirectory: true
            )
        )
    }

    init(
        stateDirectoryURL: URL,
        helperStateDirectoryURL: URL,
        sessionStateFileURL: URL? = nil
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        pidFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun.pid")
        logFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun.log")
        protectedHostFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-protected-host")
        controlLogFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-control.log")
        self.sessionStateFileURL = sessionStateFileURL
            ?? stateDirectoryURL.appendingPathComponent("xray-tun-session.json")
        configFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-config.json")
    }
}
