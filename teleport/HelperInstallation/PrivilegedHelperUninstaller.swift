import Foundation

/// Removes everything `PrivilegedHelperInstaller` placed on the machine, through
/// the same administrator shell the install goes through. The leak guard anchor
/// is flushed as well: the daemon being booted out cannot release it itself.
///
/// `scripts/uninstall.sh` removes the same set for a machine the app is already
/// gone from; `test_mach_service_installation` checks the two agree.
nonisolated struct PrivilegedHelperUninstaller: Sendable {
    private let shellRunner: PrivilegedShellRunner

    init(shellRunner: PrivilegedShellRunner = PrivilegedShellRunner()) {
        self.shellRunner = shellRunner
    }

    /// Every root-owned path an install writes or the running helper creates, in
    /// removal order. Taken from the constants the install transaction and the
    /// LaunchDaemon plist are built from, so a renamed path cannot be left behind.
    static let removedPaths: [String] = [
        PrivilegedHelperConstants.launchDaemonPlistPath,
        PrivilegedHelperConstants.installedToolPath,
        PrivilegedHelperConstants.installedXrayPath,
        PrivilegedHelperConstants.installationManifestPath,
        PrivilegedHelperConstants.installedAssetDirectoryPath,
        PrivilegedHelperConstants.helperStateDirectoryPath,
        PrivilegedHelperInstaller.launchDaemonLogPath
    ]

    /// Installed means the daemon plist or the helper executable is on disk. The
    /// manifest or state directory alone is a leftover, not an installation, and
    /// the uninstall removes those too.
    static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: PrivilegedHelperConstants.launchDaemonPlistPath)
            || fileManager.fileExists(atPath: PrivilegedHelperConstants.installedToolPath)
    }

    /// Off the main actor for the same reason as the install: the prompt stays
    /// open for as long as the user takes.
    @concurrent
    func uninstall() async throws {
        do {
            try await shellRunner.runAdministratorShellScript(Self.uninstallScript(), prompt: administratorPrompt)
        } catch {
            throw PrivilegedHelperUninstallerError.uninstallFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private var administratorPrompt: String {
        """
        Teleport needs administrator access to remove its privileged helper.

        The helper and its LaunchDaemon are removed, and Teleport asks to install them again the next time either mode connects.
        """
    }

    /// The ordered shell steps. The daemon goes first, so nothing recreates the
    /// state directory or the log while they are being removed; the anchor flush
    /// goes last. Every step tolerates its target being absent already, so a
    /// partial earlier removal or a never-installed helper is not an error.
    static func uninstallSteps() -> [String] {
        let q = PrivilegedShellRunner.shellQuote
        var steps = ["launchctl bootout \(q("system/\(PrivilegedHelperConstants.label)")) >/dev/null 2>&1 || true"]
        steps += removedPaths.map { "rm -rf \(q($0))" }
        // Staging directories of an install that was killed before its trap ran.
        steps.append("rm -rf /Library/PrivilegedHelperTools/.teleport-install.*")
        steps.append("/sbin/pfctl -a \(q(LeakGuardRuleset.anchorName)) -F all >/dev/null 2>&1 || true")
        return steps
    }

    static func uninstallScript() -> String {
        (["set -eu"] + uninstallSteps()).joined(separator: "\n")
    }
}

enum PrivilegedHelperUninstallerError: LocalizedError {
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case let .uninstallFailed(message):
            return message.isEmpty ? "Failed to remove Teleport's privileged helper" : message
        }
    }
}
