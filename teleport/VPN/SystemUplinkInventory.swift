import Foundation
import SystemConfiguration

/// The physical interface macOS considers primary, read from the dynamic store.
///
/// `route get` cannot answer this while a tunnel is up: the TUN owns both default
/// halves, so every lookup reports the tunnel. Xray's TUN is not a configured
/// network service, so the dynamic store keeps naming the real uplink — which is
/// what a health probe needs, since a probe measures the server rather than the
/// tunnel that happens to be running.
nonisolated enum SystemUplinkInventory {
    /// The uplink a session was built on. The router is part of its identity, not
    /// decoration: a tunnel pins its proxy-server routes to that specific gateway,
    /// so the same interface coming back with a new lease is as broken as a
    /// different interface entirely.
    struct Uplink: Equatable, Sendable {
        let interfaceName: String
        let routerAddress: String?

        var summary: String {
            "\(interfaceName) via \(routerAddress ?? "<no router>")"
        }
    }

    static func current() -> Uplink? {
        guard let store = SCDynamicStoreCreate(nil, "dev.x.teleport" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interfaceName = value["PrimaryInterface"] as? String,
              !interfaceName.isEmpty else {
            return nil
        }
        let routerAddress = (value["Router"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Uplink(interfaceName: interfaceName, routerAddress: routerAddress)
    }

    static func primaryInterfaceName() -> String? {
        current()?.interfaceName
    }
}
