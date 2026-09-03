import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func readSource(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@main
struct VerifyMachServiceInstallation {
    static func main() throws {
        let plistData = Data(PrivilegedHelperInstaller.launchDaemonPlist().utf8)
        let decoded = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let plist = decoded as? [String: Any] else {
            preconditionFailure("LaunchDaemon plist must decode as a dictionary")
        }

        require(plist["Label"] as? String == PrivilegedHelperConstants.label, "LaunchDaemon label changed")
        require(
            plist["ProgramArguments"] as? [String] == [PrivilegedHelperConstants.installedToolPath],
            "LaunchDaemon program arguments changed"
        )
        require(plist["StandardOutPath"] as? String == "/var/log/teleport-privileged-helper.log", "stdout path changed")
        require(plist["StandardErrorPath"] as? String == "/var/log/teleport-privileged-helper.log", "stderr path changed")
        require(plist["Sockets"] == nil, "Legacy launchd Sockets dictionary must be absent")

        guard let machServices = plist["MachServices"] as? [String: Any] else {
            preconditionFailure("LaunchDaemon plist must expose MachServices")
        }
        require(machServices.count == 1, "LaunchDaemon must expose exactly one Mach service")
        require(machServices[VPNHelperProtocol.machServiceName] as? Bool == true, "Expected Mach service must be enabled")
        require(PrivilegedHelperConstants.version == "8", "Installed helper compatibility version must be 8")

        let installerSource = try readSource("teleport/HelperInstallation/PrivilegedHelperInstaller.swift")
        require(!installerSource.contains("socketPath"), "Installer must not reference the legacy socket constant")
        require(!installerSource.contains("/var/run/dev.x.teleport.helper.sock"), "Installer must not reference the legacy socket path")
        require(!installerSource.contains("<key>Sockets</key>"), "Installer must not generate launchd sockets")
        require(installerSource.contains("launchctl bootstrap system \"$PLIST_DST\""), "Installer bootstrap behavior changed")
        require(installerSource.contains("launchctl kickstart -k \"system/$LABEL\""), "Installer kickstart behavior changed")

        let resetSource = try readSource("scripts/reset_legacy_privileged_helper.sh")
        require(resetSource.hasPrefix("#!/bin/sh\n"), "Reset script must use a system shell shebang")
        require(resetSource.contains("set -eu"), "Reset script must enable set -eu")
        require(resetSource.contains("$(id -u)"), "Reset script must check the effective user")
        require(resetSource.contains("launchctl bootout \"system/$LABEL\""), "Reset script must boot out the legacy daemon")
        require(resetSource.contains("printf '%s\\n' \"Removing $path\""), "Reset script must print every removed path")
        require(resetSource.contains("rm -rf -- \"$path\""), "Reset script must remove each declared path")

        let resetPaths = [
            "/var/run/dev.x.teleport.helper.sock",
            PrivilegedHelperConstants.installedToolPath,
            PrivilegedHelperConstants.installedXrayPath,
            PrivilegedHelperConstants.installedAssetDirectoryPath,
            PrivilegedHelperConstants.launchDaemonPlistPath,
            PrivilegedHelperConstants.helperStateDirectoryPath
        ]
        for path in resetPaths {
            require(resetSource.contains("remove_path '\(path)'"), "Reset script is missing \(path)")
        }

        let justSource = try readSource("justfile")
        require(
            justSource.contains("reset-legacy-privileged-helper:\n    sudo sh scripts/reset_legacy_privileged_helper.sh"),
            "Just reset recipe must invoke the explicit reset script with sudo"
        )
        guard let verifyLine = justSource.split(separator: "\n").first(where: { $0.hasPrefix("verify: ") }) else {
            preconditionFailure("Aggregate verify recipe is missing")
        }
        require(!verifyLine.contains("reset-legacy-privileged-helper"), "Destructive reset must not run during verification")

        print("verify_mach_service_installation: all checks passed")
    }
}
