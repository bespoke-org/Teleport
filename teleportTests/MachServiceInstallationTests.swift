import Foundation
import XCTest

final class MachServiceInstallationTests: XCTestCase {
    func testInstallationErrorsExplainTheFixAndKeepTechnicalDetailsSeparate() {
        let signature = ConnectionFailure(error: PrivilegedHelperInstallerError.installFailed("codesign: invalid signature"))
        XCTAssertTrue(signature.summary.contains("fresh signed copy"))
        XCTAssertEqual(signature.details, "codesign: invalid signature")
        let digest = ConnectionFailure(error: PrivilegedHelperInstallerError.installFailed("Bundled Xray runtime hash verification failed."))
        XCTAssertTrue(digest.summary.contains("does not match"))
        XCTAssertTrue(digest.summary.contains("fresh copy"))
        let startup = ConnectionFailure(error: PrivilegedHelperInstallerError.helperDidNotStart("service bootstrap failed"))
        XCTAssertTrue(startup.summary.contains("Restart your Mac"))
        XCTAssertEqual(startup.details, "service bootstrap failed")
        let removal = ConnectionFailure(error: PrivilegedHelperUninstallerError.uninstallFailed("file is locked"))
        XCTAssertTrue(removal.summary.contains("Try Uninstall again"))
        XCTAssertEqual(removal.details, "file is locked")
    }

    func testAdministratorCancellationIsRecognizedByItsCodeInAnyLanguage() {
        let error = PrivilegedShellRunner.failure(fromOSAScriptOutput: "0:42: execution error: Операция отменена. (-128)")
        guard case .approvalCancelled = error else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error.localizedDescription.contains("Administrator approval was cancelled"))
        XCTAssertTrue(error.localizedDescription.contains("Try again"))
        XCTAssertFalse(error.localizedDescription.contains("(-128)"))
    }

    func testIsolatedGroupInstallationScriptParsesWithoutExecuting() throws {
        let manifest = HelperInstallationManifest(helperVersion: PrivilegedHelperConstants.version,
            appCDHashes: [String(repeating: "a", count: 40)], helperCDHashes: [String(repeating: "b", count: 40)],
            xraySHA256: String(repeating: "c", count: 64))
        let script = try PrivilegedHelperInstaller().installScript(
            appBundleURL: URL(fileURLWithPath: "/unused/Teleport.app"), helperURL: URL(fileURLWithPath: "/unused/helper"),
            runtimeURL: URL(fileURLWithPath: "/unused/xray"), manifest: manifest, plist: PrivilegedHelperInstaller.launchDaemonPlist())
        XCTAssert(script.contains("GroupMembership GroupMembers NestedGroups"))
        XCTAssert(script.contains("-list /Users PrimaryGroupID"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-install-parse-\(UUID()).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", path.path]
        try shell.run(); shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
    }

    func testLaunchDaemonPlist() throws {
        let plistData = Data(PrivilegedHelperInstaller.launchDaemonPlist().utf8)
        let decoded = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        let plist = try XCTUnwrap(decoded as? [String: Any], "LaunchDaemon plist must decode as a dictionary")

        XCTAssert(plist["Label"] as? String == PrivilegedHelperConstants.label, "LaunchDaemon label changed")
        XCTAssert(
            plist["ProgramArguments"] as? [String] == [PrivilegedHelperConstants.installedToolPath],
            "LaunchDaemon program arguments changed"
        )
        XCTAssert(plist["StandardOutPath"] as? String == "/var/log/teleport-privileged-helper.log", "stdout path changed")
        XCTAssert(plist["StandardErrorPath"] as? String == "/var/log/teleport-privileged-helper.log", "stderr path changed")
        XCTAssert(plist["RunAtLoad"] as? Bool == true, "LaunchDaemon must run when loaded")
        XCTAssert(plist["KeepAlive"] as? Bool == true, "LaunchDaemon must remain available")
        XCTAssertEqual(plist["GroupName"] as? String, PrivilegedHelperConstants.runtimeGroup)
        XCTAssert(plist["UserName"] == nil, "LaunchDaemon must use launchd's root default")
        XCTAssert(plist["Sockets"] == nil, "Legacy launchd Sockets dictionary must be absent")

        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any], "LaunchDaemon plist must expose MachServices")
        XCTAssert(machServices.count == 1, "LaunchDaemon must expose exactly one Mach service")
        XCTAssert(machServices[TUNHelperProtocol.machServiceName] as? Bool == true, "Expected Mach service must be enabled")

        try verifyUninstall()

    }

    /// The uninstall has to remove what the install writes, and the standalone
    /// script has to remove the same set as the app.
    private func verifyUninstall() throws {
        let q = PrivilegedShellRunner.shellQuote
        let removedPaths = PrivilegedHelperUninstaller.removedPaths
        XCTAssert(removedPaths.first == PrivilegedHelperConstants.launchDaemonPlistPath, "The LaunchDaemon plist must go before the files it points at")
        for path in removedPaths {
            XCTAssert(path.hasPrefix("/Library/") || path.hasPrefix("/var/"), "Removed path must be root-owned: \(path)")
            XCTAssert(path.hasSuffix("teleport") || path.contains("dev.x.teleport") || path.contains("teleport-privileged-helper"), "Removed path must be Teleport's own: \(path)")
            XCTAssert(!path.hasSuffix("/"), "Removed path must not end in a slash: \(path)")
        }

        let steps = PrivilegedHelperUninstaller.uninstallSteps()
        XCTAssert(steps.first == "launchctl bootout \(q("system/\(PrivilegedHelperConstants.label)")) >/dev/null 2>&1 || true", "The daemon must be booted out first, tolerating its absence")
        XCTAssert(steps.last == "/sbin/pfctl -a \(q(LeakGuardRuleset.anchorName)) -F all >/dev/null 2>&1 || true", "The leak guard anchor must be flushed last, tolerating its absence")
        let removalSteps = Array(steps.dropFirst().dropLast())
        for step in removalSteps {
            XCTAssert(step.hasPrefix("rm -rf '/") || step.hasPrefix("rm -rf /Library/PrivilegedHelperTools/.teleport-install."), "Unexpected uninstall step: \(step)")
        }
        XCTAssert(PrivilegedHelperUninstaller.uninstallScript().hasPrefix("set -eu\nlaunchctl bootout "), "The uninstall script must stop on the first unexpected failure")

        let scriptPath = repositoryRoot.appendingPathComponent("scripts/uninstall.sh").path
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssert(script.hasPrefix("#!/usr/bin/env bash\n"), "scripts/uninstall.sh must be a bash script")
        XCTAssert(script.contains("set -euo pipefail"), "scripts/uninstall.sh must fail fast")
        XCTAssert(script.contains("LABEL='\(PrivilegedHelperConstants.label)'"), "scripts/uninstall.sh must boot out the installed label")
        XCTAssert(script.contains("PF_ANCHOR='\(LeakGuardRuleset.anchorName)'"), "scripts/uninstall.sh must flush the leak guard anchor")
        for path in removedPaths {
            XCTAssert(script.contains("remove_path \(q(path))"), "scripts/uninstall.sh must remove \(path)")
        }
    }
}
