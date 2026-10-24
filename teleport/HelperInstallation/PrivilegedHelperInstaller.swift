import Foundation
import Security

/// Installs the helper, Xray binary, and LaunchDaemon into root-owned locations.
/// Geodata is delivered separately through the authenticated session request, so
/// updating routing data does not require another administrator approval. This path
/// runs only when installed executable content differs or the helper is
/// unavailable; ordinary TUN lifecycle commands use `PrivilegedHelperClient`.
nonisolated struct PrivilegedHelperInstaller: Sendable {
    /// Written next to the installed helper by the admin transaction. The helper's
    /// code-directory hash is what detects a rebuilt helper whose protocol version
    /// did not change; the version alone would keep a stale root daemon running.
    ///
    /// The code-directory hash rather than a hash of the file: the file carries the
    /// signature's signing time, so every re-sign changed its hash and cost an
    /// administrator prompt on the next connect even when the code was identical.
    /// The code directory covers the code, identifier, entitlements and
    /// requirements, and not the signing time.
    private struct InstallationManifest: Codable, Equatable {
        let helperVersion: String
        let helperCDHash: String
        let xraySHA256: String
    }

    /// Where the LaunchDaemon sends the helper's stdout and stderr. Removed by
    /// `PrivilegedHelperUninstaller` along with the rest of the installation.
    static let launchDaemonLogPath = "/var/log/teleport-privileged-helper.log"

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

    /// `@concurrent` keeps the signature checks, the administrator prompt and the
    /// install off the caller's actor, which is the main one: run there, they froze
    /// the UI for as long as the prompt stayed open.
    @concurrent
    /// `beforeInstalling` runs only when an install is actually about to happen,
    /// before the administrator prompt, so the caller can tell the user what the
    /// wait is for.
    func ensureInstalled(runtimeURL: URL, beforeInstalling: @Sendable () -> Void = {}) async throws {
        guard let helperURL = bundledHelperURL() else {
            throw PrivilegedHelperInstallerError.bundledHelperMissing
        }

        let manifest = try expectedInstallationManifest(helperURL: helperURL)
        if await isInstalledAndRunning(expecting: manifest) {
            return
        }
        beforeInstalling()
        try verifyBundleArtifacts(helperURL: helperURL, runtimeURL: runtimeURL)
        try await install(helperURL: helperURL, runtimeURL: runtimeURL, manifest: manifest)
        try await waitUntilRunning()
    }

    private func isInstalledAndRunning(expecting manifest: InstallationManifest) async -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedToolPath),
              fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedXrayPath),
              installedManifest() == manifest else {
            return false
        }
        guard let response = try? await PrivilegedHelperClient().status(), response.success else {
            return false
        }
        return response.version == PrivilegedHelperClient.expectedVersion
    }

    /// Read from the signature in-process on every connect, which is cheap and
    /// avoids spawning `codesign`.
    private func expectedInstallationManifest(helperURL: URL) throws -> InstallationManifest {
        var staticCode: SecStaticCode?
        var signingInformation: CFDictionary?
        guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let cdHash = (signingInformation as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw PrivilegedHelperInstallerError.installFailed("Teleport could not read the privileged helper's code signature. Rebuild or reinstall Teleport.")
        }
        return InstallationManifest(
            helperVersion: PrivilegedHelperClient.expectedVersion,
            helperCDHash: cdHash.map { String(format: "%02x", $0) }.joined(),
            xraySHA256: artifactPolicy.xraySHA256
        )
    }

    private func installedManifest() -> InstallationManifest? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: PrivilegedHelperConstants.installationManifestPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(InstallationManifest.self, from: data)
    }

    private func install(helperURL: URL, runtimeURL: URL, manifest: InstallationManifest) async throws {
        guard let requirement = artifactPolicy.codeSigningRequirement else {
            throw PrivilegedHelperInstallerError.installFailed(BundledArtifactPolicy.missingTeamIdentifierMessage)
        }
        let plist = Self.launchDaemonPlist()
        let script = installScript(appBundleURL: bundle.bundleURL, helperURL: helperURL, runtimeURL: runtimeURL, requirement: requirement, manifest: manifest, plist: plist)
        do {
            try await shellRunner.runAdministratorShellScript(script, prompt: administratorPrompt)
        } catch {
            throw PrivilegedHelperInstallerError.installFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// What this establishes, and what it does not. A local `codesign --verify`
    /// against the team requirement and a pinned Xray hash prove that the helper
    /// and runtime about to be installed as root are the ones this build shipped
    /// with — the property the install transaction depends on. They do not prove
    /// anything about distribution: that the app was signed with a Developer ID
    /// certificate, passed Apple's notary service, and carries a stapled ticket.
    /// Those are properties of the release artifact, not of this code, and are
    /// listed as release checks in docs/xray-bundling-and-release.md. Until the
    /// pipeline produces such an artifact, installation stays on `launchctl` from
    /// an administrator shell, since `SMAppService` will not register a daemon
    /// for an app that lacks them.
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
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(5)
        var lastError: Error?
        while clock.now < deadline {
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
        Teleport needs administrator access to install or update its privileged helper for TUN mode.

        The helper lets Teleport start and stop Xray TUN and configure system routing. Your password is only used by macOS to approve this privileged install.
        """
    }

    /// Generates the complete administrator shell transaction. Values are quoted
    /// before interpolation, and helper/Xray copies are reverified after staging.
    ///
    /// The transaction is rollback-safe from the point it touches installed files.
    /// Whatever is installed is copied aside first; a failure anywhere after the
    /// daemon is booted out puts every file back and boots the previous daemon
    /// again, or, on a first install, removes what was placed. Only a script that
    /// reaches its last line leaves the new files behind.
    ///
    /// Installation goes through `launchctl` from an administrator shell rather
    /// than `SMAppService`, which requires a notarized, Developer ID-signed app to
    /// register a daemon; see the note on `verifyBundleArtifacts`.
    private func installScript(appBundleURL: URL, helperURL: URL, runtimeURL: URL, requirement: String, manifest: InstallationManifest, plist: String) -> String {
        let q = PrivilegedShellRunner.shellQuote
        let manifestJSON = "{\"helperVersion\":\"\(manifest.helperVersion)\",\"helperCDHash\":\"\(manifest.helperCDHash)\",\"xraySHA256\":\"\(manifest.xraySHA256)\"}"
        return """
        set -eu
        APP_BUNDLE=\(q(appBundleURL.path))
        HELPER_SRC=\(q(helperURL.path))
        XRAY_SRC=\(q(runtimeURL.path))
        HELPER_DST=\(q(PrivilegedHelperClient.installedToolPath))
        XRAY_DST=\(q(PrivilegedHelperClient.installedXrayPath))
        MANIFEST_DST=\(q(PrivilegedHelperConstants.installationManifestPath))
        LEGACY_ASSET_DIR=\(q(PrivilegedHelperConstants.installedAssetDirectoryPath))
        INSTALL_MANIFEST=\(q(manifestJSON))
        PLIST_DST=\(q(PrivilegedHelperClient.launchDaemonPlistPath))
        LABEL=\(q(PrivilegedHelperClient.label))
        REQUIREMENT=\(q(requirement))
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

        # Everything currently installed is kept beside the staging copies, so a
        # failure after the daemon is booted out can put it all back. A first
        # install has nothing to keep and is rolled back by removal instead.
        previous_dir="$tmp_dir/previous"
        mkdir -p "$previous_dir"
        had_previous=0
        for installed in "$HELPER_DST" "$XRAY_DST" "$MANIFEST_DST" "$PLIST_DST"; do
            if [ -e "$installed" ]; then
                cp -p "$installed" "$previous_dir/$(basename "$installed")"
                had_previous=1
            fi
        done

        activated=0
        touched_installed=0
        cleanup() {
            if [ "$activated" -ne 1 ] && [ "$touched_installed" -eq 1 ]; then
                echo "Helper installation failed; restoring the previous installation." >&2
                launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
                for installed in "$HELPER_DST" "$XRAY_DST" "$MANIFEST_DST" "$PLIST_DST"; do
                    kept="$previous_dir/$(basename "$installed")"
                    if [ -e "$kept" ]; then
                        mv -f "$kept" "$installed"
                    else
                        rm -f "$installed"
                    fi
                done
                if [ "$had_previous" -eq 1 ] && [ -e "$PLIST_DST" ]; then
                    launchctl bootstrap system "$PLIST_DST" >/dev/null 2>&1 || true
                    launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
                fi
            fi
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

        touched_installed=1
        launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
        mv -f "$tmp_helper" "$HELPER_DST"
        mv -f "$tmp_xray" "$XRAY_DST"
        chown root:wheel "$HELPER_DST" "$XRAY_DST"
        chmod 755 "$HELPER_DST" "$XRAY_DST"
        mv -f "$tmp_manifest" "$MANIFEST_DST"
        chown root:wheel "$MANIFEST_DST"
        chmod 644 "$MANIFEST_DST"
        rm -rf "$LEGACY_ASSET_DIR"
        cat > "$PLIST_DST" <<'TELEPORT_HELPER_PLIST'
        \(plist)
        TELEPORT_HELPER_PLIST
        chown root:wheel "$PLIST_DST"
        chmod 644 "$PLIST_DST"
        launchctl bootstrap system "$PLIST_DST"
        launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
        activated=1
        """
    }

    /// The daemon runs as root by default because no `UserName` is specified.
    /// `KeepAlive` keeps the XPC service available; Xray itself is a separate child
    /// launched only for an active TUN session.
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
                <key>\(TUNHelperProtocol.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(launchDaemonLogPath)</string>
            <key>StandardErrorPath</key>
            <string>\(launchDaemonLogPath)</string>
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
