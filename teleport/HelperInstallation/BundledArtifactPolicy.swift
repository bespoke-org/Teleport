import Foundation

nonisolated struct BundledArtifactPolicy: Sendable {
    static let current = BundledArtifactPolicy(
        xraySHA256: "26fde0ef5186cc2379f6a0954c0d1d20c3dc1dd9f66c83ae87ccd753eb6f93b5"
    )

    let xraySHA256: String
}
