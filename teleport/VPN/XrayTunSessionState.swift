import Foundation

/// A user-owned cache of the session that the helper reported as started.
/// This is useful for UI restoration, but it is not authoritative root state:
/// the helper/Xray process may have changed after this snapshot was written.
struct XrayTunSessionState: Codable, Sendable {
    var pid: Int32
    var protectedHost: String
    var tunnelInterfaceName: String
    var outboundInterface: String
    var configPath: String
    var startedAt: Date
}

/// Inputs sent across the privileged IPC boundary for one Xray TUN launch.
/// `configData` is the complete JSON configuration; the helper writes it into
/// its root-only state directory before starting Xray.
struct XrayTunLaunchSession: Sendable {
    var configData: Data
    var protectedHost: String
    var tunnelInterfaceName: String
    var outboundInterface: String
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
        let helperStateDirectoryURL = URL(fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath, isDirectory: true)
        stateDirectoryURL = baseURL.appendingPathComponent("teleport", isDirectory: true)
        pidFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun.pid")
        logFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun.log")
        protectedHostFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-protected-host")
        controlLogFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-control.log")
        sessionStateFileURL = stateDirectoryURL.appendingPathComponent("xray-tun-session.json")
        configFileURL = helperStateDirectoryURL.appendingPathComponent("xray-tun-config.json")
    }
}
