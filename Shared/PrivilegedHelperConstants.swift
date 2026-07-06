import Foundation

enum PrivilegedHelperConstants {
    static let version = "7"
    static let label = "dev.x.teleport.PrivilegedHelper"
    static let socketPath = "/var/run/dev.x.teleport.helper.sock"
    static let helperStateDirectoryPath = "/var/db/dev.x.teleport"
    static let installedToolPath = "/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper"
    static let installedXrayPath = "/Library/PrivilegedHelperTools/dev.x.teleport.xray"
    static let installedAssetDirectoryPath = "/Library/PrivilegedHelperTools/dev.x.teleport.xray-assets"
    static let launchDaemonPlistPath = "/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist"
}
