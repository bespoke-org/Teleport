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
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "dev.x.teleport" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interfaceName = value["PrimaryInterface"] as? String,
              !interfaceName.isEmpty else {
            return nil
        }
        return interfaceName
    }
}
