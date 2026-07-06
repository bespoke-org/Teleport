import Foundation

struct PrivilegedHelperInstaller: Sendable {
    private static let codeSigningRequirement = "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"ZTB359LSTB\""
    private static let bundledXraySHA256 = "95984ec72638f96f0c576246e91ad2fff978557cf8e37e3e6111ee595030b2f7"

    private let bundle: Bundle
    private let shellRunner: PrivilegedShellRunner

    init(bundle: Bundle = .main, shellRunner: PrivilegedShellRunner = PrivilegedShellRunner()) {
        self.bundle = bundle
        self.shellRunner = shellRunner
    }

    func ensureInstalled(runtimeURL: URL) throws {
        guard let helperURL = bundledHelperURL() else {
            throw PrivilegedHelperInstallerError.bundledHelperMissing
        }
        if isInstalledAndRunning(helperURL: helperURL, runtimeURL: runtimeURL) {
            return
        }
        try verifyBundleArtifacts(helperURL: helperURL, runtimeURL: runtimeURL)
        try install(helperURL: helperURL, runtimeURL: runtimeURL)
        try waitUntilRunning()
    }

    private func isInstalledAndRunning(helperURL: URL, runtimeURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedToolPath),
              fileManager.isExecutableFile(atPath: PrivilegedHelperClient.installedXrayPath),
              fileManager.contentsEqual(atPath: helperURL.path, andPath: PrivilegedHelperClient.installedToolPath),
              fileManager.contentsEqual(atPath: runtimeURL.path, andPath: PrivilegedHelperClient.installedXrayPath),
              installedGeodataIsPresent() else {
            return false
        }
        guard let response = try? PrivilegedHelperClient().status(), response.success else {
            return false
        }
        return response.version == PrivilegedHelperClient.expectedVersion
    }

    private static let geodataFileNames = ["geosite.dat", "geoip.dat"]

    private func bundledAssetDirectoryURL() -> URL? {
        // Bundled geodata sits directly in the app's Resources dir, so resolve the
        // directory from one of the .dat files rather than assuming a subfolder.
        guard let geositeURL = bundle.url(forResource: "geosite", withExtension: "dat"),
              bundle.url(forResource: "geoip", withExtension: "dat") != nil else {
            return nil
        }
        return geositeURL.deletingLastPathComponent()
    }

    private func installedGeodataIsPresent() -> Bool {
        let fileManager = FileManager.default
        return Self.geodataFileNames.allSatisfy { name in
            fileManager.fileExists(atPath: PrivilegedHelperConstants.installedAssetDirectoryPath + "/" + name)
        }
    }

    private func install(helperURL: URL, runtimeURL: URL) throws {
        guard let assetDirectoryURL = bundledAssetDirectoryURL() else {
            throw PrivilegedHelperInstallerError.installFailed("Bundled Xray geodata is missing from the app bundle. Rebuild or reinstall Teleport.")
        }
        let plist = launchDaemonPlist()
        let script = installScript(appBundleURL: bundle.bundleURL, helperURL: helperURL, runtimeURL: runtimeURL, assetDirectoryURL: assetDirectoryURL, plist: plist)
        do {
            try shellRunner.runAdministratorShellScript(script, prompt: administratorPrompt)
        } catch {
            throw PrivilegedHelperInstallerError.installFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func verifyBundleArtifacts(helperURL: URL, runtimeURL: URL) throws {
        try verifyCodeSignature(at: bundle.bundleURL)
        try verifyCodeSignature(at: helperURL)
        try verifyXrayHash(runtimeURL)
    }

    private func verifyCodeSignature(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "--requirement", Self.codeSigningRequirement,
            url.path
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegedHelperInstallerError.installFailed(stderr.isEmpty ? "Teleport bundle signature verification failed." : stderr)
        }
    }

    private func verifyXrayHash(_ runtimeURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", runtimeURL.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegedHelperInstallerError.installFailed(stderr.isEmpty ? "Could not verify bundled Xray runtime." : stderr)
        }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let digest = output.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard digest.caseInsensitiveCompare(Self.bundledXraySHA256) == .orderedSame else {
            throw PrivilegedHelperInstallerError.installFailed("Bundled Xray runtime hash verification failed.")
        }
    }

    private func bundledHelperURL() -> URL? {
        let bundleURL = bundle.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(PrivilegedHelperClient.label)"),
            bundleURL.appendingPathComponent("Contents/MacOS/\(PrivilegedHelperClient.label)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func waitUntilRunning() throws {
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        while Date() < deadline {
            do {
                let response = try PrivilegedHelperClient().status()
                if response.success, response.version == PrivilegedHelperClient.expectedVersion {
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.2)
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

    private func installScript(appBundleURL: URL, helperURL: URL, runtimeURL: URL, assetDirectoryURL: URL, plist: String) -> String {
        let q = PrivilegedShellRunner.shellQuote
        return """
        set -eu
        APP_BUNDLE=\(q(appBundleURL.path))
        HELPER_SRC=\(q(helperURL.path))
        XRAY_SRC=\(q(runtimeURL.path))
        ASSET_SRC=\(q(assetDirectoryURL.path))
        HELPER_DST=\(q(PrivilegedHelperClient.installedToolPath))
        XRAY_DST=\(q(PrivilegedHelperClient.installedXrayPath))
        ASSET_DST=\(q(PrivilegedHelperConstants.installedAssetDirectoryPath))
        PLIST_DST=\(q(PrivilegedHelperClient.launchDaemonPlistPath))
        LABEL=\(q(PrivilegedHelperClient.label))
        REQUIREMENT=\(q(Self.codeSigningRequirement))
        EXPECTED_XRAY_SHA256=\(q(Self.bundledXraySHA256))
        GEODATA_FILES=\(q(Self.geodataFileNames.joined(separator: " ")))

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

        tmp_assets="$tmp_dir/assets"
        mkdir "$tmp_assets"
        for geodata_file in $GEODATA_FILES; do
            cp "$ASSET_SRC/$geodata_file" "$tmp_assets/$geodata_file"
        done
        chown root:wheel "$tmp_assets"
        chmod 755 "$tmp_assets"
        for geodata_file in $GEODATA_FILES; do
            chown root:wheel "$tmp_assets/$geodata_file"
            chmod 644 "$tmp_assets/$geodata_file"
        done

        launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
        rm -f \(q(PrivilegedHelperClient.socketPath))
        mv -f "$tmp_helper" "$HELPER_DST"
        mv -f "$tmp_xray" "$XRAY_DST"
        chown root:wheel "$HELPER_DST" "$XRAY_DST"
        chmod 755 "$HELPER_DST" "$XRAY_DST"
        rm -rf "$ASSET_DST"
        mv -f "$tmp_assets" "$ASSET_DST"
        cat > "$PLIST_DST" <<'TELEPORT_HELPER_PLIST'
        \(plist)
        TELEPORT_HELPER_PLIST
        chown root:wheel "$PLIST_DST"
        chmod 644 "$PLIST_DST"
        launchctl bootstrap system "$PLIST_DST"
        launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
        """
    }

    private func launchDaemonPlist() -> String {
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
