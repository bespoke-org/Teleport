import Foundation

nonisolated struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        xraySHA256: "70a7377e7eead7077576d6f84feccc7ffdd9a413f45e84c7900729e3a909c820"
    )

    let xraySHA256: String
}
