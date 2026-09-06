import Foundation

/// Installs the helper, Xray binary, and LaunchDaemon into root-owned locations.
/// Geodata is delivered separately through the authenticated session request, so
/// updating routing data does not require another administrator approval. This path
/// runs only when installed executable content differs or the helper is
/// unavailable; ordinary VPN lifecycle commands use `PrivilegedHelperClient`.
struct PrivilegedHelperInstaller: Sendable {
    private struct InstallationManifest: Codable, Equatable {
        let helperVersion: String
        let xraySHA256: String
    }

    private let bundle: Bundle
    private let shellRunner: PrivilegedShellRunner
    private let artifactPolicy: BundledArtifactPolicy
    private let artifactVerifier: BundledArtifactVerifier

    init(
        bundle: Bundle = .main,
        shellRunner: PrivilegedShellRunner = PrivilegedShellRunner(),
        artifactPolicy: BundledArtifactPolicy = .current,
        artifactVerifier: BundledArtifactVerifier? = nil
    ) {
        self.bundle = bundle
        self.shellRunner = shellRunner
        self.artifactPolicy = artifactPolicy
        self.artifactVerifier = artifactVerifier ?? BundledArtifactVerifier(policy: artifactPolicy)
    }

    func ensureInstalled(runtimeURL: URL) async throws {
        guard let helperURL = bundledHelperURL() else {
            throw PrivilegedHelperInstallerError.bundledHelperMissing
        }

        if await isInstalledAndRunning() {
            return
        }
        try verifyBundleArtifacts(helperURL: helperURL, runtimeURL: runtimeURL)
        try install(helperURL: helperURL, runtimeURL: runtimeURL)
        try await waitUntilRunning()
    }

