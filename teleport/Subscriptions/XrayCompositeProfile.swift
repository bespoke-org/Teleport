import Foundation

/// Validated Xray options stored in a stable JSON representation. Only the
/// parser constructs these objects; arbitrary provider runtime settings never
/// become part of Teleport's generated configuration.
nonisolated struct XrayJSONObject: Codable, Equatable, Sendable {
    private let data: Data

    init(_ object: [String: Any]) throws {
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

nonisolated struct XrayProfileMember: Codable, Equatable, Sendable {
    let tag: String
    let configuration: ConnectionConfiguration
}

nonisolated struct XrayCompositeProfile: Codable, Equatable, Sendable {
    let members: [XrayProfileMember]
    let balancer: XrayJSONObject
    let burstObservatory: XrayJSONObject

    var strategy: String {
        (balancer.object["strategy"] as? [String: Any])?["type"] as? String ?? "random"
    }
}
