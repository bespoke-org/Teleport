import Foundation

/// Imported portals share the subscription's settings. Only standalone portals
/// have a connection-level target.
nonisolated enum TunnelTarget: Codable, Hashable, Identifiable, Sendable {
    case subscription(UUID)
    case connection(UUID)

    var id: String {
        switch self {
        case let .subscription(id): return "subscription:\(id)"
        case let .connection(id): return "connection:\(id)"
        }
    }

    init(connection: SavedConnection) {
        if let sourceID = connection.source?.subscriptionSourceID { self = .subscription(sourceID) }
        else { self = .connection(connection.id) }
    }
}

nonisolated struct TunnelProfileAssignment: Codable, Equatable, Sendable {
    let target: TunnelTarget
    /// nil follows this subscription's provider profile. A personal profile can
    /// be shared by multiple targets; refreshes never change these assignments.
    var personalProfileID: UUID?
}

enum TunnelProfileResolver {
    static func profile(
        for target: TunnelTarget?, profiles: [SplitTunnelProfile],
        assignments: [TunnelProfileAssignment]
    ) -> SplitTunnelProfile? {
        if let target, let id = assignments.first(where: { $0.target == target })?.personalProfileID,
           let profile = profiles.first(where: { $0.id == id }) { return profile }
        if case let .subscription(sourceID) = target,
           let profile = profiles.first(where: { $0.subscriptionSourceID == sourceID }) { return profile }
        return profiles.first(where: { $0.subscriptionSourceID == nil })
    }
}
