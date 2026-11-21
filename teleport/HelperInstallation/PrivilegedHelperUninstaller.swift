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
        } catch PrivilegedShellError.approvalCancelled {
            throw PrivilegedShellError.approvalCancelled
        } catch {
            throw PrivilegedHelperUninstallerError.uninstallFailed((error as? LocalizedError)?.failureReason ?? error.localizedDescription)
        }
    }

    private var administratorPrompt: String {
        """
        Teleport needs administrator access to remove its privileged helper.

        The helper and its LaunchDaemon are removed, and TUN mode asks to install them again the next time it connects.
        """
    }

    /// Stop the daemon and release PF before removing its recovery files.
    static func uninstallSteps() -> [String] {
        let q = PrivilegedShellRunner.shellQuote
        let service = q("system/\(PrivilegedHelperConstants.label)")
        var steps = ["if launchctl print \(service) >/dev/null 2>&1; then launchctl bootout \(service); fi"]
        steps.append("""
        PF_ANCHOR=\(q(LeakGuardRuleset.anchorName))
        STATE=\(q(PrivilegedHelperConstants.helperStateDirectoryPath))
        /sbin/pfctl -a "$PF_ANCHOR" -F all >/dev/null
        rm -f "$STATE/leak-guard.pf"
        if [ -e "$STATE/leak-guard.token" ]; then
            token=$(cat "$STATE/leak-guard.token")
            case "$token" in ''|*[!0-9]*) echo "Invalid saved PF reference" >&2; exit 1 ;; esac
            if ! /sbin/pfctl -X "$token"; then
                refs=$(/sbin/pfctl -s References)
                if printf '%s\\n' "$refs" | awk -v t="$token" '{for(i=1;i<=NF;i++) if ("x"$i=="x"t) found=1} END {exit !found}'; then exit 1; fi
            fi
            rm -f "$STATE/leak-guard.token"
        fi
        """)
        steps += removedPaths.map { "rm -rf \(q($0))" }
        // Staging directories of an install that was killed before its trap ran.
        steps.append("rm -rf /Library/PrivilegedHelperTools/.teleport-install.*")
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
        case .uninstallFailed:
            return "Teleport could not remove its privileged helper. Try Uninstall again and approve the administrator request. If files remain locked, restart your Mac before retrying."
        }
    }

    var failureReason: String? {
        if case let .uninstallFailed(message) = self, !message.isEmpty { return message }
        return nil
    }
}
