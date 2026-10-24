import Foundation

nonisolated struct BundledArtifactVerifier: Sendable {
    let policy: BundledArtifactPolicy

    init(policy: BundledArtifactPolicy = .current) {
        self.policy = policy
    }

    func verify(appBundleURL: URL, helperURL: URL, runtimeURL: URL) throws {
        try verifyCodeSignature(at: appBundleURL)
        try verifyCodeSignature(at: helperURL)
        try verifyXrayHash(runtimeURL)
    }

    func verifyCodeSignature(at url: URL) throws {
        guard let requirement = policy.codeSigningRequirement else {
            throw PrivilegedHelperInstallerError.installFailed(BundledArtifactPolicy.missingTeamIdentifierMessage)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "--requirement", requirement,
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
