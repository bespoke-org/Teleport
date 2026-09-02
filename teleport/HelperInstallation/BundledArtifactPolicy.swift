import Foundation

struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        codeSigningRequirement: "identifier \"dev.x.teleport\" and anchor apple generic and certificate leaf[subject.OU] = \"6RXJJA7GCX\"",
        xraySHA256: "650e6edf792ce808554e94f891db5271c77a7c2e80188beaafbf24883b3b84a0"
    )

    let codeSigningRequirement: String
    let xraySHA256: String
}
