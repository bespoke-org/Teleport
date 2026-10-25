import Foundation
import XCTest
import Security

final class BuildApprovalTests: XCTestCase {
    func testBuiltAppApproval() throws {
        // The scheme builds the app for testing into the products directory that holds this bundle.
        let app = Bundle(for: BuildApprovalTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Teleport.app")
        XCTAssert(FileManager.default.fileExists(atPath: app.path), "Teleport.app was not built next to the test bundle")
        let helper = app.appendingPathComponent("Contents/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper")
        let manifest = HelperInstallationManifest(
            helperVersion: PrivilegedHelperConstants.version,
            appCDHashes: try BundledArtifactVerifier.codeDirectoryHashes(at: app),
            helperCDHashes: try BundledArtifactVerifier.codeDirectoryHashes(at: helper),
            xraySHA256: BundledArtifactPolicy.current.xraySHA256
        )
        XCTAssert(manifest.isValid)
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(HelperInstallationManifest.self, from: encoded)
        XCTAssert(decoded == manifest)
        let verifier = BundledArtifactVerifier()
        try verifier.verify(appBundleURL: app, helperURL: helper,
                            runtimeURL: app.appendingPathComponent("Contents/Resources/xray"), manifest: manifest)
        do {
            try verifier.verifyCodeSignature(at: helper, requirement: manifest.clientRequirement)
            XCTFail("A different executable must not satisfy app approval")
        } catch is PrivilegedHelperInstallerError {}

        // A build changed under the same signing identifier must lose approval.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = directory.appendingPathComponent("changed-helper")
        try FileManager.default.copyItem(at: helper, to: changed)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "dev.x.teleport", "--options", "runtime", changed.path]
        try signer.run()
        signer.waitUntilExit()
        XCTAssert(signer.terminationStatus == 0)
        do {
            try verifier.verifyCodeSignature(at: changed, requirement: manifest.helperRequirement)
            XCTFail("Changed code signature must require approval again")
        } catch is PrivilegedHelperInstallerError {}

        let approval = directory.appendingPathComponent("approval.json")
        try encoded.write(to: approval)
        XCTAssert(HelperInstallationManifest.loadApproved(at: approval.path) == nil,
                     "A user-owned approval must never authorize a client")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: approval)
        XCTAssert(HelperInstallationManifest.loadApproved(at: link.path) == nil)
        XCTAssert(HelperInstallationManifest.loadApproved(at: directory.appendingPathComponent("missing").path) == nil)

        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for value in ["", "abc", String(repeating: "z", count: 40), "\" or true"] {
            object["appCDHashes"] = [value]
            let data = try JSONSerialization.data(withJSONObject: object)
            let invalid = try JSONDecoder().decode(HelperInstallationManifest.self, from: data)
            XCTAssert(!invalid.isValid)
        }
        for hashes in [[], [manifest.appCDHashes[0], manifest.appCDHashes[0]]] {
            object["appCDHashes"] = hashes
            let data = try JSONSerialization.data(withJSONObject: object)
            let invalid = try JSONDecoder().decode(HelperInstallationManifest.self, from: data)
            XCTAssert(!invalid.isValid)
        }
        object.removeValue(forKey: "appCDHashes")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssert((try? JSONDecoder().decode(HelperInstallationManifest.self, from: legacy)) == nil)

        try verifyUniversalApproval(in: directory, verifier: verifier)

        // Parse the actual administrator transaction without executing privileged operations.
        let script = try PrivilegedHelperInstaller().installScript(appBundleURL: app, helperURL: helper,
            runtimeURL: app.appendingPathComponent("Contents/Resources/xray"), manifest: manifest,
            plist: PrivilegedHelperInstaller.launchDaemonPlist())
        let scriptURL = directory.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", scriptURL.path]
        try shell.run()
        shell.waitUntilExit()
        XCTAssert(shell.terminationStatus == 0)
    }

    /// Release apps have two slices. Requiring only the host cdhash rejects the
    /// other slice during codesign verification, even though neither changed.
    private func verifyUniversalApproval(in directory: URL, verifier: BundledArtifactVerifier) throws {
        let source = directory.appendingPathComponent("fixture.c")
        let executable = directory.appendingPathComponent("universal-fixture")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-arch", "x86_64", source.path, "-o", executable.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "dev.x.teleport", executable.path])
        let hashes = try BundledArtifactVerifier.codeDirectoryHashes(at: executable)
        XCTAssert(hashes.count == 2, "Both architectures must be approved")
        let approval = HelperInstallationManifest(
            helperVersion: PrivilegedHelperConstants.version,
            appCDHashes: hashes,
            helperCDHashes: hashes,
            xraySHA256: BundledArtifactPolicy.current.xraySHA256
        )
        try verifier.verifyCodeSignature(at: executable, requirement: approval.clientRequirement)
        for hash in hashes {
            do {
                try verifier.verifyCodeSignature(at: executable, requirement: "cdhash H\"\(hash)\"")
                XCTFail("Approving one architecture must not approve the other")
            } catch is PrivilegedHelperInstallerError {}
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssert(process.terminationStatus == 0, "Fixture command failed: \(executable)")
    }
}
