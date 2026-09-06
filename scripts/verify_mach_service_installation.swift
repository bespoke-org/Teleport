import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
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
        require(plist["RunAtLoad"] as? Bool == true, "LaunchDaemon must run when loaded")
        require(plist["KeepAlive"] as? Bool == true, "LaunchDaemon must remain available")
        require(plist["UserName"] == nil, "LaunchDaemon must use launchd's root default")
        require(plist["Sockets"] == nil, "Legacy launchd Sockets dictionary must be absent")

        guard let machServices = plist["MachServices"] as? [String: Any] else {
            preconditionFailure("LaunchDaemon plist must expose MachServices")
        }
        require(machServices.count == 1, "LaunchDaemon must expose exactly one Mach service")
        require(machServices[VPNHelperProtocol.machServiceName] as? Bool == true, "Expected Mach service must be enabled")
        require(PrivilegedHelperConstants.version == "9", "Installed helper compatibility version must be 9")

        print("verify_mach_service_installation: all checks passed")
    }
}
