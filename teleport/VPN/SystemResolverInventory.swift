import Foundation
import SystemConfiguration

/// The resolvers macOS currently uses for unscoped DNS queries, read from the
/// dynamic store the same way `scutil --dns` does, without parsing its text.
nonisolated enum SystemResolverInventory {
    static func nameservers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "dev.x.teleport" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = value["ServerAddresses"] as? [String] else {
            return []
        }
        var seen: Set<String> = []
        return servers.filter { seen.insert($0).inserted }
    }
}
