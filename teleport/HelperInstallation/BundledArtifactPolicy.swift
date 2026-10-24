import Foundation

nonisolated struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        codeSigningRequirement: TeleportCodeSigning.currentRequirement(),
        xraySHA256: "26fde0ef5186cc2379f6a0954c0d1d20c3dc1dd9f66c83ae87ccd753eb6f93b5"
    )

    /// Nil when the running app has no Team ID; nothing is installed as root then.
    let codeSigningRequirement: String?
    let xraySHA256: String
}

extension BundledArtifactPolicy {
    nonisolated static let missingTeamIdentifierMessage = "This build of Teleport is not signed with a Team ID, so it cannot verify the helper it would install. Set DEVELOPMENT_TEAM in Config/Local.xcconfig and rebuild, or use System Proxy mode."
}
