import Foundation

/// Values compiled into both the sandbox-free app process and the root helper.
/// Keeping them here prevents the two binaries from silently disagreeing about
/// the wire protocol or about which root-owned files they are allowed to use.
nonisolated enum PrivilegedHelperConstants {
    /// Installation/protocol compatibility version, not the user-facing app version.
    /// Bump this whenever an older helper cannot safely serve the current client.
    static let version = "12"
    static let label = "dev.x.teleport.PrivilegedHelper"

    /// Root-owned runtime state. The regular app process cannot read this directory directly.
    static let helperStateDirectoryPath = "/var/db/dev.x.teleport"
    static let installedToolPath = "/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper"
    static let installedXrayPath = "/Library/PrivilegedHelperTools/dev.x.teleport.xray"
    static let installedAssetDirectoryPath = "/Library/PrivilegedHelperTools/dev.x.teleport.xray-assets"
    static let installationManifestPath = "/Library/PrivilegedHelperTools/dev.x.teleport.installation.json"
    static let launchDaemonPlistPath = "/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist"
}