    private func isInstalledAndRunning() async -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedToolPath),
              fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedXrayPath),
              installationManifestMatches() else {
            return false
        }
        guard let response = try? await PrivilegedHelperClient().status(), response.success else {
            return false
        }
        return response.version == PrivilegedHelperClient.expectedVersion
    }

    private var expectedInstallationManifest: InstallationManifest {
        InstallationManifest(
            helperVersion: PrivilegedHelperClient.expectedVersion,
            xraySHA256: artifactPolicy.xraySHA256
        )
    }

    private func installationManifestMatches() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: PrivilegedHelperConstants.installationManifestPath)),
              let manifest = try? JSONDecoder().decode(InstallationManifest.self, from: data) else {
            return false
        }
        return manifest == expectedInstallationManifest
    }

    private func install(helperURL: URL, runtimeURL: URL) throws {
        let plist = Self.launchDaemonPlist()
        let script = installScript(appBundleURL: bundle.bundleURL, helperURL: helperURL, runtimeURL: runtimeURL, plist: plist)
        do {
            try shellRunner.runAdministratorShellScript(script, prompt: administratorPrompt)
        } catch {
            throw PrivilegedHelperInstallerError.installFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // TODO(gpt-5.6-sol): Local `codesign --verify` and a pinned Xray hash do not
    // establish Developer ID distribution trust or notarization. The release
    // pipeline must sign every executable appropriately, submit the app/DMG to
    // Apple's notary service, staple the ticket, and verify the final artifact.
    private func verifyBundleArtifacts(helperURL: URL, runtimeURL: URL) throws {
        try artifactVerifier.verify(
            appBundleURL: bundle.bundleURL,
            helperURL: helperURL,
            runtimeURL: runtimeURL
        )
    }

    private func bundledHelperURL() -> URL? {
        let bundleURL = bundle.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(PrivilegedHelperClient.label)"),
            bundleURL.appendingPathComponent("Contents/MacOS/\(PrivilegedHelperClient.label)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func waitUntilRunning() async throws {
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        while Date() < deadline {
            do {
                let response = try await PrivilegedHelperClient().status()
                if response.success, response.version == PrivilegedHelperClient.expectedVersion {
                    return
                }
            } catch {
                lastError = error
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw PrivilegedHelperInstallerError.helperDidNotStart(
            (lastError as? LocalizedError)?.errorDescription ?? lastError?.localizedDescription
        )
    }

    private var administratorPrompt: String {
        """
        Teleport needs administrator access to install or update its privileged helper for VPN mode.

        The helper lets Teleport start and stop Xray TUN and configure system routing. Your password is only used by macOS to approve this privileged install.
        """
    }

    /// Generates the complete administrator shell transaction. Values are quoted
    /// before interpolation, and helper/Xray copies are reverified after staging.
    // TODO(gpt-5.6-sol): Replace the AppleScript/manual `launchctl` installation
    // path with `SMAppService` daemon registration once the distribution pipeline
    // is notarized, and provide a matching unregister/uninstall operation.
    // TODO(gpt-5.6-sol): Make activation rollback-safe. A failure after `bootout`
    // can currently leave a stopped daemon or a mixture of old and new helper,
    // runtime, assets, and plist files because only the temporary directory is
    // cleaned up.
    private func installScript(appBundleURL: URL, helperURL: URL, runtimeURL: URL, plist: String) -> String {
        let q = PrivilegedShellRunner.shellQuote
        let manifest = expectedInstallationManifest
        let manifestJSON = "{\"helperVersion\":\"\(manifest.helperVersion)\",\"xraySHA256\":\"\(manifest.xraySHA256)\"}"
        return """
        set -eu
        APP_BUNDLE=\(q(appBundleURL.path))
        HELPER_SRC=\(q(helperURL.path))
        XRAY_SRC=\(q(runtimeURL.path))
        HELPER_DST=\(q(PrivilegedHelperClient.installedToolPath))
        XRAY_DST=\(q(PrivilegedHelperClient.installedXrayPath))
        MANIFEST_DST=\(q(PrivilegedHelperConstants.installationManifestPath))
        INSTALL_MANIFEST=\(q(manifestJSON))
        PLIST_DST=\(q(PrivilegedHelperClient.launchDaemonPlistPath))
        LABEL=\(q(PrivilegedHelperClient.label))
        REQUIREMENT=\(q(artifactPolicy.codeSigningRequirement))
        EXPECTED_XRAY_SHA256=\(q(artifactPolicy.xraySHA256))

        verify_signature() {
            /usr/bin/codesign --verify --strict --requirement "$REQUIREMENT" "$1"
        }

        verify_xray_hash() {
            actual_hash=$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')
            [ "$actual_hash" = "$EXPECTED_XRAY_SHA256" ] || {
                echo "Bundled Xray runtime hash verification failed." >&2
                exit 1
            }
        }

        verify_artifacts() {
            verify_signature "$APP_BUNDLE"
            verify_signature "$1"
            verify_xray_hash "$2"
        }

        verify_artifacts "$HELPER_SRC" "$XRAY_SRC"

        mkdir -p /Library/PrivilegedHelperTools
        tmp_dir=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.teleport-install.XXXXXX)
        cleanup() {
            rm -rf "$tmp_dir"
        }
        trap cleanup EXIT

        tmp_helper="$tmp_dir/$(basename "$HELPER_DST")"
        tmp_xray="$tmp_dir/$(basename "$XRAY_DST")"
        cp "$HELPER_SRC" "$tmp_helper"
        cp "$XRAY_SRC" "$tmp_xray"
        chown root:wheel "$tmp_helper" "$tmp_xray"
        chmod 755 "$tmp_helper" "$tmp_xray"

        verify_signature "$tmp_helper"
        verify_xray_hash "$tmp_xray"

        tmp_manifest="$tmp_dir/installation.json"
        printf '%s\n' "$INSTALL_MANIFEST" > "$tmp_manifest"
        chown root:wheel "$tmp_manifest"
        chmod 644 "$tmp_manifest"

        launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
        mv -f "$tmp_helper" "$HELPER_DST"
        mv -f "$tmp_xray" "$XRAY_DST"
        chown root:wheel "$HELPER_DST" "$XRAY_DST"
        chmod 755 "$HELPER_DST" "$XRAY_DST"
        mv -f "$tmp_manifest" "$MANIFEST_DST"
        chown root:wheel "$MANIFEST_DST"
        chmod 644 "$MANIFEST_DST"
        cat > "$PLIST_DST" <<'TELEPORT_HELPER_PLIST'
        \(plist)
        TELEPORT_HELPER_PLIST
        chown root:wheel "$PLIST_DST"
        chmod 644 "$PLIST_DST"
        launchctl bootstrap system "$PLIST_DST"
        launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
        """
    }

    /// The daemon runs as root by default because no `UserName` is specified.
    /// `KeepAlive` keeps the XPC service available; Xray itself is a separate child
    /// launched only for an active VPN session.
    static func launchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(PrivilegedHelperClient.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(PrivilegedHelperClient.installedToolPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(VPNHelperProtocol.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/teleport-privileged-helper.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/teleport-privileged-helper.log</string>
        </dict>
        </plist>
        """
    }
}

enum PrivilegedHelperInstallerError: LocalizedError {
    case bundledHelperMissing
    case installFailed(String)
    case helperDidNotStart(String?)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            return "Teleport's privileged helper is missing from the app bundle. Rebuild or reinstall Teleport."
        case let .installFailed(message):
            return message.isEmpty ? "Failed to install Teleport's privileged helper" : message
        case .helperDidNotStart:
            return "Teleport's privileged helper was installed but did not start."
        }
    }

    var failureReason: String? {
        switch self {
        case let .helperDidNotStart(details):
            return details
        default:
            return nil
        }
    }
}
