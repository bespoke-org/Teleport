import Foundation
import Security

nonisolated struct BundledArtifactVerifier: Sendable {
    let policy: BundledArtifactPolicy

    init(policy: BundledArtifactPolicy = .current) {
        self.policy = policy
    }

    func verify(appBundleURL: URL, helperURL: URL, runtimeURL: URL, manifest: HelperInstallationManifest) throws {
        try verifyCodeSignature(at: appBundleURL, requirement: manifest.clientRequirement)
        try verifyCodeSignature(at: helperURL, requirement: manifest.helperRequirement)
        try verifyXrayHash(runtimeURL)
    }

    func verifyCodeSignature(at url: URL, requirement: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "--all-architectures",
            "-R=\(requirement)",
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

    /// Approve every supported slice so universal builds pass verification on
    /// both Intel and Apple Silicon, including a client running under Rosetta.
    static func codeDirectoryHashes(at url: URL) throws -> [String] {
        var hashes: [String] = []
        for architecture in ["arm64", "x86_64"] {
            let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess,
                  let code else { continue }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
                throw PrivilegedHelperInstallerError.installFailed("Teleport could not read a bundled code signature. Rebuild or reinstall Teleport.")
            }
            hashes.append(hash.map { String(format: "%02x", $0) }.joined())
        }
        guard !hashes.isEmpty else {
            throw PrivilegedHelperInstallerError.installFailed("Teleport could not read a supported code signature. Rebuild or reinstall Teleport.")
        }
        return hashes.sorted()
    }

    func verifyXrayHash(_ runtimeURL: URL) throws {
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
        guard digest.caseInsensitiveCompare(policy.xraySHA256) == .orderedSame else {
            throw PrivilegedHelperInstallerError.installFailed("Bundled Xray runtime hash verification failed.")
        }
    }
}
