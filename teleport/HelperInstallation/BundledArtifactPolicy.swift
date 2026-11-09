import Foundation

nonisolated struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        xraySHA256: "42d74053687fd3fa64d5eca560709aceda7c96297f10a1424aece8aa83ec192f"
    )

    let xraySHA256: String
}
