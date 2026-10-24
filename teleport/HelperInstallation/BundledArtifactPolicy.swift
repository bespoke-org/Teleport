import Foundation

nonisolated struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        codeSigningRequirement: TeleportCodeSigning.currentRequirement(),
        xraySHA256: "650e6edf792ce808554e94f891db5271c77a7c2e80188beaafbf24883b3b84a0"
    )

    /// Nil when the running app has no Team ID; nothing is installed as root then.
    let codeSigningRequirement: String?
    let xraySHA256: String
}

extension BundledArtifactPolicy {
    nonisolated static let missingTeamIdentifierMessage = "This build of Teleport is not signed with a Team ID, so it cannot verify the helper it would install. Set DEVELOPMENT_TEAM in Config/Local.xcconfig and rebuild, or use System Proxy mode."
}
