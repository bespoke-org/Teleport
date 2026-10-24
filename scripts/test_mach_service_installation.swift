import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

struct TestMachServiceInstallation {
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
        require(plist["RunAtLoad"] as? Bool == true, "LaunchDaemon must run when loaded")
        require(plist["KeepAlive"] as? Bool == true, "LaunchDaemon must remain available")
        require(plist["UserName"] == nil, "LaunchDaemon must use launchd's root default")
        require(plist["Sockets"] == nil, "Legacy launchd Sockets dictionary must be absent")

        guard let machServices = plist["MachServices"] as? [String: Any] else {
            preconditionFailure("LaunchDaemon plist must expose MachServices")
        }
        require(machServices.count == 1, "LaunchDaemon must expose exactly one Mach service")
        require(machServices[TUNHelperProtocol.machServiceName] as? Bool == true, "Expected Mach service must be enabled")
        require(PrivilegedHelperConstants.version == "12", "Installed helper compatibility version must be 12")

        try verifyUninstall(logPath: plist["StandardOutPath"] as? String ?? "")

        print("test_mach_service_installation: all checks passed")
    }

    /// The uninstall has to remove what the install writes, and the standalone
    /// script has to remove the same set as the app.
    private static func verifyUninstall(logPath: String) throws {
        let q = PrivilegedShellRunner.shellQuote
        let expectedPaths = [
            PrivilegedHelperConstants.launchDaemonPlistPath,
            PrivilegedHelperConstants.installedToolPath,
            PrivilegedHelperConstants.installedXrayPath,
            PrivilegedHelperConstants.installationManifestPath,
            PrivilegedHelperConstants.installedAssetDirectoryPath,
            PrivilegedHelperConstants.helperStateDirectoryPath,
            logPath
        ]
        let removedPaths = PrivilegedHelperUninstaller.removedPaths
        require(Set(removedPaths) == Set(expectedPaths), "Uninstall must remove exactly what the install and the LaunchDaemon write")
        require(removedPaths.first == PrivilegedHelperConstants.launchDaemonPlistPath, "The LaunchDaemon plist must go before the files it points at")
        for path in removedPaths {
            require(path.hasPrefix("/Library/") || path.hasPrefix("/var/"), "Removed path must be root-owned: \(path)")
            require(path.hasSuffix("teleport") || path.contains("dev.x.teleport") || path.contains("teleport-privileged-helper"), "Removed path must be Teleport's own: \(path)")
            require(!path.hasSuffix("/"), "Removed path must not end in a slash: \(path)")
        }

        let steps = PrivilegedHelperUninstaller.uninstallSteps()
        require(steps.first == "launchctl bootout \(q("system/\(PrivilegedHelperConstants.label)")) >/dev/null 2>&1 || true", "The daemon must be booted out first, tolerating its absence")
        require(steps.last == "/sbin/pfctl -a \(q(LeakGuardRuleset.anchorName)) -F all >/dev/null 2>&1 || true", "The leak guard anchor must be flushed last, tolerating its absence")
        let removalSteps = Array(steps.dropFirst().dropLast())
        for path in removedPaths {
            require(removalSteps.contains("rm -rf \(q(path))"), "Missing removal step for \(path)")
        }
        for step in removalSteps {
            require(step.hasPrefix("rm -rf '/") || step.hasPrefix("rm -rf /Library/PrivilegedHelperTools/.teleport-install."), "Unexpected uninstall step: \(step)")
        }
        require(PrivilegedHelperUninstaller.uninstallScript().hasPrefix("set -eu\nlaunchctl bootout "), "The uninstall script must stop on the first unexpected failure")

        let scriptPath = FileManager.default.currentDirectoryPath + "/scripts/uninstall.sh"
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        require(script.hasPrefix("#!/usr/bin/env bash\n"), "scripts/uninstall.sh must be a bash script")
        require(script.contains("set -euo pipefail"), "scripts/uninstall.sh must fail fast")
        require(script.contains("LABEL='\(PrivilegedHelperConstants.label)'"), "scripts/uninstall.sh must boot out the installed label")
        require(script.contains("PF_ANCHOR='\(LeakGuardRuleset.anchorName)'"), "scripts/uninstall.sh must flush the leak guard anchor")
        for path in removedPaths {
            require(script.contains("remove_path \(q(path))"), "scripts/uninstall.sh must remove \(path)")
        }
    }
}
